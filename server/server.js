'use strict';

/**
 * CHRIS Chat · 零依赖即时通讯服务端
 *
 * HTTP：静态托管 public/，以及 /api 下注册、登录、好友、会话、消息接口
 * WebSocket：lib/ws.js 自实现（RFC 6455），负责实时收发
 * 数据：users/friendships/chats/reads 存 JSON，消息按会话追加到 JSONL
 *
 * 启动：node server.js     默认 http://127.0.0.1:5180
 */

const http = require('http');
const http2 = require('http2');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const { spawnSync, spawn } = require('child_process');
const zlib = require('zlib');
const ws = require('./lib/ws');

const ROOT = __dirname;
const PUBLIC_DIR = path.join(ROOT, 'public');
const DATA_DIR = process.env.DATA_DIR ? path.resolve(process.env.DATA_DIR) : path.join(ROOT, 'data');
const MSG_DIR = path.join(DATA_DIR, 'messages');
const UPLOAD_DIR = path.join(DATA_DIR, 'uploads');

const PORT = Number(process.env.PORT || 5180);
/* 内置 TURN（通话中转）的端口和账号：局域网内部用，保持简单 */
const TURN_PORT_NUM = Number(process.env.TURN_PORT || 3478);
const TURN_USER = process.env.TURN_USER || 'chris';
const TURN_PASS = process.env.TURN_PASS || 'chris1234';
const TURN_REALM = process.env.TURN_REALM || 'chris';
const HOST = process.env.HOST || '127.0.0.1';
// 手机版：默认监听所有网卡（手机连同一个 Wi-Fi 就能打开），
// 想只允许本机访问就设 CHRIS_LOCAL_ONLY=1
const BIND_HOST = process.env.CHRIS_LOCAL_ONLY === '1' ? HOST : '0.0.0.0';
const COOKIE_NAME = 'chris_chat_session';
const ADMIN_COOKIE = 'chris_chat_admin';
const ADMIN_FILE_NAME = 'admin.json';
const DEFAULT_ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'chris888';
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
/* 普通用户的登录态：默认 180 天，别动不动就掉登录。
   要改就改 data/security.json 里的 sessionDays（1~3650）。 */
function userSessionTtlMs() {
  const d = Number(secCfg().sessionDays);
  const days = (isFinite(d) && d >= 1 && d <= 3650) ? d : 180;
  return days * 24 * 60 * 60 * 1000;
}
const MAX_BODY = 28 * 1024 * 1024;
const RECALL_WINDOW_MS = 2 * 60 * 1000;
let writeSeq = 0;                 // writeJson 用的临时文件序号
const MAX_CACHE = 8000;          // 一个会话最多在内存里留多少条（聊天记录本身在文件里一条不少）

/* ---------------------------------------------------------------- 小工具 */

function ensureDirs() {
  [DATA_DIR, MSG_DIR, UPLOAD_DIR].forEach((d) => fs.mkdirSync(d, { recursive: true }));
}

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { return fallback; }
}

function writeJson(file, value) {
  // 每次用唯一的临时名 + 失败重试：多人同时说话时，原来固定用 .tmp
  // 会互相抢（Windows 上 rename 会报 EPERM，消息就丢了）
  const tmp = file + '.' + process.pid + '.' + (writeSeq = (writeSeq + 1) % 1e6) + '.tmp';
  const text = JSON.stringify(value, null, 2);
  fs.writeFileSync(tmp, text, 'utf8');
  for (let i = 0; i < 6; i++) {
    try {
      fs.renameSync(tmp, file);
      return;
    } catch (err) {
      if (i === 5) {
        try { fs.copyFileSync(tmp, file); fs.unlinkSync(tmp); return; } catch (e2) { throw err; }
      }
      const until = Date.now() + 6 * (i + 1);
      while (Date.now() < until) { /* 等几毫秒再试 */ }
    }
  }
}


/** 只接受 #rrggbb，其它一律当空（用默认色） */
function hexColor(value) {
  const s = String(value == null ? '' : value).trim();
  return /^#[0-9a-fA-F]{6}$/.test(s) ? s.toLowerCase() : '';
}
function uid(prefix) { return prefix + '_' + crypto.randomBytes(8).toString('hex'); }
function now() { return new Date().toISOString(); }

/* ------------------------------------------------------------------
   群头像：和微信一样，把成员头像拼成九宫格（1-4 人 2×2，5-9 人 3×3）
   用服务器上的 ffmpeg 直接合成一张正方形 PNG，存进 /uploads，
   这样 App、网页版、后台看到的都是同一张（客户端一行代码都不用改）。
   ------------------------------------------------------------------ */
const GROUP_TILE = 128;          // 单格边长（3×3 出图 384×384）

/* 共享实时位置：活跃会话（内存里的，2 小时过期） */
const liveLocations = new Map();
const LIVE_LOCATION_TTL = 2 * 60 * 60 * 1000;

/* ---------------------------------------------------------- 零钱：银行卡 / 充值 / 提现 */

/* ============================================================
   客服中心（腾讯/微信那套）：常见问题分类 + 搜索 + 在线客服（转人工）+ 工单进度
   配置在 data/support.json（后台「客服中心」页改），工单在 data/support-tickets.jsonl
   ============================================================ */
const SUPPORT_FILE = 'support.json';
const SUPPORT_TICKETS = 'support-tickets.jsonl';
let supportCache = null;
const DEFAULT_SUPPORT = {
  title: '客服中心',
  searchHint: '描述你遇到的问题，比如「登录不上」',
  human: 1,                      // 是否开放在线客服（转人工）
  autoReply: 1,                  // 人工不在时，AI 先按下面的问答答一轮（0 = 不自动回）
  ticketOn: 1,                   // 是否允许「提交问题」开工单（0 = 只留在线客服）
  phone: '',                     // 客服电话（留空不显示）
  email: '',
  workTime: '在线客服 09:00 - 22:00',
  workStart: 9,                  // 人工值班开始（整点，北京时间）
  workEnd: 22,                   // 人工值班结束
  offTimeNote: '现在不在人工值班时间（在线客服 09:00 - 22:00），你的问题已经记下来了，明天上班会有人跟进。急的话可以先在常见问题里搜一下。',
  greet: '你好，我是客服。把问题说清楚一点，我会尽快帮你处理。',
  ticketHint: '没找到答案？把问题写清楚提交，我们会尽快处理，处理进度在「我的工单」里看。',
  categories: [
    { id: 'sp1', title: '账号与登录', icon: '账号', items: [
      { q: '收不到验证码怎么办？', a: '① 检查手机号是否填对；② 等 60 秒再点一次；③ 换一个信号好的地方。还是收不到就让管理员在后台「短信通道」里检查配置。' },
      { q: '忘记密码了', a: '登录页点「忘记密码」，用绑定的手机号收验证码后重设。' },
      { q: '怎么改昵称/头像？', a: '我 → 点头像进「个人信息」，改完点右上角保存。' }
    ] },
    { id: 'sp2', title: '支付与零钱', icon: '钱包', items: [
      { q: '零钱怎么充值？', a: '我 → 服务 → 钱包 → 零钱 → 充值，选银行卡、填金额，输入支付密码即可。' },
      { q: '提现多久到账？', a: '一般是 2 小时内到账，手续费 0.1%（最低 0.1 元），具体以银行处理时间为准。' },
      { q: '转账转错了怎么办？', a: '先联系对方退回；对方不配合的话把转账单号发给客服，我们协助核实。' }
    ] },
    { id: 'sp3', title: '聊天与通话', icon: '聊天', items: [
      { q: '消息发不出去', a: '看下网络；被杀掉后台再重开 App；还不行就把时间点告诉客服，我们查服务器日志。' },
      { q: '语音/视频打不通', a: '语音通话走的是服务器转发，只要你能收消息就能通；视频通话需要更好的网络。打不通时报一下时间，我们查。' },
      { q: '怎么发朋友圈？', a: '发现 → 朋友圈 → 右上角相机，选图或拍一张，写完点发表。' }
    ] },
    { id: 'sp4', title: '安全与隐私', icon: '锁', items: [
      { q: '怎么拉黑一个人？', a: '好友名片 → 右上角「···」→ 加入黑名单。' },
      { q: '怎么改支付密码？', a: '我 → 设置 → 支付密码，按提示重设。' },
      { q: '实名认证怎么弄？', a: '我 → 设置 → 账号与安全 → 实名认证，填姓名和身份证号。' }
    ] }
  ]
};

/** 现在是不是「人工下班了」（按北京时间算，值班时段在后台「客服中心」里配） */
function supportOffDuty() {
  const cfg = readSupport();
  const start = Number(cfg.workStart);
  const end = Number(cfg.workEnd);
  if (!isFinite(start) || !isFinite(end)) return false;
  const h = new Date(Date.now() + 8 * 3600 * 1000).getUTCHours();   // 北京时间小时
  if (start === end) return false;
  if (start < end) return h < start || h >= end;
  return h < start && h >= end;                                     // 跨零点那种（比如 22:00-06:00）
}

function readSupport() {
  if (supportCache) return supportCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, SUPPORT_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_SUPPORT, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.categories) || !cfg.categories.length) cfg.categories = DEFAULT_SUPPORT.categories;
  supportCache = cfg;
  return cfg;
}

function saveSupport(next) {
  supportCache = Object.assign({}, DEFAULT_SUPPORT, next || {});
  try { writeJson(path.join(DATA_DIR, SUPPORT_FILE), supportCache); } catch (e) { }
  return supportCache;
}

/** 客服账号（在线客服转人工就是和这个号聊天）：没有就建一个 */
function supportAgent() {
  let u = db.users.find((x) => x.username === 'kefu');
  if (u) {
    /* 老数据里这个账号没有 service 标记：补上，免得被当成普通机器人给所有人建会话 */
    if (!u.service) { u.service = true; u.bot = true; saveUsers(); }
    return u;
  }
  u = {
    id: uid('u'), username: 'kefu', nickname: '在线客服', avatar: '/uploads/bot-kefu.png',
    salt: crypto.randomBytes(16).toString('hex'), bio: '有问题随时找我',
    /* bot: true → 名片上显示「官方账号」（和微信客服一样）；
       service: true → 不参与「给所有人开机器人欢迎会话 / 机器人会话置顶」那几套循环，
       只有真的点了「联系客服」的人才会有这个会话，不会打扰所有人。 */
    createdAt: now(), bot: true, service: true
  };
  db.users.push(u);
  saveUsers();
  return u;
}

function supportTicketCount(userId) {
  try {
    return fs.readFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), 'utf8')
      .trim().split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
      .filter((t) => t && (!userId || t.userId === userId)).length;
  } catch (e) { return 0; }
}

function readSupportTickets(limit, userId) {
  try {
    const rows = fs.readFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), 'utf8')
      .trim().split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
      .filter((t) => t && (!userId || t.userId === userId));
    return rows.slice(-limit).reverse();
  } catch (e) { return []; }
}

/* 工单：一行一条追加（和聊天记录一样的存法，不怕写坏） */
function appendSupportTicket(t) {
  try { fs.appendFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), JSON.stringify(t) + '\n', 'utf8'); } catch (e) { }
  return t;
}

/* 改一条工单（回复 / 结单）：整文件重写，行数不多，无所谓 */
function updateSupportTicket(id, patch) {
  let rows = [];
  try {
    rows = fs.readFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), 'utf8')
      .trim().split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean);
  } catch (e) { rows = []; }
  let hit = null;
  rows = rows.map((t) => {
    if (t.id !== id) return t;
    hit = Object.assign({}, t, patch || {});
    return hit;
  });
  if (!hit) return null;
  try {
    fs.writeFileSync(path.join(DATA_DIR, SUPPORT_TICKETS),
      rows.map((t) => JSON.stringify(t)).join('\n') + '\n', 'utf8');
  } catch (e) { }
  return hit;
}

/* 客服和某个用户的单聊（在线客服/工单回复都往这里发消息） */
function supportChatFor(userId) {
  const agent = supportAgent();
  /* 客服和用户是好友关系：这样手机端「打开会话」走的还是普通单聊那一套（和机器人一样） */
  ensureSupportFriend(userId, agent);
  return openChatForFriendship(userId, agent.id);
}

function ensureSupportFriend(userId, agent) {
  try {
    const f = friendshipBetween(userId, agent.id);
    if (f) {
      if (f.status !== 'accepted') { f.status = 'accepted'; saveFriendships(); }
      return;
    }
    db.friendships.push({ id: uid('f'), fromId: agent.id, toId: userId, status: 'accepted', createdAt: now() });
    saveFriendships();
  } catch (e) { }
}

/* 人工不在时的自动回复：把后台配的问答当知识库，让 AI 用客服口吻答一轮 */
async function supportBotAnswer(user, text) {
  const cfg = readSupport();
  const faq = (cfg.categories || []).map((c) =>
    '【' + (c.title || '') + '】\n' + (c.items || []).map((it) => '问：' + it.q + '\n答：' + it.a).join('\n')).join('\n');
  /* 回答风格照微信官方帮助中心那套（微信的「帮助与反馈」就是这么写的）：
     结论 → 完整路径（每级用「」）→ 分步骤 → 限制/费用/时长 → 结尾一句「如仍有问题…」 */
  const sys = '你是这个 App 的在线客服。回答格式严格照微信官方帮助中心（微信「我 → 设置 → 帮助与反馈」里那套）：\n'
    + '【第一条】先用一句话给结论：能不能做、在哪做、为什么，不要寒暄、不要复述用户的问题。\n'
    + '【第二条】要给操作路径时写完整：每一级都用「」包起来、用 → 连接。例如：我 → 服务 → 钱包 → 零钱 → 充值。\n'
    + '【第三条】步骤多就分点，用「① ② ③」，每点一句话，只说要点，不要长段落。\n'
    + '【第四条】该写的限制一定写清楚：时间（24 小时自动退回）、费用（手续费 0.1%、最低 0.1 元）、额度（单笔/单日 1000、5000、20000 三档）、个数（红包最多 100 个）。\n'
    + '【第五条】最后固定加一句：如需人工客服协助，回复「人工」即可转接。\n'
    + '【第六条】只用下面「知识库」里的内容。知识库里没有的（查某个账号、改数据、退钱、承诺处理时间），不要编，回：这个情况我记下来了，转人工客服帮你核实处理。\n'
    + '【第七条】只回答这个 App 的使用问题；中文；不要 Markdown 符号（不要 **、#、-），不要表情符号堆砌，整段不超过 6 行。\n'
    + '【知识库】\n' + faq;
  const ai = readAiCfg();
  const reply = await llmChat([
    { role: 'system', content: sys },
    { role: 'user', content: String(text || '').slice(0, 500) }
  ], ai);
  return String(reply || '').trim();
}

const WALLET_OPS_FILE = 'wallet-ops.json';
let walletOpsCache = null;
const WALLET_RULES_FILE = 'wallet-rules.json';
let walletRulesCache = null;
const DEFAULT_WALLET_RULES = {
  allowRecharge: 1,        // 允许用户自己充值（0 = 只能后台充）
  rechargeMax: 50000,      // 单笔充值上限
  feeRate: 0.001,          // 提现手续费率（微信 0.1%）
  feeMin: 0.1,             // 最低手续费
  withdrawMin: 1,          // 最低提现
  withdrawMax: 50000,      // 单笔提现上限
  withdrawReview: 0,       // 1 = 提现要后台审核后才算到账
  note: '提现到银行卡一般是 2 小时内到账，具体以银行处理时间为准。'
};

function readWalletRules() {
  if (walletRulesCache) return walletRulesCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, WALLET_RULES_FILE), 'utf8')); } catch (e) { raw = {}; }
  walletRulesCache = Object.assign({}, DEFAULT_WALLET_RULES, raw && typeof raw === 'object' ? raw : {});
  return walletRulesCache;
}

function saveWalletRules(next) {
  walletRulesCache = Object.assign({}, DEFAULT_WALLET_RULES, next || {});
  try { writeJson(path.join(DATA_DIR, WALLET_RULES_FILE), walletRulesCache); } catch (e) { }
  return walletRulesCache;
}

function readWalletOps() {
  if (walletOpsCache) return walletOpsCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, WALLET_OPS_FILE), 'utf8')); } catch (e) { raw = {}; }
  walletOpsCache = { ops: Array.isArray(raw.ops) ? raw.ops : [] };
  return walletOpsCache;
}

function saveWalletOps() {
  if (!walletOpsCache) return;
  try { writeJson(path.join(DATA_DIR, WALLET_OPS_FILE), walletOpsCache); } catch (e) { }
}

/** 记一条零钱操作（充值 / 提现），账单里也会显示 */
function pushWalletOp(row) {
  const d = readWalletOps();
  d.ops.unshift(row);
  if (d.ops.length > 5000) d.ops.length = 5000;
  saveWalletOps();
  return row;
}

/** 我的银行卡（只存银行名 + 末四位，完整卡号不落盘） */
function userBanks(user) {
  if (!Array.isArray(user.banks)) user.banks = [];
  return user.banks;
}

/* ---------------------------------------------------------- 视频号「关注」
   以前点关注是拿「用户 id」当用户名去发好友申请，服务器查不到 → 必然失败。
   现在是真的关注表：谁关注了谁，和好友关系分开（微信视频号也是分开的）。 */
const FEED_FOLLOW_FILE = 'feed-follows.json';
let feedFollowCache = null;

function readFeedFollows() {
  if (feedFollowCache) return feedFollowCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, FEED_FOLLOW_FILE), 'utf8')); } catch (e) { raw = {}; }
  feedFollowCache = { follows: Array.isArray(raw.follows) ? raw.follows : [] };
  return feedFollowCache;
}

function saveFeedFollows() {
  if (!feedFollowCache) return;
  try { writeJson(path.join(DATA_DIR, FEED_FOLLOW_FILE), feedFollowCache); } catch (e) { }
}

/** 我关注了谁（id 数组） */
function myFeedFollows(userId) {
  return readFeedFollows().follows.filter((f) => f.fromId === userId).map((f) => f.toId);
}

/* ---------------------------------------------------------- 视频号推荐（抖音那套逻辑）
   同一个视频号，不同的人看到的内容和顺序都不一样。信号来源：
     ① 内容质量：点赞 / 评论 / 分享 + 后台设置的 baseLikes
     ② 新鲜度：越新越靠前（按小时衰减）
     ③ 个人兴趣：我点过赞 / 评论过 / 关注过的「作者」和「标签」加权
     ④ 社交关系：我好友点过赞的、我关注的人发的，加权
     ⑤ 负反馈：我已经看过的，看过的次数越多排得越后
     ⑥ 多样性：相邻不重复同一作者，避免同一个人刷屏
     ⑦ 探索：每个用户一份稳定的随机（同一天内不跳），千人千面又不抖
   同时把「这次推给了谁」记进 feed-views.json，作为下次的负反馈依据。 */
const FEED_VIEW_FILE = 'feed-views.json';
const FEED_QUEUE_FILE = 'feed-queue.json';   // 每用户一条稳定的播放队列（进去不打乱）
const FEED_VIEW_THROTTLE_MS = 0;           // 每次推给用户都记账（推过就不再推同样的）
/* 至少还剩这么多没看过的，就完全不推看过的；不够了才开始回收 */
const FEED_UNSEEN_FLOOR = 6;
/* 一次推几条：抖音是一条条喂的，一次给一点，刷新才是新的一批 */
const FEED_BATCH = 12;

/* 推荐用到的这两个小文件：内存里存一份，改动合并后每 2 秒落一次盘。
   原来每个 /api/feed 请求都要同步读写两个文件，人多的时候白白占磁盘和事件循环。 */
const FEED_STORE = {};
let feedStoreTimer = null;
function feedStoreRead(name, fallback) {
  if (!FEED_STORE[name]) FEED_STORE[name] = { data: null, dirty: false };
  const slot = FEED_STORE[name];
  if (slot.data === null) slot.data = readJson(path.join(DATA_DIR, name), fallback);
  return slot.data;
}
function feedStoreFlush() {
  feedStoreTimer = null;
  Object.keys(FEED_STORE).forEach((name) => {
    const slot = FEED_STORE[name];
    if (!slot.dirty || slot.data === null) return;
    try { writeJson(path.join(DATA_DIR, name), slot.data); slot.dirty = false; } catch (e) { }
  });
}
function feedStoreMarkDirty(name) {
  if (!FEED_STORE[name]) FEED_STORE[name] = { data: null, dirty: false };
  FEED_STORE[name].dirty = true;
  if (!feedStoreTimer) feedStoreTimer = setTimeout(feedStoreFlush, 2000);
}

function hashStr32(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i += 1) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return Math.abs(h);
}

/** 一条视频的标签集合：后台填的 tag + 文案里的 #话题 */
function feedTagsOf(it) {
  const out = [];
  const tag = String(it.tag || '').trim();
  if (tag) out.push(tag);
  const m = String(it.desc || '').match(/#[^\s#]{1,16}/g) || [];
  for (const x of m) out.push(x.slice(1));
  return out;
}

/** 个人兴趣画像：作者权重 / 标签权重 */
function buildFeedInterest(userId, items, follows) {
  const authorW = {}, tagW = {};
  const bump = (map, k, v) => { if (k) map[k] = (map[k] || 0) + v; };
  items.forEach((it) => {
    const liked = Array.isArray(it.likedBy) && it.likedBy.indexOf(userId) >= 0;
    const commented = Array.isArray(it.comments) && it.comments.some((c) => c && c.userId === userId);
    if (liked || commented) {
      bump(authorW, it.authorId, liked ? 3 : 2);
      feedTagsOf(it).forEach((t) => bump(tagW, t, liked ? 2 : 1));
    }
  });
  follows.forEach((id) => bump(authorW, id, 2));
  return { authorW, tagW };
}

/** 个性化排序：返回排好序的条目数组 */
/** 一条视频 → 客户端要的结构（推荐流和「选集」列表共用同一套字段） */
function feedItemOut(it, user) {
  const a = it.authorId ? findUser(it.authorId) : null;
  const likedBy = Array.isArray(it.likedBy) ? it.likedBy : [];
  const iFollow = (it.authorId && myFeedFollows(user.id).includes(it.authorId)) || false;
  return {
    id: it.id,
    video: it.video || '',
    /* 分片地址（有的话客户端优先用它）：先出画面，后面边看边下 */
    hls: it.hls || '',
    cover: it.cover || '',
    desc: it.desc || '',
    music: it.music || '',
    tag: it.tag || '',
    /* 短剧：集数标签 / 总集数 / 剧集 id 与剧名（客户端左上角显示集数、并做选集） */
    ep: it.ep || '',
    epTotal: Number(it.epTotal) || 0,
    series: it.series || '',
    seriesName: it.seriesName || '',
    createdAt: it.createdAt || '',
    mine: it.authorId === user.id,
    author: {
      id: it.authorId || '',
      name: (a && a.nickname) || it.author || '用户',
      avatar: (a && a.avatar) || it.authorAvatar || ''
    },
    likes: likedBy.length + (Number(it.baseLikes) || 0),
    liked: likedBy.indexOf(user.id) >= 0,
    /* 收藏（抖音右侧那排的星标） */
    favorites: Array.isArray(it.savedBy) ? it.savedBy.length : 0,
    favorited: Array.isArray(it.savedBy) && it.savedBy.indexOf(user.id) >= 0,
    followed: iFollow,
    comments: (it.comments || []).length + (Number(it.baseComments) || 0),
    shares: Number(it.baseShares) || 0
  };
}

function rankFeedFor(user, items, myFriends) {
  const nowMs = Date.now();
  const follows = myFeedFollows(user.id);
  const followSet = new Set(follows);
  const { authorW, tagW } = buildFeedInterest(user.id, items, follows);
  const views = feedStoreRead(FEED_VIEW_FILE, {});
  const mineViews = (views && views[user.id]) || {};
  const today = new Date().toISOString().slice(0, 10);
  /* 别人的内容池：抖音不会把你自己的作品推给你（自己的在「我 → 作品」里看） */
  const others = items.filter((it) => it.authorId !== user.id);
  const pool0 = others.length ? others : items;
  /* 冷启动：这个用户还没有任何兴趣信号（没点赞/没评论/没关注/没看过），
     给每个人一份更强的探索随机，做到「新用户也各看各的」。 */
  const hasProfile = Object.keys(authorW).length > 0 || Object.keys(tagW).length > 0 || Object.keys(mineViews).length > 0;
  /* 没看过的快刷完时，把"看过"的计数砍一半，让老内容重新回到队伍里 —— 抖音永远刷得动 */
  try {
    const unseenLeft = pool0.filter((it) => !mineViews[it.id]).length;
    if (unseenLeft < FEED_UNSEEN_FLOOR) {
      Object.keys(mineViews).forEach((k) => {
        const rec = mineViews[k];
        if (rec && typeof rec === 'object') rec.count = Math.floor((Number(rec.count) || 0) / 2);
        else mineViews[k] = Math.floor((Number(rec) || 0) / 2);
      });
      views[user.id] = mineViews;
      feedStoreMarkDirty(FEED_VIEW_FILE);
    }
  } catch (e) { /* 回收失败不影响出视频 */ }

  /* 「最近一次看到」的时间，用于播放队列重建时判断谁更该被冷落 */
  const lastSeenAt = (it) => {
    const rec = mineViews[it.id];
    return rec && typeof rec === 'object' && rec.lastAt ? new Date(rec.lastAt).getTime() : 0;
  };
  /* 顺序必须稳定：池子是「别人的全部视频」，排序固定，剩下的交给「播放队列」去推进 */
  const feedPool = pool0;
  const round = 'stable';   // 探索随机改成按「用户+当天」固定，进来不会再被重新洗牌

  const scored = feedPool.map((it) => {
    const likes = (Array.isArray(it.likedBy) ? it.likedBy.length : 0) + (Number(it.baseLikes) || 0);
    const comments = ((it.comments || []).length) + (Number(it.baseComments) || 0);
    const shares = Number(it.baseShares) || 0;
    /* 注意：零互动的新视频质量分不能是 0，否则排序会退化成"原顺序"、人人相同 */
    const quality = 1 + Math.log(1 + likes + comments * 2 + shares * 3);   // 互动越多越好，但不会无限放大
    const t = it.createdAt ? new Date(it.createdAt).getTime() : nowMs - 86400000;
    const hours = Math.max(0.5, (nowMs - t) / 3600000);
    const fresh = 1 / Math.pow(hours + 2, 0.45);                            // 新鲜度衰减
    /* 刚发出来的先给流量（抖音的冷启动池就是这个意思），用户进去第一眼看到的是新的 */
    const freshBoost = hours <= 24 ? 1.35 : (hours <= 72 ? 1.12 : 1);

    let interest = 0;
    if (it.authorId && authorW[it.authorId]) interest += authorW[it.authorId] * 1.2;
    feedTagsOf(it).forEach((tag) => { if (tagW[tag]) interest += tagW[tag] * 0.6; });
    const affinity = 1 + Math.min(3, interest);                             // 越合口味越靠前

    const friendLikes = (it.likedBy || []).filter((id) => myFriends.has(id)).length;
    const social = 1 + Math.min(2, friendLikes * 0.8) + (it.authorId && followSet.has(it.authorId) ? 1.2 : 0);

    const rec = mineViews[it.id];
    const seen = rec ? (typeof rec === 'number' ? rec : Number(rec.count) || 0) : 0;
    /* 负反馈：看过就往后排 —— 这样每次刷新推给你的都是没看过的，越刷越新 */
    const novelty = seen === 0 ? 1 : Math.max(0.08, 1 / (1 + seen * seen));

    const r = (hashStr32(user.id + '|' + it.id + '|' + today + '|' + round) % 1000) / 1000;
    /* 探索只做极小抖动（±4%/±6%），顺序基本由「新 + 热 + 兴趣」决定，
       不再大范围随机 —— 否则并列的几条会莫名其妙换位，看着像被打乱。
       真正拉开"千人千面"的是上面的兴趣（作者/标签权重）和社交权重。 */
    const explore = hasProfile ? (0.98 + r * 0.04) : (0.97 + r * 0.06);

    return { it, seen, score: quality * fresh * freshBoost * affinity * social * novelty * explore };
  });

  scored.sort((a, b) => b.score - a.score);

  /* 多样性：以分数排序为主（新的、热的在前），只做一件事 —— 不让同一个作者
     连排 3 条。以前是"严格交替"，结果把某个作者的老视频硬插到新视频中间，
     顺序看上去像被洗过一样乱，所以改成现在这种轻量打散。 */
  const top = scored.slice(0, 300);
  const out = top.map((x) => x.it);
  const authorKeyOf = (it) => it.authorId || ('item:' + it.id);
  for (let i = 2; i < out.length; i += 1) {
    const a0 = authorKeyOf(out[i - 2]), a1 = authorKeyOf(out[i - 1]), a2 = authorKeyOf(out[i]);
    if (a0 === a1 && a1 === a2) {
      /* 连排 3 条了：在往后的 6 条里找一个不同作者的换上来（找不到就算了） */
      const win = Math.min(out.length - 1, i + 6);
      for (let j = i + 1; j <= win; j += 1) {
        if (authorKeyOf(out[j]) !== a1) {
          const t = out[i]; out[i] = out[j]; out[j] = t;
          break;
        }
      }
    }
  }

  /* 每个人的「播放队列」：
       ① 进来看的顺序和你上次接着（光标往下走），不会每次重新洗牌；
       ② 刷过的不会再来（光标只往前）；
       ③ 期间新发的视频插到当前光标后面 —— 下次进去先看到新的；
       ④ 整条队列放完了，才按最新的兴趣重新排一轮。 */
  const rankedIds = out.map((it) => it.id);
  const byId = new Map(out.map((it) => [it.id, it]));
  const validIds = new Set(pool0.map((it) => it.id));
  const queues = feedStoreRead(FEED_QUEUE_FILE, {});
  let q = queues[user.id];
  if (!q || !Array.isArray(q.ids) || !q.ids.length) q = { ids: rankedIds.slice(), cursor: 0 };
  q.ids = q.ids.filter((id) => validIds.has(id));                 // 已经删掉的视频
  const inQueue = new Set(q.ids);
  const freshIds = rankedIds.filter((id) => !inQueue.has(id));     // 新发的内容
  if (freshIds.length) {
    const cur = Math.max(0, Math.min(q.cursor, q.ids.length));
    q.ids = q.ids.slice(0, cur).concat(freshIds, q.ids.slice(cur));
  }
  /* 这一轮快放完了（不够一批）：按最新的兴趣重排一轮，保证每次进去都能刷满一批 */
  if (q.ids.length - q.cursor < FEED_BATCH) { q.ids = rankedIds.slice(); q.cursor = 0; }
  const serveIds = q.ids.slice(q.cursor, q.cursor + FEED_BATCH);
  q.cursor += serveIds.length;
  queues[user.id] = q;
  feedStoreMarkDirty(FEED_QUEUE_FILE);
  const batch = serveIds.map((id) => byId.get(id)).filter(Boolean);

  /* 记曝光：推给谁看过哪几条，下次不再推同样的一条 */
  try {
    const v = feedStoreRead(FEED_VIEW_FILE, {});
    const mine = v[user.id] || {};
    const nowIso = new Date().toISOString();
    batch.forEach((it) => {
      const rec = mine[it.id];
      const prev = rec && typeof rec === 'object' ? rec : null;
      const lastAt = prev && prev.lastAt ? new Date(prev.lastAt).getTime() : 0;
      if (FEED_VIEW_THROTTLE_MS > 0 && Date.now() - lastAt < FEED_VIEW_THROTTLE_MS) return;
      const cnt = Math.min(5, (prev ? Number(prev.count) || 0 : 0) + 1);
      mine[it.id] = { count: cnt, lastAt: nowIso };
    });
    v[user.id] = mine;
    feedStoreMarkDirty(FEED_VIEW_FILE);
  } catch (e) { /* 曝光记录失败不影响出视频 */ }

  return batch;
}

/* ---------------------------------------------------------- 存储空间 */
/** 上传目录一共占了多少字节 */
function uploadDirSize() {
  let total = 0;
  try {
    fs.readdirSync(UPLOAD_DIR).forEach((f) => {
      try { total += fs.statSync(path.join(UPLOAD_DIR, f)).size; } catch (e) { }
    });
  } catch (e) { }
  return total;
}

/** 「没人引用」的上传文件有多大（只算，不删） */
function orphanUploadsSize() {
  let bytes = 0;
  collectOrphans().forEach((f) => {
    try { bytes += fs.statSync(path.join(UPLOAD_DIR, f)).size; } catch (e) { }
  });
  return bytes;
}

/** 找出「data 目录里任何文件都没引用」的上传文件（不删除，只返回文件名） */
function collectOrphans() {
  const used = new Set();
  /* 把 data 目录下的消息文件、所有 json、以及日志都扫一遍，凡是出现过的文件名都算「在用」。
     以前只扫了 .jsonl 和少数几个 json，结果 icons.json 里的图标、还有消息里的图片都被删了。 */
  try {
    const walk = (dir, depth) => {
      if (depth > 2) return;
      fs.readdirSync(dir).forEach((name) => {
        const p = path.join(dir, name);
        let st = null;
        try { st = fs.statSync(p); } catch (e) { return; }
        if (st.isDirectory()) {
          if (name === 'uploads') return;          // 上传目录自己不算引用来源
          walk(p, depth + 1);
          return;
        }
        if (!/\.(json|jsonl|log|txt)$/.test(name)) return;
        let text = '';
        try { text = fs.readFileSync(p, 'utf8'); } catch (e) { return; }
        const re = /\/uploads\/([A-Za-z0-9._-]+)/g;
        let m;
        while ((m = re.exec(text))) used.add(m[1]);
      });
    };
    walk(DATA_DIR, 0);
  } catch (e) { }
  const out = [];
  try {
    fs.readdirSync(UPLOAD_DIR).forEach((f) => {
      if (!used.has(f)) out.push(f);
    });
  } catch (e) { }
  return out;
}

/** 真删（只给后台用）：只删 24 小时前、且确认没人引用的，单次最多 200 个 */
function cleanOrphanUploads() {
  const orphans = collectOrphans();
  let freed = 0;
  let removed = 0;
  const now = Date.now();
  for (const f of orphans) {
    if (removed >= 200) break;
    try {
      const p = path.join(UPLOAD_DIR, f);
      const st = fs.statSync(p);
      /* 只清 24 小时以前没人引用的：刚上传还没发出去的消息绝不能删 */
      if (!st.isFile() || now - st.mtimeMs < 24 * 60 * 60 * 1000) continue;
      freed += st.size;
      fs.unlinkSync(p);
      removed += 1;
    } catch (e) { }
  }
  callTrace('清缓存：删了 ' + removed + ' 个没人引用的上传文件，释放 ' + Math.round(freed / 1024) + ' KB');
  return freed;
}

function ffmpegExe() {
  if (process.env.FFMPEG_PATH) return process.env.FFMPEG_PATH;
  /* 以前这里写死了 Windows 的绝对路径 —— 部署到 Linux 云服务器上就找不到 ffmpeg，
     群头像九宫格一直拼不出来（这也是「群头像不显示」的根因）。按系统挑路径。 */
  if (process.platform === 'win32') return 'C:/Users/Administrator/ffmpeg/bin/ffmpeg.exe';
  return '/usr/bin/ffmpeg';
}

/** 头像字段 → ffmpeg 能读的输入：/uploads 本地文件、data:URL 落成临时文件、http 网址原样 */
function avatarInputFile(avatar) {
  const a = String(avatar || '').trim();
  if (!a) return '';
  const m = /^\/uploads\/([A-Za-z0-9._-]+)/.exec(a);
  if (m) {
    const p = path.join(UPLOAD_DIR, m[1]);
    try { return fs.existsSync(p) ? p : ''; } catch (e) { return ''; }
  }
  if (/^https?:\/\//i.test(a)) return a;
  if (/^data:image\//i.test(a)) {
    const mm = /^data:image\/([a-zA-Z0-9.+-]+);base64,([\s\S]*)$/.exec(a);
    if (!mm) return '';
    try {
      const ext = mm[1].toLowerCase().replace('jpeg', 'jpg').replace(/[^a-z0-9]/g, '') || 'png';
      const file = path.join(os.tmpdir(), 'chris_av_' + crypto.randomBytes(6).toString('hex') + '.' + ext);
      fs.writeFileSync(file, Buffer.from(mm[2], 'base64'));
      return file;
    } catch (e) { return ''; }
  }
  return '';
}

/** 把前 9 个成员的头像拼成九宫格写回 chat.avatar；没人有头像就返回 false */
function buildGroupAvatar(chat) {
  if (!chat || chat.type !== 'group') return false;
  /* 顺序要跟「群聊信息页」的成员格子完全一致：群主排第一，其余按成员顺序 */
  const ids = (chat.memberIds || []).slice();
  const ownerFirst = chat.ownerId && ids.includes(chat.ownerId)
    ? [chat.ownerId].concat(ids.filter((id) => id !== chat.ownerId))
    : ids;
  const members = ownerFirst.map((id) => findUser(id)).filter(Boolean).slice(0, 9);
  if (!members.length) return false;
  const cols = members.length <= 4 ? 2 : 3;
  const size = cols * GROUP_TILE;
  const args = ['-y', '-loglevel', 'error'];
  const chain = [];
  chain.push('color=c=black@0.0:s=' + size + 'x' + size + ',format=rgba[bg]');
  let last = 'bg';
  /* 成员头像在上传目录里是**加密落盘**的，ffmpeg 直接读会是乱码 ——
     先解到临时明文文件再喂给它（不这么解，群头像永远拼不出来）。 */
  const temps = [];
  members.forEach((u, i) => {
    let file = avatarInputFile(u.avatar);
    if (file && path.dirname(file) === UPLOAD_DIR) {
      try {
        const tmp = uploadTempPlain(path.basename(file));
        temps.push(tmp);
        file = tmp;
      } catch (err) { file = ''; }
    } else if (file && path.dirname(file) === os.tmpdir()) {
      temps.push(file);
    }
    /* 没设头像的成员给一块浅灰砖（相当于微信的默认头像），格子不会缺一块 */
    if (file) args.push('-i', file);
    else args.push('-f', 'lavfi', '-i', 'color=c=0xE6E6EA:s=' + GROUP_TILE + 'x' + GROUP_TILE);
    const x = (i % cols) * GROUP_TILE;
    const y = Math.floor(i / cols) * GROUP_TILE;
    chain.push('[' + i + ':v]scale=' + GROUP_TILE + ':' + GROUP_TILE
      + ':force_original_aspect_ratio=increase,crop=' + GROUP_TILE + ':' + GROUP_TILE + ',setsar=1[v' + i + ']');
    chain.push('[' + last + '][v' + i + ']overlay=' + x + ':' + y + '[o' + i + ']');
    last = 'o' + i;
  });
  const name = 'group-' + chat.id.replace(/[^A-Za-z0-9._-]/g, '') + '.png';
  const outTmp = path.join(os.tmpdir(), 'chris-' + crypto.randomBytes(6).toString('hex') + '-group.png');
  const run = spawnSync(ffmpegExe(), args.concat([
    '-filter_complex', chain.join(';'),
    '-map', '[' + last + ']',
    '-frames:v', '1', '-pix_fmt', 'rgba', '-update', '1', outTmp
  ]), { timeout: 30000 });
  temps.forEach((t) => { try { fs.unlinkSync(t); } catch (err) { } });
  if (run.status !== 0 || !fs.existsSync(outTmp)) return false;
  try {
    fs.writeFileSync(path.join(UPLOAD_DIR, name), sealUploadBuffer(name, fs.readFileSync(outTmp)));
  } catch (err) {
    try { fs.unlinkSync(outTmp); } catch (err2) { }
    return false;
  }
  try { fs.unlinkSync(outTmp); } catch (err) { }
  chat.avatar = '/uploads/' + name;
  chat.avatarAuto = true;
  chat.avatarAt = now();
  return true;
}

/** 改完头像/群成员后重新拼一次群头像，并把新头像推给群成员 */
function refreshGroupAvatar(chat) {
  if (!chat || chat.type !== 'group') return false;
  /* 群主自己上传过群头像就不动它 */
  if (chat.avatar && !chat.avatarAuto) return false;
  const ok = buildGroupAvatar(chat);
  if (!ok) return false;
  (chat.memberIds || []).forEach((id) => {
    sendTo(id, { type: 'chat', action: 'updated', chat: chatSummary(chat, id) });
  });
  return true;
}


function str(v, max) {
  if (v == null) return '';
  const s = String(v).trim();
  return max ? s.slice(0, max) : s;
}

/* ---------------------------------------------------- 实名（转账页的脱敏实名）
   微信的规则：只留最后一个字，前面的字全用 * 挡住
   赵伟 → *伟    王秀芳 → **芳    欧阳娜娜 → ***娜
   单字（如「芳」）原样显示；没填实名就返回空串，界面上不显示括号。
   realNameHidden 为 false 时表示本人允许全显，就原样返回。 */
function realNameOf(u) {
  const s = str(u && u.realName, 24);
  if (!s) return '';
  if (u.realNameHidden === false) return s;
  if (s.length === 1) return s;
  return '*'.repeat(Math.min(s.length - 1, 6)) + s.slice(-1);
}

/* 用户能填的「图片地址」只允许：本站上传的文件、空、auto（聊天背景），
   以及很小的 data:image（1×1 那种）。外链一律不收 —— 防追踪像素、防混合内容。 */
function safeImageRef(v) {
  const s = String(v == null ? '' : v).trim();
  if (!s) return '';
  if (s === 'auto') return 'auto';
  if (/^\/uploads\/[A-Za-z0-9._-]+(\?[^\s"']*)?$/.test(s)) return s.split('?')[0];
  if (/^data:image\/(png|jpe?g|gif|webp);base64,[A-Za-z0-9+/=]{1,1500}$/i.test(s)) return s;
  return null;
}

/** 银行卡对外只回后四位，完整卡号不出服务器 */
function maskBankCard(c) {
  const n = String((c && c.number) || '');
  return {
    id: (c && c.id) || '', bank: (c && c.bank) || '', holder: (c && c.holder) || '',
    tail: (c && c.tail) || n.slice(-4), addedAt: (c && c.addedAt) || '',
    /* 微信银行卡那一页要的信息：卡类型、免密支付、限额、脱敏手机号 */
    type: (c && c.type) || '储蓄卡',
    noPin: !!(c && c.noPin),
    single: Number(c && c.single) || 0,
    day: Number(c && c.day) || 0,
    phoneMask: (c && c.phoneMask) || '',
    idCardTail: (c && c.idCardTail) || ''
  };
}

/** 状态还在不在（微信：24 小时后自动消失） */
function moodAlive(u) {
  if (!u) return false;
  if (!(u.moodText || u.moodIcon)) return false;
  const exp = Number(u.moodExpiresAt) || 0;
  if (!exp) return true;              // 老数据没写过期时间：当作永久（不折腾老用户）
  return exp > Date.now();
}

function publicUser(u) {
  if (!u) return null;
  /* 下面这些字段是用户档案里给「自己人」看的完整版 */
  return {
    region: u.region || '',
    gender: u.gender || '',
    id: u.id,
    username: u.username,
    nickname: u.nickname,
    realName: realNameOf(u),
    avatar: u.avatar || '',
    bio: u.bio || '',
    moodText: moodAlive(u) ? (u.moodText || '') : '',
    moodIcon: moodAlive(u) ? (u.moodIcon || '') : '',
    moodColor: moodAlive(u) ? (u.moodColor || '') : '',
    moodColor2: moodAlive(u) ? (u.moodColor2 || '') : '',
    /* 微信的状态分两层：状态名（摸鱼）+「说点什么」那句自定义文案。
       moodText 始终是「拿来做展示的那一句」（有文案用文案，没文案用状态名），
       所以老客户端不用改也能正常显示。 */
    moodLabel: moodAlive(u) ? (u.moodLabel || u.moodText || '') : '',
    moodCaption: moodAlive(u) ? (u.moodCaption || '') : '',
    moodExpiresAt: Number(u.moodExpiresAt) || 0,
    status: u.status || 'online',
    momentCover: u.momentCover || '',
    momentCoverPos: u.momentCoverPos === undefined ? 50 : u.momentCoverPos,
    chatBackground: u.chatBackground || '',
    birthday: u.birthday || '',
    createdAt: u.createdAt,
    alipayQr: u.alipayQr || '',          // 支付宝收款码图片（谁都能看，方便付款）
    bot: !!u.bot,
    botName: u.bot ? u.nickname : ''
  };
}

/* 陌生人能看到的「最小资料」：只有别人搜索你时用的那几项。
   实名、支付宝收款码、聊天背景、状态、封面这些属于隐私，只给自己和好友。 */
function publicUserBrief(u, viewerId, preFriendSet) {
  if (!u) return null;
  const self = viewerId && u.id === viewerId;
  const friend = !self && viewerId &&
    (preFriendSet ? preFriendSet.has(u.id) : friendIds(viewerId).includes(u.id));
  const out = {
    id: u.id,
    username: u.username,
    nickname: u.nickname,
    avatar: u.avatar || '',
    gender: u.gender || '',
    region: u.region || '',
    bio: u.bio || '',
    bot: !!u.bot
  };
  if (self || friend) {
    out.realName = realNameOf(u);
    out.moodText = moodAlive(u) ? (u.moodText || '') : '';
    out.moodIcon = moodAlive(u) ? (u.moodIcon || '') : '';
    out.moodColor = moodAlive(u) ? (u.moodColor || '') : '';
    out.moodColor2 = moodAlive(u) ? (u.moodColor2 || '') : '';
    out.moodLabel = moodAlive(u) ? (u.moodLabel || u.moodText || '') : '';
    out.moodCaption = moodAlive(u) ? (u.moodCaption || '') : '';
    out.moodExpiresAt = Number(u.moodExpiresAt) || 0;
    out.status = u.status || 'online';
    out.momentCover = u.momentCover || '';
    out.momentCoverPos = u.momentCoverPos === undefined ? 50 : u.momentCoverPos;
  }
  if (self) {
    out.chatBackground = u.chatBackground || '';
    out.alipayQr = u.alipayQr || '';
    out.createdAt = u.createdAt;
  }
  return out;
}

/* 列表里一次要拼几十个用户，每次都遍历 5000+ 条好友关系会拖慢接口，
   所以按「看的人」缓存 3 秒；好友关系变了最多 3 秒后自动生效。 */
const friendSetCache = new Map();       // viewerId -> { t, set }
function friendSetCached(viewerId) {
  if (!viewerId) return new Set();
  const t = Date.now();
  let c = friendSetCache.get(viewerId);
  if (!c || t - c.t > 3000) {
    c = { t, set: new Set(friendIds(viewerId)) };
    friendSetCache.set(viewerId, c);
  }
  if (friendSetCache.size > 3000) friendSetCache.clear();
  return c.set;
}

/* 名片 / 会话成员统一走这里：好友给完整资料，陌生人只给最小资料 */
function memberProfile(u, viewerId) {
  if (!u) return null;
  if (viewerId && u.id === viewerId) return publicUser(u);
  return friendSetCached(viewerId).has(u.id) ? publicUser(u) : publicUserBrief(u, viewerId);
}

/* ------------------------------------------------------- 性别（名片图标用）
   以后台注册 / 资料里填的为准；老账号（没有这个字段的）按昵称猜一个，
   猜不出来的按 id 固定分配，后台和「我的资料」里都能随时改。 */
const GENDER_FEMALE_CHARS = '燕娜婷丽娟敏静霞芳萍玲红梅雪莉倩颖慧悦妍欣瑶琳彤佳萱怡萌凤秀英花兰珍桂妹姐薇洁琪曦雅楠媛婧姝月荷莲蓉蕊晴柔甜梦妮'.split('');
const GENDER_MALE_CHARS = '伟强涛磊军明豪波峰鹏刚勇杰宇浩鑫超斌龙辉建国平东亮飞坤航阳帅岩兵海山成生林武文良庆博轩然帆华天佑泓栋锐彬旭铎铭希捷锋锦洲牧稼诚伯炯宏奎健威震旗'.split('');

function normalizeGender(v) {
  return v === 'male' || v === 'female' ? v : '';
}

/* 手机号：统一成 11 位纯数字（去空格、去 +86） */
function normalizePhone(v) {
  return String(v == null ? '' : v).replace(/[^0-9]/g, '').replace(/^86(?=1[3-9]\d{9}$)/, '');
}

/* 手机号登录的验证码（内存里存，5 分钟有效） */
const phoneCodes = new Map();

/* ============================================================
   短信通道（登录验证码 / 找回密码用）
   后台「短信」里填服务商和 Key，填完开关一开就是真发短信。
   支持：阿里云短信（推荐）· Twilio · 自定义 HTTP 接口（任何服务商都能接）
   没配的时候走「开发模式」：验证码只写服务器日志 + 局域网内直接显示，不真发。
   ============================================================ */
const SMS_FILE = 'sms.json';
const DEFAULT_SMS = {
  enabled: false,
  provider: 'aliyun',              // aliyun | twilio | custom
  signName: '',                    // 阿里云：短信签名（比如「某某科技」）
  templateCode: '',                // 阿里云：模板 ID（SMS_123456789）
  accessKeyId: '',
  accessKeySecret: '',
  twilioSid: '',
  twilioToken: '',
  twilioFrom: '',
  customUrl: '',                   // 自定义：POST 到这个地址，body 里有 phone / code
  customHeader: '',                // 自定义：额外请求头，形如 {"Authorization":"Bearer xxx"}
  note: '验证码 5 分钟有效，一分钟最多发一次'
};

function readSmsCfg() {
  const s = readJson(path.join(DATA_DIR, SMS_FILE), {});
  return Object.assign({}, DEFAULT_SMS, s || {});
}
function saveSmsCfg(patch) {
  const next = Object.assign({}, readSmsCfg(), patch || {});
  writeJson(path.join(DATA_DIR, SMS_FILE), next);
  return next;
}
function smsReady(cfg) {
  const c = cfg || readSmsCfg();
  if (!c.enabled) return false;
  if (c.provider === 'aliyun') return !!(c.accessKeyId && c.accessKeySecret && c.signName && c.templateCode);
  if (c.provider === 'twilio') return !!(c.twilioSid && c.twilioToken && c.twilioFrom);
  if (c.provider === 'custom') return !!c.customUrl;
  return false;
}

/** 真发短信。返回 { ok, error } */
async function sendSmsCode(phone, code, cfg) {
  const c = cfg || readSmsCfg();
  if (!smsReady(c)) return { ok: false, error: '短信没配置（后台「短信」里填一下）' };
  try {
    if (c.provider === 'aliyun') {
      /* 阿里云短信：RPC 签名（HMAC-SHA1），官方文档那套 */
      const params = {
        AccessKeyId: c.accessKeyId,
        Action: 'SendSms',
        Format: 'JSON',
        PhoneNumbers: phone,
        RegionId: 'cn-hangzhou',
        SignName: c.signName,
        SignatureMethod: 'HMAC-SHA1',
        SignatureNonce: String(Date.now()) + Math.random().toString(16).slice(2, 8),
        SignatureVersion: '1.0',
        TemplateCode: c.templateCode,
        TemplateParam: JSON.stringify({ code: code }),
        Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
        Version: '2017-05-25'
      };
      const enc = (s) => encodeURIComponent(s).replace(/\+/g, '%20').replace(/\*/g, '%2A').replace(/%7E/g, '~');
      const qs = Object.keys(params).sort().map((k) => enc(k) + '=' + enc(params[k])).join('&');
      const strToSign = 'GET&' + enc('/') + '&' + enc(qs);
      const sig = crypto.createHmac('sha1', c.accessKeySecret + '&').update(strToSign).digest('base64');
      const url = 'https://dysmsapi.aliyuncs.com/?Signature=' + enc(sig) + '&' + qs;
      const r = await fetch(url, { signal: AbortSignal.timeout(12000) });
      const d = await r.json().catch(() => ({}));
      if (d && d.Code === 'OK') return { ok: true };
      return { ok: false, error: '阿里云：' + ((d && (d.Message || d.Code)) || ('HTTP ' + r.status)) };
    }
    if (c.provider === 'twilio') {
      const body = new URLSearchParams({ To: '+' + phone, From: c.twilioFrom, Body: '【登录验证码】' + code + '，5 分钟内有效。' });
      const r = await fetch('https://api.twilio.com/2010-04-01/Accounts/' + c.twilioSid + '/Messages.json', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Authorization: 'Basic ' + Buffer.from(c.twilioSid + ':' + c.twilioToken).toString('base64')
        },
        body: body.toString(),
        signal: AbortSignal.timeout(12000)
      });
      if (r.ok) return { ok: true };
      const t = await r.text();
      return { ok: false, error: 'Twilio：HTTP ' + r.status + ' ' + String(t).slice(0, 120) };
    }
    if (c.provider === 'custom') {
      /* 自定义接口：POST JSON {phone, code} 到你自己的短信网关 */
      let headers = { 'Content-Type': 'application/json' };
      try { headers = Object.assign(headers, JSON.parse(c.customHeader || '{}')); } catch (err) { }
      const r = await fetch(c.customUrl, {
        method: 'POST', headers,
        body: JSON.stringify({ phone: phone, code: code, text: '【登录验证码】' + code + '，5 分钟内有效。' }),
        signal: AbortSignal.timeout(12000)
      });
      if (r.ok) return { ok: true };
      const t = await r.text();
      return { ok: false, error: '自定义接口：HTTP ' + r.status + ' ' + String(t).slice(0, 120) };
    }
    return { ok: false, error: '不认识的短信服务商' };
  } catch (e) {
    return { ok: false, error: '发送失败：' + (e && e.message) };
  }
}

function guessGender(nickname) {
  const s = String(nickname || '');
  for (const ch of s) if (GENDER_FEMALE_CHARS.indexOf(ch) >= 0) return 'female';
  for (const ch of s) if (GENDER_MALE_CHARS.indexOf(ch) >= 0) return 'male';
  return '';
}

function fallbackGender(id) {
  const s = String(id || '');
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h % 2 ? 'female' : 'male';
}

/** 只给「完全没有 gender 字段」的老账号补，注册时留空的不会被覆盖 */
function ensureGenders() {
  let changed = 0;
  db.users.forEach((u) => {
    if (u.gender === undefined) {
      u.gender = guessGender(u.nickname) || fallbackGender(u.id);
      changed++;
    }
  });
  if (changed) { try { saveUsers(); } catch (err) { /* 忽略 */ } }
  return changed;
}

/* ------------------------------------------------------------------ 存储 */

const db = {
  users: [], friendships: [], chats: [], reads: {},
  moments: [], momentViews: {}, announcements: [], secret: '',
  branding: null, faceRooms: [],
  transfers: [],
  security: { logins: [], events: [] }
};
let adminAuth = null;
let adminJustCreated = false;

const BRANDING_FILE = 'branding.json';
const PLUSPANEL_FILE = 'pluspanel.json';
/* 聊天输入栏「＋」面板：默认就是微信那两页（第一页按参考图：照片/拍摄/视频通话/位置 + 红包/礼物/转账/语音输入） */
const DEFAULT_PLUS_ITEMS = [
  { id: 'p01', label: '照片', icon: 'photo', action: 'photo', enabled: true },
  { id: 'p02', label: '拍摄', icon: 'camera', action: 'camera', enabled: true },
  { id: 'p03', label: '视频通话', icon: 'video', action: 'videocall', enabled: true },
  { id: 'p04', label: '位置', icon: 'location', action: 'location', enabled: true },
  { id: 'p05', label: '红包', icon: 'redpacket', action: 'redpacket', enabled: true },
  { id: 'p06', label: '礼物', icon: 'gift', action: 'gift', enabled: true },
  { id: 'p07', label: '转账', icon: 'transfer', action: 'transfer', enabled: true },
  { id: 'p08', label: '语音输入', icon: 'voice', action: 'voice', enabled: true },
  { id: 'p09', label: '收藏', icon: 'favorite', action: 'favorite', enabled: true },
  { id: 'p10', label: '名片', icon: 'card', action: 'card', enabled: true },
  { id: 'p11', label: '文件', icon: 'file', action: 'file', enabled: true },
  { id: 'p12', label: '音乐', icon: 'music', action: 'music', enabled: true },
  { id: 'p13', label: '卡券', icon: 'coupon', action: 'coupon', enabled: true },
  { id: 'p14', label: '群接龙', icon: 'chain', action: 'none', enabled: false },
  { id: 'p15', label: '群投票', icon: 'vote', action: 'none', enabled: false },
  { id: 'p16', label: '投屏', icon: 'screen', action: 'none', enabled: false }
];
const PLUS_ICONS = ['photo', 'camera', 'video', 'location', 'redpacket', 'gift', 'transfer', 'voice',
  'favorite', 'card', 'file', 'music', 'coupon', 'chain', 'vote', 'screen', 'star', 'heart', 'link', 'none'];
const PLUS_ACTIONS = ['photo', 'camera', 'videocall', 'location', 'redpacket', 'gift', 'transfer', 'voice',
  'favorite', 'card', 'file', 'music', 'coupon', 'none'];

/* ------------------------------------------------- 发现页（后台可以自由增删） ----------------
   group 相同的一串排在一张卡片里，group 变了就换一张卡（和微信发现页一样有分块）。
   action 决定点了去哪：moments=朋友圈 / news=腾讯新闻 / soon=占位页（显示「还没做」）。 */
const DISCOVER_FILE = 'discover.json';
const DISCOVER_ACTIONS = ['moments', 'news', 'nearby', 'shake', 'live', 'games', 'channels', 'soon'];
/* ---------------------------------------------- 我页（后台也能自由增删） */
const ME_PAGE_FILE = 'me-page.json';
const ME_ACTIONS = ['service', 'favorites', 'moments', 'works', 'stickers', 'settings', 'soon'];
const DEFAULT_ME_PAGE = [
  { id: 'm01', label: '服务', icon: 'i.wallet', color: '#59C47E', action: 'service', group: 1, enabled: true },
  { id: 'm02', label: '收藏', icon: 'i.star', color: '#4489EA', action: 'favorites', group: 2, enabled: true },
  { id: 'm03', label: '朋友圈', icon: 'i.album', color: '#7275E9', action: 'moments', group: 2, enabled: true },
  { id: 'm04', label: '作品', icon: 'i.works', color: '#3D83E7', action: 'works', group: 2, enabled: true },
  { id: 'm05', label: '表情', icon: 'i.sticker', color: '#F5C144', action: 'stickers', group: 3, enabled: true },
  { id: 'm06', label: '设置', icon: 'i.gear', color: '#3D83E7', action: 'settings', group: 4, enabled: true }
];
const DEFAULT_DISCOVER = [
  { id: 'd01', label: '朋友圈', icon: 'i.moments', color: '#4A90D9', action: 'moments', group: 1, enabled: true },
  { id: 'd02', label: '视频号', icon: 'i.channels', color: '#F2943B', action: 'soon', group: 2, enabled: true },
  { id: 'd03', label: '直播', icon: 'i.live', color: '#F4525B', action: 'soon', group: 2, enabled: true },
  { id: 'd04', label: '扫一扫', icon: 'i.scan', color: '#3D83E7', action: 'soon', group: 3, enabled: true },
  { id: 'd05', label: '摇一摇', icon: 'i.shake', color: '#4489EA', action: 'shake', group: 3, enabled: true },
  { id: 'd06', label: '看一看', icon: 'i.look', color: '#7275E9', action: 'soon', group: 4, enabled: true },
  { id: 'd07', label: '搜一搜', icon: 'i.searchRow', color: '#59C47E', action: 'soon', group: 4, enabled: true },
  { id: 'd08', label: '附近', icon: 'i.nearby', color: '#3D83E7', action: 'nearby', group: 5, enabled: true },
  { id: 'd09', label: '腾讯新闻', icon: 'i.searchBig', color: '#2C7BE5', action: 'news', group: 6, enabled: false },
  { id: 'd10', label: '游戏', icon: 'i.game', color: '#9A6AE8', action: 'soon', group: 7, enabled: true }
];

/* ------------------------------------------------- 服务页（我 → 服务）
   照着微信「服务」页做的：上面一张绿色大卡（收付款 / 钱包），
   下面一张张白卡，每张卡 = 一个分类标题 + 四列图标格子。
   尺寸是按参考图（iPhone @3x，420×912pt）量的：
     卡片左右各内缩 8pt、卡与卡之间空 8pt、绿卡高 144pt、
     白卡：标题行 48pt + 每行格子 93pt + 底部 19pt、图标格 4 列均分（列宽 = 卡宽/4）、
     图标 28pt、图标下间距 12pt、文字 13pt、圆角 7pt。
   这一页的内容（分类、格子、名称、图标、颜色、动作、开关）全都能在后台改。 */
const SERVICE_FILE = 'service.json';
/* ------------------------------------------------- 零钱页（我 → 服务 → 钱包 → 零钱）
   照着微信「零钱」页做的（整页白底）：中间一个金币图标 + 「我的零钱」+ 余额，
   底下贴着屏幕底部：充值（绿色按钮）、提现（浅灰按钮）、常见问题/账户升级服务、财付通说明。
   尺寸按参考图量的：金币 48、我的零钱 17pt、余额 44pt、
   按钮 183.7×47.7 圆角 8（中间空 16）、底部链接 13pt（#576B95）、说明 12pt（#B3B3B3）。 */
const BALANCE_FILE = 'balance-page.json';
/* 账单页的样式（图标大小、各种字号、行高）——后台「账单页」里调 */
const BILLS_FILE = 'bills-page.json';
const DEFAULT_BILLS_PAGE = {
  faq: [
    { q: '账单里的「支出」和「收入」怎么算？', a: '转出去的算支出；别人转给你、你已经收款的算收入。还没收款的那笔算「待收款」。' },
    { q: '为什么有的账单显示待对方收款？', a: '转账发出去后钱先挂着，对方点「收钱」才进他余额；24 小时没人收会自动退回你零钱。' },
    { q: '账单可以导出吗？', a: '可以。账单页右上角「⋯ → 导出账单（CSV）」，网页版会下载一个 Excel 能打开的表格。' }
  ],
  style: {
    iconSize: 48,      // 每行左边那个头像/图标
    titleSize: 17,     // 对方名字
    timeSize: 13,      // 时间（灰）
    amountSize: 16,    // 金额
    curSize: 0,        // 「¥」符号单独的字号（0 = 跟数字一样）
    amountWeight: 400, // 金额字重（300 细 / 400 常规 / 500 中 / 600 粗）—— 账单页默认比钱包页细一点
    showCur: false,    // 每行金额要不要带「¥」（参考图里是只显示 +/− 和数字，所以默认不带）
    monthSize: 15,     // 「2026年9月」那一行
    sumSize: 13,       // 「支出 ¥x 收入 ¥y」
    rowHeight: 80      // 每行高
  }
};
const BALANCE_ACTIONS = ['recharge', 'withdraw', 'bills', 'faq', 'upgrade', 'soon'];
const DEFAULT_BALANCE_PAGE = {
  navTitle: '零钱明细',          // 导航栏标题（照参考图：左边返回、中间「零钱明细」）
  title: '我的零钱',
  detailLabel: '零钱明细',
  note: '',                     // 比如「另有 ¥0.12 被有权机关冻结不可用」；留空 = 不显示
  recharge: { label: '充值', action: 'recharge' },
  withdraw: { label: '提现', action: 'withdraw' },
  links: [
    { id: 'bl1', label: '常见问题', action: 'faq', enabled: true },
    { id: 'bl2', label: '账户升级服务', action: 'upgrade', enabled: true }
  ],
  /* 底部那行说明：留空就不显示（以前写的是「本服务由财付通和微众银行提供」，用户要求去掉） */
  footer: '',
  /* 常见问题（后台能改）：点「常见问题」弹出来的问答 */
  faq: [
    { q: '零钱里的钱从哪来？', a: '别人转给你、收到的转账，钱会进零钱；发出去、转给别人会从零钱扣。' },
    { q: '零钱明细在哪看？', a: '钱包页右上角「账单」，或者零钱页右上角……都能看每一笔的进出、时间和对方。' },
    { q: '为什么有金额被冻结？', a: '被有权机关冻结的部分只能看不能用；解冻后会自动恢复到可用余额。' },
    { q: '提现要多久到账？', a: '提现到银行卡一般是 2 小时内到账，具体以银行处理时间为准。' }
  ],
  style: {
    bg: '#FFFFFF',
    circleSize: 64,              // 黄色圆形 ¥ 图标：直径
    circleColor: '#FFD100',
    yenSize: 24,                 // 圆里的「¥」字号
    yenColor: '#FFFFFF',
    titleSize: 18,
    amountSize: 64,              // 金额字号（重点）
    curSize: 28,                 // 「¥」符号单独的字号（微信那样比数字小）；0 = 跟数字一样
    noteSize: 16,
    noteColor: '#EB9400',        // 橙色提示
    padTop: 60,                  // 导航栏到圆的距离
    gapTitle: 24,                // 圆 →「我的零钱」
    gapAmount: 16,               // 「我的零钱」→ 金额
    gapNote: 20,                 // 金额 → 橙色提示
    btnWidth: 183.7,
    btnHeight: 47.7,
    btnRadius: 8,
    rechargeBg: '#07C160',
    rechargeInk: '#FFFFFF',
    withdrawBg: '#F2F2F2',
    withdrawInk: '#313131',
    linkSize: 13,
    linkColor: '#576B95',
    footerSize: 12,
    footerColor: '#B3B3B3'
  }
};
/* ------------------------------------------------- 钱包页（我 → 服务 → 钱包）
   照着微信「钱包」页做的：第一张全宽白卡 5 行、空 12pt、第二张白卡 2 行，
   底部两个蓝色链接（身份信息 / 支付设置）。尺寸按参考图量的：
     行高 56.6pt、图标 20pt 在 x=18、文字 x=56.7、箭头右边距 18、
     分隔线左边缩进 56pt、行标题 17pt、右边数值 16pt、底部链接 13pt */
const WALLET_FILE = 'wallet.json';
const WALLET_ACTIONS = ['bills', 'balance', 'card', 'service', 'identity', 'settings', 'score', 'soon'];
const DEFAULT_WALLET = {
  title: '钱包',
  right: { label: '账单', action: 'bills' },
  groups: [
    { id: 'wg1', enabled: true, items: [
      { id: 'w01', label: '零钱', value: '', valueKind: 'balance', note: '', icon: 'svc.wcoin', color: '#F5C000', action: 'balance', enabled: true },
      { id: 'w02', label: '经营账户', value: '¥0.00', note: '', icon: 'svc.wbiz', color: '#F5C000', action: 'soon', enabled: true },
      { id: 'w03', label: '零钱通', value: '', note: '收益率 1.01%', icon: 'svc.wfund', color: '#F5C000', action: 'soon', enabled: true },
      { id: 'w04', label: '银行卡', value: '', note: '', icon: 'svc.wcard', color: '#1180E0', action: 'card', enabled: true },
      { id: 'w05', label: '亲属卡', value: '', note: '', icon: 'svc.wfamily', color: '#FA9D3B', action: 'soon', enabled: true }
    ] },
    { id: 'wg2', enabled: true, items: [
      { id: 'w06', label: '支付分', value: '', note: '', icon: 'svc.wscore', color: '#2BC46E', action: 'soon', enabled: true },
      { id: 'w07', label: '客服中心', value: '', note: '', icon: 'svc.wservice', color: '#07C160', action: 'service', enabled: true }
    ] }
  ],
  footer: [
    { id: 'wf1', label: '身份信息', action: 'identity', enabled: true },
    { id: 'wf2', label: '支付设置', action: 'settings', enabled: true }
  ],
  /* 样式：行高、图标大小、各处字号、分隔线缩进 —— 后台能自己调 */
  style: {
    rowHeight: 56.3,
    iconSize: 20,
    iconLeft: 18,
    textLeft: 56.7,
    rightInset: 18,
    labelSize: 17,
    valueSize: 16,
    noteSize: 13,
    footerSize: 13,
    curSize: 0,               // 「¥」符号单独的字号（0 = 跟数字一样）
    groupGap: 12,
    dividerInset: 56,
    labelColor: '',          // 留空 = 跟主题
    valueColor: '#1A1A1A',
    noteColor: '#FA9D3B',
    footerColor: '#576B95',
    curSize: 0,              // 「¥」符号单独的号字大小（0 = 跟数字一样大）
    maskAmount: true,        // 金额默认打成星号（¥****）
    maskReveal: true         // 点一下金额能不能看
  }
};
/* 点一格去哪：pay=收付款 / wallet=钱包账单 / 其余先占位（soon） */
const SERVICE_ACTIONS = ['pay', 'wallet', 'soon'];
const DEFAULT_SERVICE = {
  title: '服务',
  card: {
    enabled: true,
    bg: '#2AAE67',
    left: { label: '收付款', sub: '向商家付款 · 二维码收款', icon: 'svc.pay', action: 'pay' },
    right: { label: '钱包', sub: '', icon: 'svc.wallet', action: 'wallet' }   // sub 留空 = 显示零钱余额
  },
  /* 页面底部那块账单卡 + 右上角「⋯」菜单的文案：以前写死在 App 里，
     现在后台「服务页 → 底部」能改（留空就用这里的默认值）。 */
  bottom: {
    billTitle: '账单',
    billAll: '全部账单',
    billRecharge: '充值',
    billEmpty: '还没有账单项',
    moreRefresh: '刷新账单',
    moreRecharge: '充值',
    moreCancel: '取消',
    soonTip: '「{label}」还没接后端，先把页面做出来'
  },
  /* 样式：绿卡背景（颜色 + 背景图）、图标大小、各处字体的大小和颜色，后台都能改。
     默认值就是照参考图量出来的那套数字，不动它就跟参考图一模一样。 */
  style: {
    cardImage: '',            // 绿卡背景图（填 /uploads/xxx.jpg 或网址；留空 = 只用底色）
    cardTextColor: '#FFFFFF',
    cardTextSize: 18,
    cardSubSize: 12,
    cardSubOpacity: 0.5,      // 绿卡小字的透明度（0~1）
    iconSize: 28,
    gridTitleSize: 14,
    gridTitleColor: '#7A7A7A',
    gridTextSize: 13,
    gridTextColor: '',        // 留空 = 跟主题（浅色黑、深色白）
    maskAmount: true,         // 绿卡右边的零钱要不要打成「¥****」
    maskReveal: true          // 打星号之后，点一下能不能看
  },
  groups: [
    {
      id: 'sg1', title: '金融理财', enabled: true, items: [
        { id: 'sv101', label: '信用卡还款', icon: 'svc.creditcard', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv102', label: '理财通', icon: 'svc.fund', color: '#10AEFF', action: 'soon', enabled: true },
        { id: 'sv103', label: '保险服务', icon: 'svc.insure', color: '#FA9D3B', action: 'soon', enabled: true }
      ]
    },
    {
      id: 'sg2', title: '生活服务', enabled: true, items: [
        { id: 'sv201', label: '手机充值', icon: 'svc.phone', color: '#1180E0', action: 'soon', enabled: true },
        { id: 'sv202', label: '生活缴费', icon: 'svc.utility', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv203', label: 'Q币充值', icon: 'svc.qcoin', color: '#10AEFF', action: 'soon', enabled: true },
        { id: 'sv204', label: '城市服务', icon: 'svc.city', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv205', label: '腾讯公益', icon: 'svc.charity', color: '#FA5151', action: 'soon', enabled: true },
        { id: 'sv206', label: '医疗健康', icon: 'svc.health', color: '#FA9D3B', action: 'soon', enabled: true }
      ]
    },
    {
      id: 'sg3', title: '交通出行', enabled: true, items: [
        { id: 'sv301', label: '出行服务', icon: 'svc.travel', color: '#1180E0', action: 'soon', enabled: true },
        { id: 'sv302', label: '火车票机票', icon: 'svc.train', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv303', label: '酒店民宿', icon: 'svc.hotel', color: '#FA9D3B', action: 'soon', enabled: true },
        { id: 'sv304', label: '滴滴出行', icon: 'svc.didi', color: '#07C160', action: 'soon', enabled: true }
      ]
    },
    {
      id: 'sg4', title: '购物消费', enabled: true, items: [
        { id: 'sv401', label: '京东购物', icon: 'svc.jd', color: '#FA5151', action: 'soon', enabled: true },
        { id: 'sv402', label: '美团外卖', icon: 'svc.meituan', color: '#FA9D3B', action: 'soon', enabled: true },
        { id: 'sv403', label: '电影演出', icon: 'svc.movie', color: '#1180E0', action: 'soon', enabled: true },
        { id: 'sv404', label: '拼多多', icon: 'svc.pdd', color: '#FA5151', action: 'soon', enabled: true }
      ]
    }
  ]
};

/* ---------------------------------------------------------------- 礼物 */
const GIFTS_FILE = 'gifts.json';
const DEFAULT_GIFTS = [
  { id: 'g01', name: '玫瑰', icon: '🌹', price: 1, category: '浪漫', enabled: true },
  { id: 'g02', name: '爱心', icon: '❤️', price: 2, category: '浪漫', enabled: true },
  { id: 'g03', name: '花束', icon: '💐', price: 5, category: '浪漫', enabled: true },
  { id: 'g04', name: '巧克力', icon: '🍫', price: 3, category: '浪漫', enabled: true },
  { id: 'g05', name: '蛋糕', icon: '🎂', price: 8, category: '浪漫', enabled: true },
  { id: 'g06', name: '钻戒', icon: '💍', price: 66, category: '浪漫', enabled: true },
  { id: 'g07', name: '礼物盒', icon: '🎁', price: 5, category: '通用', enabled: true },
  { id: 'g08', name: '气球', icon: '🎈', price: 1, category: '通用', enabled: true },
  { id: 'g09', name: '星星', icon: '⭐', price: 2, category: '通用', enabled: true },
  { id: 'g10', name: '点赞', icon: '👍', price: 1, category: '通用', enabled: true },
  { id: 'g11', name: '啤酒', icon: '🍺', price: 3, category: '通用', enabled: true },
  { id: 'g12', name: '皇冠', icon: '👑', price: 20, category: '豪华', enabled: true },
  { id: 'g13', name: '烟花', icon: '🎆', price: 30, category: '豪华', enabled: true },
  { id: 'g14', name: '火箭', icon: '🚀', price: 52, category: '豪华', enabled: true },
  { id: 'g15', name: '跑车', icon: '🏎️', price: 88, category: '豪华', enabled: true },
  { id: 'g16', name: '城堡', icon: '🏰', price: 199, category: '豪华', enabled: true }
];
const GIFT_ICON_PRESETS = ['🌹', '❤️', '💐', '🍫', '🎂', '💍', '🎁', '🎈', '⭐', '👍', '🍺', '👑',
  '🎆', '🚀', '🏎️', '🏰', '🧸', '🌻', '🍀', '🧧', '💎', '🦄', '🐱', '🐶'];

function giftNameOf(content) {
  try {
    const o = JSON.parse(String(content || '{}'));
    return String(o.name || o.icon || '礼物').slice(0, 20);
  } catch (err) { return '礼物'; }
}

/* 后台保存的礼物列表：名称 / 图标 / 价格 / 分类 / 开关都按这里来 */
/* ---------------------------------------------------------------- AI 助手
   数据里的「AI 助手」账号（username = ai）：谁给它发消息，它就用大模型回一句。
   配置存在 data/ai.json（密钥、模型、人设都能改），后台 /ai.html 也能改。 */
const AI_FILE = 'ai.json';
const AI_USERNAME = 'ai';
const AI_DEFAULT = {
  enabled: true,
  apiKey: '',
  baseUrl: 'https://api.deepseek.com',
  model: 'deepseek-chat',
  systemPrompt: '你是「AI 助手」，用户的好朋友。用中文聊天，回答要简短、自然、像微信里发消息，一般不超过 3 句话；不要用 Markdown 排版，不要长篇大论。',
  assistantPrompt: "你是「AI 助手」，这个 App 的**使用引导台**（就像商场里的引导台）：只回答“这个软件怎么用、功能在哪里”这类问题。\n【只答这些】\n· 找不到功能、问某功能在哪、怎么操作（换头像、改名字、换聊天背景、发朋友圈、加好友、建群、语音/视频通话、转账、红包、收付款、位置、表情、收藏、状态、二维码、退出登录…）\n· App 里各个入口在哪、点了会怎样、出错怎么办（比如“上不去”“没网”“发不出去”）\n【其它一律婉拒】跟软件使用无关的问题（天气、闲聊、写作、翻译、算数、新闻、情感、学习、代码…）都不用回答，直接说：“这个我帮不上～我只负责 App 里怎么用的问题，你可以问我某功能在哪、怎么操作。”\n【本 App 的功能地图，照这个回答，别说错】\n· 底部四个标签：微信（会话列表）、通讯录、发现、我\n· 微信（会话）：右上「＋」→ 发起群聊 / 加朋友 / 扫一扫 / 收付款；会话往左滑 → 标为未读 / 不显示 / 删除；点会话进聊天\n· 聊天页：左上「‹」返回；右上「⋯」→ 聊天背景 / 语音通话 / 视频通话 / 刷新消息 / 返回会话列表；底部输入框左边是语音，右边「＋」→ 照片、拍摄、视频通话、位置、红包、礼物、转账、语音输入、收藏、名片、文件、音乐、卡券；长按消息可以撤回/删除；点对方头像看名片\n· 通讯录：顶部有 新的朋友 / 仅聊天的朋友 / 标签 / 服务号 / 企业联系人 / 我的企业；下面是好友列表，右侧 A-Z 可以点或滑着跳；点头像看名片（名片里有 发消息 / 音视频通话 / 朋友圈）\n· 发现：朋友圈、视频号、直播、扫一扫、摇一摇、看一看、搜一搜、附近、游戏、小程序\n· 朋友圈：右上相机按钮 → 拍摄（直接开相机）/ 从手机相册选择；点头像看这个人名片；点右边「⋯」可以赞、评论、删除自己的动态；下拉刷新\n· 我：头像（点一下进个人信息）、名字、＋状态、朋友圈、服务、收藏、作品、表情、设置、二维码\n· 我 → 个人信息：头像、名字、性别、地区、手机号、微信号、我的二维码、拍一拍、签名、来电铃声\n· 我 → 设置：个人信息 / 外观（深色·浅色）/ 手机访问地址 / 安全中心（支付密码）/ 退出登录\n· 换头像：我 → 点头像（或个人信息 → 头像）；换名字/签名/性别/地区：我 → 个人信息\n· 换聊天背景：进聊天 → 右上「⋯」→ 聊天背景\n· 加好友：通讯录 → 新的朋友，或右上「＋」→ 加朋友（按微信号/用户名搜）\n· 收付款：我 → 服务 → 收付款（出付款码 / 收款码）；对方用「扫一扫」扫了就能付款，钱当时到账；余额、账单：聊天「＋」面板里的转账/红包，或 我 → 服务\n· 退出登录：我 → 设置 → 退出登录\n· 三个机器人：贾维斯AI（管家：提醒、天气、记账、代发消息、发朋友圈）、AI 助手（就是我，只答使用问题）、腾讯新闻（看新闻，发「新闻」）\n【说话方式】简短、直接、像引导台：先给“在哪”，再给“怎么点”，一般 2~4 句，必要时用「我 → 设置 → 退出登录」这种箭头路径；不要 Markdown 排版，不要长篇大论，不确定就说不确定。",
  housekeeperPrompt: "你是「贾维斯AI」，用户的英式管家（就像《唐顿庄园》里的管家那样）：称呼用户为「先生」，语气恭敬、沉稳、克制、干练，句子简短优雅，偶尔用「为您效劳」「如您所愿」「容我提醒」这类管家口吻；不要啰嗦、不要油腻、不要玩贵族梗。能力跟豆包一样：聊天、答疑、写作、翻译、算数、给建议、查最新资讯都行；先直接回答用户问的事，不要跑题、不要答非所问；需要最新信息就联网查一下再回答。另外你能替先生办事：提醒（「提醒我 8:30 开会」）、天气、记账、给好友发消息、发朋友圈、改签名——用户说这类话时照做即可；只有真的执行了动作才说完成，没执行就说「要不要我替您办」。用中文回答，一般不超过 4 句话，不要用 Markdown 排版。\n· 你能替用户在这个 App 里直接办事（说一句就执行）：给某人发消息、建群、加好友、改昵称、改签名、发朋友圈、给好友的朋友圈点赞和评论、置顶/免打扰/删除会话、清空聊天记录、查聊天记录、转账（会先让用户确认）、看账单、谁在线、提醒、天气、记账、点餐购物。用户说得不标准时，顺手告诉他一句标准说法（例如「给张三发消息 你好」「建个群 张三 李四」「给张三转 50」）。\n· 【必须遵守】上面这些事都是系统按用户的话真的去做的。你没看到系统执行结果时，绝对不要自己说「已经发了」「已经转了」「群建好了」这类话，只说「你可以这么说：…」让他再说一遍。\n· 点外卖 / 饿了 / 想吃什么 → 系统会**直接跳到美团外卖**（点了就跳，装了美团跳美团 App，没装就用 App 内网页），你不用贴任何网址。回一句「这就给你跳美团外卖，想吃XX在里边搜一下就行」；用户没说吃什么，就先问一句想吃什么。注意：点外卖只说美团外卖，不要提淘宝闪购，淘宝闪购不是点外卖的。\n· 买东西 / 购物 / 想买什么 → 系统会**直接跳到淘宝**（带搜索关键词）。同样不要贴网址，回一句「这就给你跳淘宝，搜XX就能买」就行。\n· 【不要再做的事】不要在回复里贴一串网址，也不要说「复制这个链接」。要跳转就用上面这些标准说法让系统去跳。",
  history: 12,
  maxTokens: 800,
  temperature: 1.1
};
/* ---------------------------------------------------------------- 状态（心情状态，主页「＋ 状态」进去选）
   分类和每个状态都可以在后台加，前台按分类铺成一格格 */
const STATUS_FILE = 'statuses.json';
/* 每个状态一套颜色，前台选完连「我」页的头像卡都会跟着变 */
const STATUS_COLORS = ['#F2725A', '#F0A73B', '#E8C84A', '#7FBF4D', '#4FC08D', '#3FB5C4',
  '#4A9BE0', '#6C7BE0', '#9A6AE8', '#D268C8', '#E86A9A', '#8A8F98'];
const STATUS_DEFAULT = [
  { id: 'c1', name: '心情想法', color: '#6f8a38', enabled: true, items: [
    { id: 's1', icon: '😄', label: '美滋滋', color: '#F2725A', color2: '#F0A73B' }, { id: 's2', icon: '🌤️', label: '等晴天', color: '#3FB5C4', color2: '#4A9BE0' },
    { id: 's3', icon: '😳', label: '发呆', color: '#E8C84A', color2: '#F0A73B' }, { id: 's4', icon: '💭', label: '胡思乱想', color: '#9A6AE8', color2: '#6C7BE0' },
    { id: 's5', icon: '😔', label: 'emo', color: '#6C7BE0', color2: '#4A9BE0' }, { id: 's6', icon: '😤', label: '元气满满', color: '#F0A73B', color2: '#E8C84A' }
  ] },
  { id: 'c2', name: '工作学习', color: '#5f7f4a', enabled: true, items: [
    { id: 's7', icon: '🧱', label: '搬砖', color: '#D268C8', color2: '#E86A9A' }, { id: 's8', icon: '✈️', label: '出差', color: '#4A9BE0', color2: '#3FB5C4' },
    { id: 's9', icon: '🐟', label: '摸鱼', color: '#4FC08D', color2: '#7FBF4D' }, { id: 's10', icon: '📵', label: '开会中', color: '#8A8F98', color2: '#6C7BE0' },
    { id: 's11', icon: '📖', label: '学习中', color: '#7FBF4D', color2: '#4FC08D' }, { id: 's12', icon: '💻', label: '写代码', color: '#6C7BE0', color2: '#9A6AE8' }
  ] },
  { id: 'c3', name: '活动', color: '#7a8a3c', enabled: true, items: [
    { id: 's13', icon: '🏃', label: '运动', color: '#F2725A', color2: '#E86A9A' }, { id: 's14', icon: '🍚', label: '干饭', color: '#F0A73B', color2: '#F2725A' },
    { id: 's15', icon: '🛍️', label: '逛街', color: '#E86A9A', color2: '#D268C8' }, { id: 's16', icon: '🎮', label: '打游戏', color: '#9A6AE8', color2: '#D268C8' },
    { id: 's17', icon: '🀄', label: '打牌', color: '#D268C8', color2: '#9A6AE8' }, { id: 's18', icon: '🏀', label: '打球', color: '#4A9BE0', color2: '#4FC08D' }
  ] },
  { id: 'c4', name: '休息', color: '#6b8a4e', enabled: true, items: [
    { id: 's19', icon: '😴', label: '睡觉', color: '#6C7BE0', color2: '#3FB5C4' }, { id: 's20', icon: '🌞', label: '晒太阳', color: '#E8C84A', color2: '#F2725A' },
    { id: 's21', icon: '🧋', label: '喝奶茶', color: '#E86A9A', color2: '#F0A73B' }, { id: 's22', icon: '🎵', label: '听歌', color: '#4FC08D', color2: '#3FB5C4' },
    { id: 's23', icon: '🚶', label: '散步', color: '#7FBF4D', color2: '#E8C84A' }, { id: 's24', icon: '🛁', label: '泡澡', color: '#3FB5C4', color2: '#9A6AE8' }
  ] }
];

function normalizeStatus(list) {
  const src = Array.isArray(list) && list.length ? list : STATUS_DEFAULT;
  // 老数据里没有 color2 的，按标签去默认表里补上，保证都渐变
  const defColor2 = {};
  STATUS_DEFAULT.forEach((c) => (c.items || []).forEach((it) => { if (it.color2) defColor2[it.label] = it.color2; }));
  return src.slice(0, 30).map((c, i) => {
    const cat = c && typeof c === 'object' ? c : {};
    const items = Array.isArray(cat.items) ? cat.items : [];
    return {
      id: String(cat.id || '').slice(0, 24) || ('c' + (i + 1)),
      name: String(cat.name == null ? '' : cat.name).trim().slice(0, 12) || ('分类' + (i + 1)),
      color: /^#[0-9a-f]{6}$/i.test(String(cat.color || '')) ? String(cat.color) : '#6f8a38',
      enabled: cat.enabled === undefined ? true : !!cat.enabled,
      items: items.slice(0, 24).map((it, k) => {
        const o = it && typeof it === 'object' ? it : {};
        return {
          id: String(o.id || '').slice(0, 24) || ('s' + (i + 1) + '_' + (k + 1)),
          icon: String(o.icon == null ? '' : o.icon).trim().slice(0, 8) || '🙂',
          label: String(o.label == null ? '' : o.label).trim().slice(0, 10) || ('状态' + (k + 1)),
          color: /^#[0-9a-f]{6}$/i.test(String(o.color || ''))
            ? String(o.color)
            : STATUS_COLORS[(i * 6 + k) % STATUS_COLORS.length],
          color2: /^#[0-9a-f]{6}$/i.test(String(o.color2 || ''))
            ? String(o.color2)
            : (defColor2[o.label] || STATUS_COLORS[(i * 6 + k + 3) % STATUS_COLORS.length])
        };
      })
    };
  });
}

/* ---------------------------------------------------------------- 表情包
   本地表情包（后台自己加）+ 第三方图源（Tenor / Giphy / 自定义接口，服务端代跑，手机不用翻墙） */
const STICKER_FILE = 'stickers.json';
/* 「我的表情」：每个人自己添加了哪些表情包 / 哪些单个表情（微信「我 → 表情」那套） */
const STICKER_USER_FILE = 'stickers-user.json';
let stickerUserCache = null;

function readStickerUser() {
  if (stickerUserCache) return stickerUserCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, STICKER_USER_FILE), 'utf8')); } catch (e) { raw = {}; }
  stickerUserCache = { byUser: (raw && typeof raw.byUser === 'object' && raw.byUser) ? raw.byUser : {} };
  return stickerUserCache;
}

function saveStickerUser() {
  if (!stickerUserCache) return;
  try { writeJson(path.join(DATA_DIR, STICKER_USER_FILE), stickerUserCache); } catch (e) { }
}

/** 某个人的表情库（没设置过就是空的：微信新号也是这样，得自己去商店添加） */
function myStickers(userId) {
  const dbm = readStickerUser();
  const row = dbm.byUser[userId] || {};
  return {
    packs: Array.isArray(row.packs) ? row.packs.map((x) => String(x).slice(0, 24)).slice(0, 40) : [],
    singles: Array.isArray(row.singles) ? row.singles.map((x) => String(x).slice(0, 400)).filter(Boolean).slice(0, 120) : [],
    recent: Array.isArray(row.recent) ? row.recent.map((x) => String(x).slice(0, 400)).filter(Boolean).slice(0, 30) : []
  };
}

function setMyStickers(userId, row) {
  const dbm = readStickerUser();
  dbm.byUser[userId] = row;
  saveStickerUser();
  return row;
}
const STICKER_PROVIDERS = ['off', 'tenor', 'giphy', 'custom'];
const STICKER_PACKS_DEFAULT = [
  { id: 's1', name: '小黄脸', icon: '😀', enabled: true, stickers: ['😀', '😃', '😄', '😁', '😆', '😅', '😂', '🤣', '😊', '😇', '🙂', '😉', '😍', '🥰', '😘', '😋', '😜', '🤪', '🤗', '🤔', '🤨', '😐', '😏', '😒', '🙄', '😴', '😷', '🤒', '🥳', '😎', '🤓', '😭'] },
  { id: 's2', name: '手势', icon: '👍', enabled: true, stickers: ['👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '👏', '🙌', '🙏', '💪', '👊', '✊', '🤝', '👋', '☝️', '👆', '👇', '👈', '👉', '🖐️', '✋', '🤙', '🫰'] },
  { id: 's3', name: '爱心', icon: '❤️', enabled: true, stickers: ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '😻', '🫶'] },
  { id: 's4', name: '动物', icon: '🐱', enabled: true, stickers: ['🐱', '🐶', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🦄', '🐝'] },
  { id: 's5', name: '开心日常', icon: '🎉', enabled: true, stickers: ['🎉', '🎊', '🎁', '🎂', '🍰', '🍺', '🥳', '🍀', '🌈', '☀️', '🌙', '⚡', '🔥', '✨', '💯', '🆗', '🙆', '🙅', '💃', '🕺'] }
];

function normalizeStickers(st) {
  const src = st && typeof st === 'object' ? st : {};
  const packsSrc = Array.isArray(src.packs) && src.packs.length ? src.packs : STICKER_PACKS_DEFAULT;
  const packs = packsSrc.slice(0, 40).map((p, i) => {
    const pack = p && typeof p === 'object' ? p : {};
    const list = Array.isArray(pack.stickers) ? pack.stickers : [];
    return {
      id: String(pack.id || '').slice(0, 24) || ('s' + (i + 1)),
      name: String(pack.name == null ? '' : pack.name).trim().slice(0, 12) || ('表情包' + (i + 1)),
      icon: String(pack.icon == null ? '' : pack.icon).trim().slice(0, 8) || '😀',
      enabled: pack.enabled === undefined ? true : !!pack.enabled,
      stickers: list.map((x) => String(x == null ? '' : x).trim().slice(0, 400)).filter(Boolean).slice(0, 120)
    };
  });
  const tp = src.thirdParty && typeof src.thirdParty === 'object' ? src.thirdParty : {};
  return {
    packs: packs,
    thirdParty: {
      provider: STICKER_PROVIDERS.indexOf(tp.provider) >= 0 ? tp.provider : 'off',
      apiKey: String(tp.apiKey || '').slice(0, 200),
      urlTemplate: String(tp.urlTemplate || '').slice(0, 500),
      limit: Math.min(50, Math.max(4, Number(tp.limit) || 24))
    }
  };
}

/** 第三方返回统一解析成 [{ id, url, title }] */
function parseThirdParty(provider, data) {
  const out = [];
  const push = (url, title) => {
    if (url && /^https?:\/\//i.test(url)) out.push({ id: 'x' + out.length, url: url, title: String(title || '表情').slice(0, 40) });
  };
  try {
    if (provider === 'tenor' && data && Array.isArray(data.results)) {
      data.results.forEach((r) => {
        const f = r.media_formats || {};
        push((f.tinygif || f.gif || f.mediumgif || {}).url, r.content_description || r.title);
      });
    } else if (provider === 'giphy' && data && Array.isArray(data.data)) {
      data.data.forEach((g) => {
        const im = g.images || {};
        push((im.fixed_height || im.downsized || im.original || {}).url, g.title);
      });
    } else {
      const found = [];
      const walk = (node, depth) => {
        if (found.length || depth > 4 || !node) return;
        if (Array.isArray(node)) {
          const objs = node.filter((n) => n && typeof n === 'object');
          if (objs.length && objs.some((o) => o.url || o.image || o.imageUrl || (o.images && typeof o.images === 'object'))) { found.push(objs); return; }
          node.slice(0, 3).forEach((n) => walk(n, depth + 1));
          return;
        }
        if (typeof node === 'object') Object.keys(node).forEach((k) => walk(node[k], depth + 1));
      };
      walk(data, 0);
      (found[0] || []).forEach((o) => {
        const url = o.url || o.image || o.imageUrl || (o.images ? ((o.images.fixed_height || o.images.original || {}).url) : '');
        push(url, o.title || o.description || o.name);
      });
    }
  } catch (err) { /* 结构不认就当没结果 */ }
  return out.slice(0, 50);
}

/** 拼第三方请求地址（自定义接口支持 {q} {key} {limit} 占位符） */
function thirdPartyUrl(tp, keyword) {
  const q = encodeURIComponent(keyword || '开心');
  if (tp.provider === 'tenor') {
    return 'https://tenor.googleapis.com/v2/search?q=' + q + '&key=' + encodeURIComponent(tp.apiKey) + '&limit=' + tp.limit + '&media_filter=tinygif,gif';
  }
  if (tp.provider === 'giphy') {
    return 'https://api.giphy.com/v1/gifs/search?api_key=' + encodeURIComponent(tp.apiKey) + '&q=' + q + '&limit=' + tp.limit + '&rating=pg-13';
  }
  if (tp.provider === 'custom' && tp.urlTemplate) {
    return tp.urlTemplate.replace(/\{q\}/g, q).replace(/\{key\}/g, encodeURIComponent(tp.apiKey)).replace(/\{limit\}/g, tp.limit);
  }
  return '';
}

function normalizeGifts(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_GIFTS;
  return src.slice(0, 120).map((it, i) => {
    const g = it && typeof it === 'object' ? it : {};
    const price = Number(g.price);
    return {
      id: String(g.id || '').slice(0, 24) || ('g' + (i + 1)),
      name: String(g.name == null ? '' : g.name).trim().slice(0, 12) || ('礼物' + (i + 1)),
      icon: String(g.icon == null ? '' : g.icon).trim().slice(0, 8) || '🎁',
      price: isFinite(price) && price >= 0 ? Math.min(999999, Math.round(price)) : 1,
      category: String(g.category == null ? '' : g.category).trim().slice(0, 8) || '通用',
      enabled: g.enabled === undefined ? true : !!g.enabled
    };
  });
}

/* 发现页那几行洗干净：名称、图标、颜色、动作、分组、顺序、开关都以后台为准 */
function normalizeDiscover(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_DISCOVER;
  return normalizeRowList(src, DISCOVER_ACTIONS, DEFAULT_DISCOVER);
}

/** 发现页 / 我页 这类「一行一行」的配置，洗干净的逻辑是一样的 */
function normalizeRowList(list, actions, defaults) {
  const src = Array.isArray(list) && list.length ? list : defaults;
  return src.slice(0, 30).map((it, i) => {
    const item = it && typeof it === 'object' ? it : {};
    const label = String(item.label == null ? '' : item.label).trim().slice(0, 12) || ('功能' + (i + 1));
    const action = actions.indexOf(item.action) >= 0 ? item.action : actions[actions.length - 1];
    const color = /^#[0-9a-fA-F]{6}$/.test(String(item.color || '')) ? String(item.color) : '#4A90D9';
    let group = Number(item.group);
    if (!Number.isFinite(group) || group < 1) group = i + 1;
    return {
      id: String(item.id || '').slice(0, 24) || ('d' + (i + 1) + '_' + Date.now().toString(36).slice(-4)),
      label: label,
      icon: String(item.icon || '').slice(0, 60),          // 图标标识（UI 图标页里那些 key）
      svg: String(item.svg || '').slice(0, 20000),          // 也可以直接塞一段 svg
      color: color,
      action: action,
      group: Math.round(group),
      enabled: item.enabled === undefined ? true : !!item.enabled
    };
  });
}

function normalizeMePage(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_ME_PAGE;
  return normalizeRowList(src, ME_ACTIONS, DEFAULT_ME_PAGE);
}

/* 账单页样式洗干净（图标大小、字号、行高） */
function normalizeBillsPage(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const def = DEFAULT_BILLS_PAGE.style;
  const faqSrc = Array.isArray(src.faq) ? src.faq : DEFAULT_BILLS_PAGE.faq;
  const faq = faqSrc.slice(0, 10).map((it) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      q: String(o.q == null ? '' : o.q).trim().slice(0, 60),
      a: String(o.a == null ? '' : o.a).trim().slice(0, 300)
    };
  }).filter((x) => x.q && x.a);
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  return {
    faq: faq,
    style: {
      iconSize: num(st.iconSize, 28, 80, def.iconSize),
      titleSize: num(st.titleSize, 11, 30, def.titleSize),
      timeSize: num(st.timeSize, 9, 24, def.timeSize),
      amountSize: num(st.amountSize, 10, 30, def.amountSize),
      curSize: num(st.curSize, 0, 60, def.curSize),
      amountWeight: num(st.amountWeight, 200, 800, def.amountWeight),
      showCur: st.showCur === undefined ? def.showCur : !!st.showCur,
      monthSize: num(st.monthSize, 11, 28, def.monthSize),
      sumSize: num(st.sumSize, 9, 24, def.sumSize),
      rowHeight: num(st.rowHeight, 56, 140, def.rowHeight)
    }
  };
}

/* 零钱页配置洗干净：文案、两个按钮、底部链接、说明、样式 */
function normalizeBalancePage(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const def = DEFAULT_BALANCE_PAGE;
  const str = (v, len, fallback) => {
    const s = String(v == null ? '' : v).trim().slice(0, len);
    return s || fallback;
  };
  const btn = (o, fallback) => {
    const b = o && typeof o === 'object' ? o : {};
    return {
      label: str(b.label, 12, fallback.label),
      action: BALANCE_ACTIONS.indexOf(b.action) >= 0 ? b.action : fallback.action
    };
  };
  const linksSrc = Array.isArray(src.links) && src.links.length ? src.links : def.links;
  const links = linksSrc.slice(0, 4).map((it, i) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      id: String(o.id || '').slice(0, 24) || ('bl' + (i + 1)),
      label: str(o.label, 12, '链接' + (i + 1)),
      action: BALANCE_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
      enabled: o.enabled === undefined ? true : !!o.enabled
    };
  });
  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const faqSrc = Array.isArray(src.faq) ? src.faq : def.faq;
  const faq = faqSrc.slice(0, 10).map((it) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      q: String(o.q == null ? '' : o.q).trim().slice(0, 60),
      a: String(o.a == null ? '' : o.a).trim().slice(0, 300)
    };
  }).filter((x) => x.q && x.a);
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  const col = (v, fallback) => (/^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? String(v) : fallback);
  const style = {
    bg: col(st.bg, def.style.bg),
    circleSize: num(st.circleSize, 40, 160, def.style.circleSize),
    circleColor: col(st.circleColor, def.style.circleColor),
    yenSize: num(st.yenSize, 12, 80, def.style.yenSize),
    yenColor: col(st.yenColor, def.style.yenColor),
    titleSize: num(st.titleSize, 11, 30, def.style.titleSize),
    amountSize: num(st.amountSize, 20, 120, def.style.amountSize),
    curSize: num(st.curSize, 0, 120, def.style.curSize),
    noteSize: num(st.noteSize, 9, 26, def.style.noteSize),
    noteColor: col(st.noteColor, def.style.noteColor),
    padTop: num(st.padTop, 0, 200, def.style.padTop),
    gapTitle: num(st.gapTitle, 0, 100, def.style.gapTitle),
    gapAmount: num(st.gapAmount, 0, 100, def.style.gapAmount),
    gapNote: num(st.gapNote, 0, 100, def.style.gapNote),
    btnWidth: num(st.btnWidth, 100, 360, def.style.btnWidth),
    btnHeight: num(st.btnHeight, 32, 80, def.style.btnHeight),
    btnRadius: num(st.btnRadius, 0, 30, def.style.btnRadius),
    rechargeBg: col(st.rechargeBg, def.style.rechargeBg),
    rechargeInk: col(st.rechargeInk, def.style.rechargeInk),
    withdrawBg: col(st.withdrawBg, def.style.withdrawBg),
    withdrawInk: col(st.withdrawInk, def.style.withdrawInk),
    linkSize: num(st.linkSize, 9, 24, def.style.linkSize),
    linkColor: col(st.linkColor, def.style.linkColor),
    footerSize: num(st.footerSize, 9, 24, def.style.footerSize),
    footerColor: col(st.footerColor, def.style.footerColor)
  };
  return {
    navTitle: str(src.navTitle, 12, def.navTitle),
    title: str(src.title, 12, def.title),
    detailLabel: str(src.detailLabel, 12, def.detailLabel),
    note: String(src.note == null ? '' : src.note).trim().slice(0, 60),
    recharge: btn(src.recharge, def.recharge),
    withdraw: btn(src.withdraw, def.withdraw),
    links: links,
    footer: src.footer === undefined ? def.footer : String(src.footer == null ? '' : src.footer).trim().slice(0, 60),
    faq: faq,
    style: style
  };
}

/* 钱包页配置洗干净：标题、右上角按钮、两张卡的格子、底部链接、样式 */
/* ============================================================
   IM 模块（后台「IM 模块」那一页能改）
   聊天总开关、各类消息允不允许、陌生人能不能私聊、撤回时限、
   单条字数上限、能不能建群 / 群人数上限、在线状态显示。
   改完存 data/im.json，App 侧发消息时会按这里的规则拦。
   ============================================================ */
const IM_FILE = 'im.json';
const DEFAULT_IM = {
  enabled: true,          // 聊天总开关
  text: true,             // 文字
  image: true,            // 图片
  audio: true,            // 语音
  video: true,            // 视频/视频通话
  file: true,             // 文件
  location: true,         // 位置
  redpacket: true,        // 红包
  transfer: true,         // 转账
  gift: true,             // 礼物
  allowStranger: false,   // 不是好友也能私聊
  recallMinutes: 2,       // 多久内能撤回（0 = 不许撤回）
  maxTextLen: 4000,       // 单条文字最多多少字
  allowCreateGroup: true, // 允许建群
  maxGroupMembers: 100,   // 群人数上限
  onlineStatus: true,     // 显示在线状态
  readReceipt: false      // 已读回执
};

function normalizeIm(src) {
  const s = src && typeof src === 'object' ? (src.im && typeof src.im === 'object' ? src.im : src) : {};
  const out = {};
  Object.keys(DEFAULT_IM).forEach((k) => {
    const def = DEFAULT_IM[k];
    const v = s[k];
    if (typeof def === 'boolean') out[k] = v === undefined ? def : !!v;
    else out[k] = (v === undefined || v === null || isNaN(Number(v))) ? def
      : Math.max(0, Math.min(k === 'maxTextLen' ? 20000 : 10000, Math.round(Number(v))));
  });
  return out;
}

function readIm() {
  try {
    return normalizeIm(readJson(path.join(DATA_DIR, IM_FILE), DEFAULT_IM));
  } catch (e) {
    return Object.assign({}, DEFAULT_IM);
  }
}

function saveIm(patch) {
  const next = normalizeIm(Object.assign({}, readIm(), patch || {}));
  writeJson(path.join(DATA_DIR, IM_FILE), next);
  return next;
}

/* 发消息前按 IM 模块的开关拦一道：返回错误文案，允许就返回 '' */
function imKindBlocked(kind) {
  const im = readIm();
  if (!im.enabled) return '管理员暂时关闭了聊天';
  const map = {
    text: im.text, image: im.image, audio: im.audio, file: im.file,
    location: im.location, redpacket: im.redpacket, transfer: im.transfer, gift: im.gift
  };
  if (map[kind] === false) return '这个类型的消息被管理员关闭了';
  if (kind === 'file' && im.video === false) {
    /* 视频文件也归「视频」那一栏管 */
  }
  return '';
}

function normalizeWallet(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const def = DEFAULT_WALLET;
  const title = String(src.title == null ? '' : src.title).trim().slice(0, 12) || def.title;
  const rightSrc = src.right && typeof src.right === 'object' ? src.right : {};
  const right = {
    label: String(rightSrc.label == null ? '' : rightSrc.label).trim().slice(0, 12) || def.right.label,
    action: WALLET_ACTIONS.indexOf(rightSrc.action) >= 0 ? rightSrc.action : def.right.action
  };

  const normItem = (it, i, gi) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      id: String(o.id || '').slice(0, 24) || ('w' + (gi + 1) + '_' + (i + 1)),
      label: String(o.label == null ? '' : o.label).trim().slice(0, 12) || ('项目' + (i + 1)),
      value: String(o.value == null ? '' : o.value).trim().slice(0, 24),
      valueKind: o.valueKind === 'balance' ? 'balance' : '',
      note: String(o.note == null ? '' : o.note).trim().slice(0, 24),
      icon: String(o.icon || '').slice(0, 60),
      svg: String(o.svg || '').slice(0, 20000),
      color: /^#[0-9a-fA-F]{6}$/.test(String(o.color || '')) ? String(o.color) : '#1180E0',
      action: WALLET_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
      mask: o.mask === undefined ? true : !!o.mask,     // 这一行的金额要不要打星号
      enabled: o.enabled === undefined ? true : !!o.enabled
    };
  };
  const groupsSrc = Array.isArray(src.groups) && src.groups.length ? src.groups : def.groups;
  const groups = groupsSrc.slice(0, 12).map((g, gi) => {
    const g0 = g && typeof g === 'object' ? g : {};
    return {
      id: String(g0.id || '').slice(0, 24) || ('wg' + (gi + 1)),
      enabled: g0.enabled === undefined ? true : !!g0.enabled,
      items: (Array.isArray(g0.items) ? g0.items : []).slice(0, 20).map((it, i) => normItem(it, i, gi))
    };
  });

  const footerSrc = Array.isArray(src.footer) && src.footer.length ? src.footer : def.footer;
  const footer = footerSrc.slice(0, 6).map((it, i) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      id: String(o.id || '').slice(0, 24) || ('wf' + (i + 1)),
      label: String(o.label == null ? '' : o.label).trim().slice(0, 12) || ('链接' + (i + 1)),
      action: WALLET_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
      enabled: o.enabled === undefined ? true : !!o.enabled
    };
  });

  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  const col = (v, fallback) => (/^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? String(v) : fallback);
  const style = {
    rowHeight: num(st.rowHeight, 40, 100, def.style.rowHeight),
    iconSize: num(st.iconSize, 12, 40, def.style.iconSize),
    iconLeft: num(st.iconLeft, 0, 60, def.style.iconLeft),
    textLeft: num(st.textLeft, 20, 120, def.style.textLeft),
    rightInset: num(st.rightInset, 0, 60, def.style.rightInset),
    labelSize: num(st.labelSize, 11, 30, def.style.labelSize),
    valueSize: num(st.valueSize, 10, 30, def.style.valueSize),
    noteSize: num(st.noteSize, 9, 26, def.style.noteSize),
    footerSize: num(st.footerSize, 9, 26, def.style.footerSize),
    groupGap: num(st.groupGap, 0, 40, def.style.groupGap),
    dividerInset: num(st.dividerInset, 0, 200, def.style.dividerInset),
    labelColor: /^#[0-9a-fA-F]{6}$/.test(String(st.labelColor || '')) ? String(st.labelColor) : '',
    valueColor: col(st.valueColor, def.style.valueColor),
    noteColor: col(st.noteColor, def.style.noteColor),
    footerColor: col(st.footerColor, def.style.footerColor),
    curSize: num(st.curSize, 0, 120, def.style.curSize)
  };
  style.maskAmount = st.maskAmount === undefined ? def.style.maskAmount : !!st.maskAmount;
  style.maskReveal = st.maskReveal === undefined ? def.style.maskReveal : !!st.maskReveal;
  return { title: title, right: right, groups: groups, footer: footer, style: style };
}

/* 服务页配置洗干净：标题、绿卡两半、每个分类里的格子，全都按后台存的来。
   格子沿用「发现页 / 我页」那一套字段（label / icon / svg / color / action / enabled），
   所以后台的图标选择器、颜色选择器可以直接复用。 */
function normalizeService(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const def = DEFAULT_SERVICE;
  const title = String(src.title == null ? '' : src.title).trim().slice(0, 12) || def.title;

  const normHalf = (half, fallback) => {
    const it = half && typeof half === 'object' ? half : {};
    return {
      label: String(it.label == null ? '' : it.label).trim().slice(0, 12) || fallback.label,
      sub: String(it.sub == null ? '' : it.sub).trim().slice(0, 30),
      icon: String(it.icon || fallback.icon).slice(0, 60),
      svg: String(it.svg || '').slice(0, 20000),
      action: SERVICE_ACTIONS.indexOf(it.action) >= 0 ? it.action : fallback.action
    };
  };
  const cardSrc = src.card && typeof src.card === 'object' ? src.card : {};
  const card = {
    enabled: cardSrc.enabled === undefined ? true : !!cardSrc.enabled,
    bg: /^#[0-9a-fA-F]{6}$/.test(String(cardSrc.bg || '')) ? String(cardSrc.bg) : def.card.bg,
    left: normHalf(cardSrc.left, def.card.left),
    right: normHalf(cardSrc.right, def.card.right)
  };

  const groupsSrc = Array.isArray(src.groups) && src.groups.length ? src.groups : def.groups;

  /* 底部那块（账单卡 + ⋯ 菜单）的文案：空字符串就回默认值，最多 20 个字 */
  const bSrc = src.bottom && typeof src.bottom === 'object' ? src.bottom : {};
  const btxt = (v, fallback, max) => {
    const s = String(v == null ? '' : v).trim();
    return s ? s.slice(0, max || 20) : fallback;
  };
  const bottom = {
    billTitle: btxt(bSrc.billTitle, def.bottom.billTitle),
    billAll: btxt(bSrc.billAll, def.bottom.billAll),
    billRecharge: btxt(bSrc.billRecharge, def.bottom.billRecharge),
    billEmpty: btxt(bSrc.billEmpty, def.bottom.billEmpty, 40),
    moreRefresh: btxt(bSrc.moreRefresh, def.bottom.moreRefresh),
    moreRecharge: btxt(bSrc.moreRecharge, def.bottom.moreRecharge),
    moreCancel: btxt(bSrc.moreCancel, def.bottom.moreCancel),
    soonTip: btxt(bSrc.soonTip, def.bottom.soonTip, 60)
  };

  /* 样式：数字都夹在合理区间里（后台拖错了也不至于把页面搞烂） */
  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  const col = (v, fallback) => (/^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? String(v) : fallback);
  const style = {
    cardImage: String(st.cardImage == null ? '' : st.cardImage).trim().slice(0, 300),
    cardTextColor: col(st.cardTextColor, def.style.cardTextColor),
    cardTextSize: num(st.cardTextSize, 10, 40, def.style.cardTextSize),
    cardSubSize: num(st.cardSubSize, 8, 30, def.style.cardSubSize),
    cardSubOpacity: Math.min(1, Math.max(0, Number.isFinite(Number(st.cardSubOpacity)) ? Number(st.cardSubOpacity) : def.style.cardSubOpacity)),
    iconSize: num(st.iconSize, 14, 60, def.style.iconSize),
    gridTitleSize: num(st.gridTitleSize, 9, 30, def.style.gridTitleSize),
    gridTitleColor: col(st.gridTitleColor, def.style.gridTitleColor),
    gridTextSize: num(st.gridTextSize, 9, 30, def.style.gridTextSize),
    gridTextColor: /^#[0-9a-fA-F]{6}$/.test(String(st.gridTextColor || '')) ? String(st.gridTextColor) : ''
  };
  style.maskAmount = st.maskAmount === undefined ? def.style.maskAmount : !!st.maskAmount;
  style.maskReveal = st.maskReveal === undefined ? def.style.maskReveal : !!st.maskReveal;

  const groups = groupsSrc.slice(0, 20).map((g, gi) => {
    const g0 = g && typeof g === 'object' ? g : {};
    const gdef = def.groups[Math.min(gi, def.groups.length - 1)];
    /* 版块只给「上 / 下」两个值（块与块之间的空隙）；
       行间距、标题行高、每行高、留白这些都取消，回到参考图那套固定值。
       左右一律固定在参考图的 8pt，不提供调节。 */
    const gst = g0.style && typeof g0.style === 'object' ? g0.style : {};
    const gnum = (v, lo, hi) => {
      if (v === undefined || v === null || v === '') return null;
      const n = Number(v);
      if (!Number.isFinite(n)) return null;
      return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
    };
    const groupStyle = {
      gapTop: gnum(gst.gapTop, 0, 100),         // 这个版块上面空多少
      gapBottom: gnum(gst.gapBottom, 8, 100)    // 这个版块下面空多少（最少 8，版块不会挨在一起）
    };
    const items = (Array.isArray(g0.items) ? g0.items : []).slice(0, 24).map((it, i) => {
      const o = it && typeof it === 'object' ? it : {};
      return {
        id: String(o.id || '').slice(0, 24) || ('sv' + (gi + 1) + '_' + (i + 1)),
        label: String(o.label == null ? '' : o.label).trim().slice(0, 12) || ('功能' + (i + 1)),
        icon: String(o.icon || '').slice(0, 60),
        svg: String(o.svg || '').slice(0, 20000),
        color: /^#[0-9a-fA-F]{6}$/.test(String(o.color || '')) ? String(o.color) : '#1180E0',
        action: SERVICE_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
        enabled: o.enabled === undefined ? true : !!o.enabled
      };
    });
    return {
      id: String(g0.id || '').slice(0, 24) || ('sg' + (gi + 1)),
      title: String(g0.title == null ? '' : g0.title).trim().slice(0, 12) || (gdef && gdef.title) || ('分类' + (gi + 1)),
      enabled: g0.enabled === undefined ? true : !!g0.enabled,
      style: groupStyle,
      items: items
    };
  });
  return { title: title, card: card, bottom: bottom, style: style, groups: groups };
}

/* 把后台传来的 ＋ 面板配置洗干净（名称、图标、动作、开关、顺序都以这里为准） */
function normalizePlusItems(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_PLUS_ITEMS;
  return src.slice(0, 40).map((it, i) => {
    const item = it && typeof it === 'object' ? it : {};
    const label = String(item.label == null ? '' : item.label).trim().slice(0, 12) || ('功能' + (i + 1));
    const icon = PLUS_ICONS.indexOf(item.icon) >= 0 ? item.icon : 'star';
    const action = PLUS_ACTIONS.indexOf(item.action) >= 0 ? item.action : 'none';
    return {
      id: String(item.id || '').slice(0, 24) || ('p' + (i + 1)),
      label: label,
      icon: icon,
      action: action,
      enabled: item.enabled === undefined ? true : !!item.enabled
    };
  });
}
const DEFAULT_BRANDING = {
  appName: 'CHRIS Chat',
  logo: '',
  chatBackground: '',
  fontFamily: '',
  fontName: '',
  fontUrl: '',
  fontScale: 1,
  accentColor: '',
  textColor: '',
  iceServers: '',
  icons: { chats: '', contacts: '', groups: '', moments: '', account: '' },
  updatedAt: ''
};
const messageCache = new Map();

/** 面对面建群：同一个 4 位数字在有效期内进同一个群 */
const FACE_ROOM_WINDOW_MS = 3 * 60 * 1000;
function pruneFaceRooms() {
  const t = Date.now();
  const kept = db.faceRooms.filter((r) => r.expiresAt > t);
  if (kept.length !== db.faceRooms.length) db.faceRooms = kept;
  return db.faceRooms;
}

function loadStore() {
  ensureDirs();
  const users = readJson(path.join(DATA_DIR, 'users.json'), { users: [] });
  const friends = readJson(path.join(DATA_DIR, 'friendships.json'), { friendships: [] });
  const chats = readJson(path.join(DATA_DIR, 'chats.json'), { chats: [] });
  const reads = readJson(path.join(DATA_DIR, 'reads.json'), { reads: {} });
  const moments = readJson(path.join(DATA_DIR, 'moments.json'), { moments: [] });
  const momentViews = readJson(path.join(DATA_DIR, 'moment-views.json'), { views: {} });
  const announcements = readJson(path.join(DATA_DIR, 'announcements.json'), { announcements: [] });
  const branding = readJson(path.join(DATA_DIR, BRANDING_FILE), { branding: null });
  const plusPanel = readJson(path.join(DATA_DIR, PLUSPANEL_FILE), { items: null });
  const gifts = readJson(path.join(DATA_DIR, GIFTS_FILE), { gifts: null });
  const stickers = readJson(path.join(DATA_DIR, STICKER_FILE), { stickers: null });
  const statuses = readJson(path.join(DATA_DIR, STATUS_FILE), { categories: null });
  const discover = readJson(path.join(DATA_DIR, DISCOVER_FILE), { items: null });
  const mePage = readJson(path.join(DATA_DIR, ME_PAGE_FILE), { items: null });
  const service = readJson(path.join(DATA_DIR, SERVICE_FILE), { service: null });
  const wallet = readJson(path.join(DATA_DIR, WALLET_FILE), { wallet: null });
  const balancePage = readJson(path.join(DATA_DIR, BALANCE_FILE), { page: null });
  const billsPage = readJson(path.join(DATA_DIR, BILLS_FILE), { page: null });
  const faceRooms = readJson(path.join(DATA_DIR, 'face-rooms.json'), { rooms: [] });
  const transfers = readJson(path.join(DATA_DIR, 'transfers.json'), { transfers: [] });
  const redpackets = readJson(path.join(DATA_DIR, 'redpackets.json'), { redpackets: [] });
  const security = readJson(path.join(DATA_DIR, 'logins.json'), { logins: [], events: [] });
  db.users = Array.isArray(users.users) ? users.users : [];
  /* 在线客服（kefu）是「服务账号」：名片上显示官方账号，但不参与给所有人建会话的机器人循环 */
  db.users.forEach((u) => { if (u.username === 'kefu') { u.bot = true; u.service = true; } });
  ensureGenders();
  db.friendships = Array.isArray(friends.friendships) ? friends.friendships : [];
  db.chats = Array.isArray(chats.chats) ? chats.chats : [];
  db.reads = reads.reads && typeof reads.reads === 'object' ? reads.reads : {};
  /* 清空聊天记录：记到哪一条为止（只影响清空的那个人，别人不受影响） */
  db.cleared = reads.cleared && typeof reads.cleared === 'object' ? reads.cleared : {};
  db.moments = Array.isArray(moments.moments) ? moments.moments : [];
  db.momentViews = momentViews.views && typeof momentViews.views === 'object' ? momentViews.views : {};
  db.announcements = Array.isArray(announcements.announcements) ? announcements.announcements : [];
  db.faceRooms = (Array.isArray(faceRooms.rooms) ? faceRooms.rooms : []).filter((r) => r && r.code && r.chatId);
  db.transfers = Array.isArray(transfers.transfers) ? transfers.transfers : [];
  /* 老的红包（早期一对一那套：只有 amount / toId）直接丢掉 —— 结构和规则都不一样，
     留着只会在聊天里画出错的卡片。红包记录本来就是一次性消费，不存在补数据的必要。 */
  db.redpackets = (Array.isArray(redpackets.redpackets) ? redpackets.redpackets : [])
    .filter((r) => r && typeof r === 'object' && Array.isArray(r.claims) && r.total != null);
  db.security = {
    logins: Array.isArray(security.logins) ? security.logins : [],
    events: Array.isArray(security.events) ? security.events : []
  };
  db.branding = branding.branding && typeof branding.branding === 'object'
    ? Object.assign({}, DEFAULT_BRANDING, branding.branding, {
      icons: Object.assign({}, DEFAULT_BRANDING.icons, branding.branding.icons || {})
    })
    : JSON.parse(JSON.stringify(DEFAULT_BRANDING));
  const badgeCfg = readJson(path.join(DATA_DIR, 'badges.json'), { badges: null });
  db.badges = Object.assign({
    chats: 'auto', contacts: 'auto', discover: 'auto', me: 'off', newFriends: 'auto', momentsRow: 'auto'
  }, (badgeCfg && badgeCfg.badges) || {});
  db.plusPanel = normalizePlusItems(plusPanel.items);
  db.gifts = normalizeGifts(gifts.gifts);
  db.stickers = normalizeStickers(stickers.stickers);
  db.statuses = normalizeStatus(statuses.categories);
  db.discover = normalizeDiscover(discover.items);
  db.mePage = normalizeMePage(mePage.items);
  db.service = normalizeService(service.service);
  db.wallet = normalizeWallet(wallet.wallet);
  db.balancePage = normalizeBalancePage(balancePage.page);
  db.billsPage = normalizeBillsPage(billsPage.page);

  const adminFile = path.join(DATA_DIR, ADMIN_FILE_NAME);
  const tablesFile = path.join(DATA_DIR, 'tables.json');
if (fs.existsSync(tablesFile)) {
  try { const parsed = JSON.parse(fs.readFileSync(tablesFile, 'utf8')); if (parsed && typeof parsed === 'object') db.tables = parsed; } catch (err) { /* 忽略 */ }
}

if (fs.existsSync(adminFile)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(adminFile, 'utf8'));
      if (parsed && parsed.hash && parsed.salt && parsed.secret) adminAuth = parsed;
    } catch (err) { adminAuth = null; }
  }
  if (!adminAuth) {
    adminAuth = makeSecretRecord(DEFAULT_ADMIN_PASSWORD);
    fs.writeFileSync(adminFile, JSON.stringify(adminAuth, null, 2), 'utf8');
    adminJustCreated = true;
  }

  const secretFile = path.join(DATA_DIR, 'secret.key');
  if (fs.existsSync(secretFile)) {
    db.secret = fs.readFileSync(secretFile, 'utf8').trim();
  } else {
    db.secret = crypto.randomBytes(32).toString('hex');
    fs.writeFileSync(secretFile, db.secret, 'utf8');
  }
}

const saveUsers = () => writeJson(path.join(DATA_DIR, 'users.json'), { users: db.users });
const saveFriendships = () => writeJson(path.join(DATA_DIR, 'friendships.json'), { friendships: db.friendships });
const saveChats = () => writeJson(path.join(DATA_DIR, 'chats.json'), { chats: db.chats });
const saveReads = () => writeJson(path.join(DATA_DIR, 'reads.json'), { reads: db.reads, cleared: db.cleared || {} });
/* 高频写入用这两个：先打标记，攒到定时器里再落盘（压测发现每发一条消息
   都重写 chats.json/reads.json 是最大瓶颈，1.5 秒合并一次完全够用）。 */
let chatsDirty = false;
let readsDirty = false;
setInterval(() => {
  try {
    if (chatsDirty) { chatsDirty = false; saveChats(); }
    if (readsDirty) { readsDirty = false; saveReads(); }
  } catch (err) { /* 忽略 */ }
}, 1500).unref();
const saveMoments = () => writeJson(path.join(DATA_DIR, 'moments.json'), { moments: db.moments });
const saveMomentViews = () => writeJson(path.join(DATA_DIR, 'moment-views.json'), { views: db.momentViews });
const saveAnnouncements = () => writeJson(path.join(DATA_DIR, 'announcements.json'), { announcements: db.announcements });
const saveBranding = () => writeJson(path.join(DATA_DIR, BRANDING_FILE), { branding: db.branding });
const saveBadges = () => writeJson(path.join(DATA_DIR, 'badges.json'), { badges: db.badges });
const savePlusPanel = () => writeJson(path.join(DATA_DIR, PLUSPANEL_FILE), { items: db.plusPanel });
const saveGifts = () => writeJson(path.join(DATA_DIR, GIFTS_FILE), { gifts: db.gifts });
const saveStickers = () => writeJson(path.join(DATA_DIR, STICKER_FILE), { stickers: db.stickers });
const saveStatuses = () => writeJson(path.join(DATA_DIR, STATUS_FILE), { categories: db.statuses });
const saveDiscover = () => writeJson(path.join(DATA_DIR, DISCOVER_FILE), { items: db.discover });
const saveMePage = () => writeJson(path.join(DATA_DIR, ME_PAGE_FILE), { items: db.mePage });
const saveService = () => writeJson(path.join(DATA_DIR, SERVICE_FILE), { service: db.service });
const saveWallet = () => writeJson(path.join(DATA_DIR, WALLET_FILE), { wallet: db.wallet });
const saveBalancePage = () => writeJson(path.join(DATA_DIR, BALANCE_FILE), { page: db.balancePage });
const saveBillsPage = () => writeJson(path.join(DATA_DIR, BILLS_FILE), { page: db.billsPage });
const saveFaceRooms = () => writeJson(path.join(DATA_DIR, 'face-rooms.json'), { rooms: db.faceRooms });
const saveTransfers = () => writeJson(path.join(DATA_DIR, 'transfers.json'), { transfers: db.transfers });
const saveRedPackets = () => writeJson(path.join(DATA_DIR, 'redpackets.json'), { redpackets: db.redpackets });
const saveSecurity = () => writeJson(path.join(DATA_DIR, 'logins.json'), { logins: db.security.logins, events: db.security.events });

/* --------------------------------------------------- 朋友圈：追加式写入
   原来每发一条朋友圈，就把「全部动态」整体重写一遍 moments.json。
   动态一多（几千上万条）光写文件就把磁盘写爆、发一条要几百毫秒。
   现在新动态只往 moments-log.jsonl 追加一行（几 KB），
   下次开服时把日志并回 moments.json 再清空日志（合并只做一次，不占正常请求）。 */
const MOMENTS_LOG = 'moments-log.jsonl';
const momentsLogPath = () => path.join(DATA_DIR, MOMENTS_LOG);
let momentsLogCount = 0;

function replayMomentsLog() {
  let added = 0;
  try {
    const raw = fs.readFileSync(momentsLogPath(), 'utf8');
    const known = new Set((db.moments || []).map((m) => m.id));
    raw.split('\n').forEach((line) => {
      const t = line.trim();
      if (!t) return;
      try {
        const m = JSON.parse(t);
        if (m && m.id && !known.has(m.id)) { db.moments.unshift(m); known.add(m.id); added++; }
      } catch (err) { /* 跳过坏行 */ }
    });
  } catch (err) { /* 没有日志文件就是第一次跑 */ }
  if (added) {
    try {
      writeJson(path.join(DATA_DIR, 'moments.json'), { moments: db.moments });
      fs.writeFileSync(momentsLogPath(), '', 'utf8');
    } catch (err) { /* 合并失败也不影响使用，下次再合 */ }
  }
  return added;
}

/** 发一条新动态：只追加一行 + 放进内存 */
function appendMoment(moment) {
  try {
    fs.appendFileSync(momentsLogPath(), JSON.stringify(moment) + '\n', 'utf8');
    momentsLogCount++;
  } catch (err) { /* 写不进日志就让下次整体保存兜底 */ }
  db.moments.unshift(moment);
}

/* --------------------------------------------------- 转账单（待收款 / 24 小时退回）
   付款时先扣付款方余额，钱挂在转账单上；对方点「收钱」才进对方余额，
   超过 24 小时没人收，自动原路退回到付款方余额。 */
const TRANSFER_TTL_MS = 24 * 60 * 60 * 1000;

function transferSnapshot(t) {
  return JSON.stringify({
    id: t.id,
    amount: t.amount,
    note: t.note || '',
    status: t.status,                 // pending / received / refunded
    method: t.method || 'balance',
    fromId: t.fromId,
    toId: t.toId,
    createdAt: t.createdAt,
    expiresAt: t.expiresAt,
    receivedAt: t.receivedAt || '',
    refundedAt: t.refundedAt || ''
  });
}

/** 把会话里那条转账消息的内容刷成最新状态（客户端按它画卡片） */
function syncTransferMessage(t) {
  const chat = db.chats.find((c) => c.id === t.chatId);
  if (!chat) return null;
  const messages = loadMessages(chat.id);
  const msg = messages.find((m) => m.id === t.messageId);
  if (!msg) return null;
      msg.content = transferSnapshot(t);
      try {
        saveMessagesFile(chat.id, messages);
      } catch (err) { /* 忽略 */ }
  return msg;
}

function broadcastTransfer(t, kind) {
  syncTransferMessage(t);
  const payload = {
    type: 'transfer',
    event: kind || 'update',
    chatId: t.chatId,
    messageId: t.messageId,
    transfer: JSON.parse(transferSnapshot(t))
  };
  [t.fromId, t.toId].forEach((id) => { if (id) sendTo(id, payload); });
}

/** 24 小时没被收款的，自动退回给付款方 */
function expireTransfers() {
  const t = Date.now();
  let changed = 0;
  db.transfers.forEach((tr) => {
    if (tr.status !== 'pending') return;
    if (!(tr.expiresAt && tr.expiresAt <= t)) return;
    const from = findUser(tr.fromId);
    if (from) {
      from.balance = Math.round(((Number(from.balance) || 0) + tr.amount) * 100) / 100;
      sendTo(from.id, { type: 'balance', balance: from.balance });
    }
    tr.status = 'refunded';
    tr.refundedAt = now();
    changed++;
    broadcastTransfer(tr, 'refunded');
  });
  if (changed) saveUsers();
  if (changed) saveTransfers();
  return changed;
}

/* 按卡号认银行（微信就是输入卡号自动跳银行）：只认最常见的几个前缀 */
/** 绑卡时能选的银行（名字 + 品牌色，App 里画成带颜色的小方块） */
const BANK_LIST = [
  { name: '工商银行', color: '#C8161D', short: '工' },
  { name: '建设银行', color: '#0B4DA2', short: '建' },
  { name: '农业银行', color: '#0E8B4A', short: '农' },
  { name: '中国银行', color: '#B01F24', short: '中' },
  { name: '招商银行', color: '#C7000B', short: '招' },
  { name: '交通银行', color: '#1B4E9B', short: '交' },
  { name: '邮储银行', color: '#0E7B40', short: '邮' },
  { name: '中信银行', color: '#D0202F', short: '信' },
  { name: '民生银行', color: '#0E5EA8', short: '民' },
  { name: '浦发银行', color: '#0A4C8B', short: '浦' },
  { name: '兴业银行', color: '#1F4C9C', short: '兴' },
  { name: '光大银行', color: '#8B1A2B', short: '光' },
  { name: '平安银行', color: '#F36F21', short: '平' },
  { name: '广发银行', color: '#C8102E', short: '广' },
  { name: '华夏银行', color: '#0E5EA8', short: '华' },
  { name: '北京银行', color: '#0B4DA2', short: '京' },
  { name: '上海银行', color: '#0E5EA8', short: '沪' },
  { name: '宁波银行', color: '#1B4E9B', short: '宁' },
  { name: '江苏银行', color: '#0E7B40', short: '苏' },
  { name: '微众银行', color: '#0E9C6B', short: '微' },
  { name: '网商银行', color: '#1F7BE0', short: '网' },
  { name: '其他银行', color: '#8A8A8E', short: '其' }
];

const BANK_BY_PREFIX = [
  { p: ['622575', '622576', '622588', '621286'], name: '招商银行' },
  { p: ['622202', '622203', '621226', '9558'], name: '工商银行' },
  { p: ['4367', '6227', '6217'], name: '建设银行' },
  { p: ['622848', '622845', '9559'], name: '农业银行' },
  { p: ['621661', '601382', '456351'], name: '中国银行' },
  { p: ['622260', '622262', '601428'], name: '交通银行' },
  { p: ['622188', '621096', '9551'], name: '邮储银行' },
  { p: ['622690', '622691'], name: '中信银行' },
  { p: ['622155', '622156'], name: '平安银行' },
  { p: ['622568', '622569'], name: '广发银行' },
  { p: ['622908', '622909'], name: '兴业银行' },
  { p: ['622622', '622617'], name: '民生银行' },
  { p: ['622636', '622637'], name: '华夏银行' },
  { p: ['622588', '622589'], name: '光大银行' }
];
function guessBankByCardNo(number) {
  const n = String(number || '').replace(/\D/g, '');
  for (const row of BANK_BY_PREFIX) {
    for (const p of row.p) {
      if (n.indexOf(p) === 0) return { name: row.name, hit: p };
    }
  }
  return { name: '', hit: '' };
}

/** 这张尾号的卡上还有没有在处理中的提现 */
function pendingWithdrawToTail(user, tail) {
  try {
    return readWalletOps().ops.some((o) =>
      o.userId === user.id && o.kind === 'withdraw' && o.status === 'pending' &&
      String(o.bankText || '').indexOf(String(tail)) >= 0);
  } catch (e) { return false; }
}

/* --------------------------------------------------- 青少年模式（微信：设置 → 青少年模式）
   开关要密码（4 位），开了以后按勾选把某些功能关掉：视频号 / 直播 / 游戏 / 附近 / 摇一摇 / 搜一搜 / 支付。
   密码只存哈希；家长手机号只存脱敏。 */
const TEEN_PATHS = [
  { p: 'feed', k: 'feed', name: '视频号' },
  { p: 'live', k: 'live', name: '直播' },
  { p: 'games', k: 'games', name: '游戏' },
  { p: 'nearby', k: 'nearby', name: '附近的人' },
  { p: 'shake', k: 'shake', name: '摇一摇' },
  { p: 'search', k: 'search', name: '搜一搜' },
  { p: 'pay', k: 'pay', name: '支付' },
  { p: 'transfer', k: 'pay', name: '转账' },
  { p: 'bills', k: 'pay', name: '零钱账单' },
  { p: 'wallet', k: 'pay', name: '钱包' }
];
const DEFAULT_TEEN_SCOPES = { feed: 0, live: 0, games: 0, nearby: 0, shake: 0, search: 0, pay: 0 };

function teenCfg(user) {
  const t = (user && user.teen) || {};
  return {
    enabled: !!t.enabled,
    hasPin: !!(t.salt && t.hash),
    scopes: Object.assign({}, DEFAULT_TEEN_SCOPES, t.scopes || {}),
    guardianPhone: t.guardianPhoneMask || '',
    setAt: t.setAt || ''
  };
}
/** 青少年模式下这个接口能不能用（不能用就返回一句人话） */
function teenBlocked(user, parts) {
  const cfg = teenCfg(user);
  if (!cfg.enabled) return '';
  const hit = TEEN_PATHS.find((x) => x.p === parts[0] && !cfg.scopes[x.k]);
  return hit ? ('青少年模式下「' + hit.name + '」被限制了，需要家长用密码关闭青少年模式') : '';
}

/* --------------------------------------------------- 关键词自动回复（微信后台那套「自动回复」）
   后台配规则：用户发的话里命中关键词 → 直接用你配的文案回（比 AI 更准、可控）；
   没命中才轮到 AI 按知识库答。规则可设「包含/完全相同」、可分单聊/群聊、可单独关。
   默认关（enabled: 0），配了规则并在后台打开才生效。 */
const AUTOREPLY_FILE = 'autoreply.json';
let autoReplyCache = null;
const DEFAULT_AUTOREPLY = {
  enabled: 0,                  // 总开关（后台「自动回复」页里打开）
  scope: 'kefu',               // kefu = 只对客服会话生效 / all = 所有机器人会话
  fallback: '',                // 都没命中时补一句（留空就不补，交给 AI）
  rules: []                    // [{ id, keyword, match:'contains'|'exact', reply, enabled }]
};
function readAutoReply() {
  if (autoReplyCache) return autoReplyCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, AUTOREPLY_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_AUTOREPLY, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.rules)) cfg.rules = [];
  autoReplyCache = cfg;
  return cfg;
}
function saveAutoReply(next) {
  autoReplyCache = Object.assign({}, DEFAULT_AUTOREPLY, next || {});
  try { writeJson(path.join(DATA_DIR, AUTOREPLY_FILE), autoReplyCache); } catch (e) { }
  return autoReplyCache;
}
/** 命中第一条规则就返回它的回复文案（没有就返回空串） */
function autoReplyHit(text) {
  const cfg = readAutoReply();
  if (!cfg.enabled) return '';
  const t = String(text || '').trim();
  if (!t) return '';
  for (const r of cfg.rules) {
    if (r && r.enabled !== false && r.keyword && r.reply) {
      const k = String(r.keyword).trim();
      if (!k) continue;
      if (r.match === 'exact' ? (t === k) : (t.indexOf(k) >= 0)) return String(r.reply);
    }
  }
  return '';
}

/* --------------------------------------------------- 支付分（微信那套）
   区间 350~950，初始 650；三个维度算分：身份特质 / 支付行为 / 履约记录；
   分数够就能用「免押服务」（后台可配：名字、门槛分、说明）；
   页面上能看到分是怎么来的、最近的变化记录。 */
const PAYSCORE_FILE = 'payscore.json';
let payScoreCache = null;
const DEFAULT_PAYSCORE = {
  enabled: 1,
  min: 350,
  max: 950,
  base: 650,
  levels: [
    { v: 800, name: '极好' },
    { v: 700, name: '优秀' },
    { v: 600, name: '良好' },
    { v: 500, name: '一般' },
    { v: 0, name: '较差' }
  ],
  services: [
    { id: 'ps1', name: '共享充电宝免押', need: 600, desc: '扫码即借，不用押金', enabled: true },
    { id: 'ps2', name: '骑车免押金', need: 600, desc: '先骑后付', enabled: true },
    { id: 'ps3', name: '酒店免押入住', need: 700, desc: '先住后付、离店结算', enabled: true },
    { id: 'ps4', name: '打车先乘后付', need: 700, desc: '到达后再付款', enabled: true }
  ],
  note: '支付分由身份特质、支付行为、履约记录三部分综合评估，每月 1 号更新一次，多使用、按时付款都会加分。'
};

function readPayScore() {
  if (payScoreCache) return payScoreCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, PAYSCORE_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_PAYSCORE, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.services) || !cfg.services.length) cfg.services = DEFAULT_PAYSCORE.services;
  if (!Array.isArray(cfg.levels) || !cfg.levels.length) cfg.levels = DEFAULT_PAYSCORE.levels;
  payScoreCache = cfg;
  return cfg;
}
function savePayScore(next) {
  payScoreCache = Object.assign({}, DEFAULT_PAYSCORE, next || {});
  try { writeJson(path.join(DATA_DIR, PAYSCORE_FILE), payScoreCache); } catch (e) { }
  return payScoreCache;
}

/** 算分：三个维度各 0~100，加权后映射到 350~950 */
function payScoreOf(user) {
  const cfg = readPayScore();
  const real = !!(user.realName && user.idCardHash);
  const banks = Array.isArray(user.bankCards) ? user.bankCards.length : 0;
  const phone = !!user.phone;
  const ageDays = user.createdAt ? Math.max(0, (Date.now() - new Date(user.createdAt).getTime()) / 86400000) : 0;

  const identity = Math.min(100,
    (real ? 45 : 0) + (banks > 0 ? 30 : 0) + (phone ? 15 : 0) + Math.min(10, Math.round(ageDays / 3)));

  const trs = (db.transfers || []).filter((t) => t.fromId === user.id || t.toId === user.id);
  const rps = (db.redpackets || []).filter((r) => r.fromId === user.id ||
    (Array.isArray(r.claims) ? r.claims.some((c) => c.userId === user.id) : false));
  const behavior = Math.min(100, Math.min(55, trs.length * 4) + Math.min(45, rps.length * 3));

  let vio = 0;
  try { vio = (opsStore.violations || []).filter((v) => v.userId === user.id).length; } catch (e) { vio = 0; }
  const perform = Math.max(0, 100 - vio * 25);

  const total = identity * 0.3 + behavior * 0.4 + perform * 0.3;
  let score = Math.round(cfg.base - 60 + total * 1.3);
  score = Math.max(cfg.min, Math.min(cfg.max, score));

  const level = (cfg.levels || []).find((l) => score >= Number(l.v)) || { name: '良好' };
  const services = (cfg.services || []).filter((s) => s.enabled !== false).map((s) => ({
    id: s.id, name: s.name, desc: s.desc || '', need: Number(s.need) || 0,
    ok: score >= (Number(s.need) || 0), gap: Math.max(0, (Number(s.need) || 0) - score)
  }));

  /* 分值变化：直接用真实事件拼出来（不额外记账，重启不丢） */
  const history = [];
  if (real) history.push({ at: user.idCardVerifiedAt || user.createdAt || '', text: '完成实名认证', delta: +40 });
  if (banks > 0) history.push({ at: (user.bankCards[banks - 1] || {}).addedAt || '', text: '绑定银行卡', delta: +25 });
  trs.slice(-6).forEach((t) => history.push({
    at: t.createdAt, text: t.fromId === user.id ? '发起转账' : '收到转账', delta: t.fromId === user.id ? +3 : +5
  }));
  rps.slice(-6).forEach((r) => history.push({
    at: r.createdAt, text: r.fromId === user.id ? '发出红包' : '收到红包', delta: r.fromId === user.id ? +2 : +3
  }));
  if (vio > 0) history.push({ at: now(), text: '有违规记录被扣分', delta: -25 * vio });
  history.sort((a, b) => String(b.at).localeCompare(String(a.at)));

  return {
    score,
    level: level.name,
    min: cfg.min,
    max: cfg.max,
    dims: [
      { key: 'identity', name: '身份特质', value: identity, desc: real ? '已实名' : '还没实名认证', tip: '完成实名认证 + 绑定银行卡能快速加分' },
      { key: 'behavior', name: '支付行为', value: behavior, desc: '转账 ' + trs.length + ' 笔 · 红包 ' + rps.length + ' 次', tip: '多用转账、红包、收付款，保持活跃' },
      { key: 'perform', name: '履约记录', value: perform, desc: vio > 0 ? ('有 ' + vio + ' 次违规') : '没有异常记录', tip: '按时收款、不要发违规内容' }
    ],
    services,
    history: history.slice(0, 12),
    note: cfg.note || DEFAULT_PAYSCORE.note
  };
}

/* --------------------------------------------------- 经营账户（微信「经营账户」那套）
   · 收款记录：谁在什么时候付了多少钱（转账收款 / 红包收款 / 充值都算经营收款）
   · 经营设置：到账方式（零钱 / 经营账户）、收款提醒、自动提现到零钱、结算周期、店铺名
   · 提现到零钱：经营账户里的钱随时提到零钱（留一条提现流水）
   · 开票信息：抬头、税号、地址电话、开户行账号；可以按金额申请开票，后台能处理
   默认「到账方式 = 零钱」，和以前完全一样；只有店主自己开了经营账户才会走经营账户余额。 */
const BIZ_FILE = 'biz.json';
let bizCache = null;
const DEFAULT_BIZ = {
  enabled: false,
  balance: 0,
  createdAt: '',
  settings: {
    arrival: 'balance',      // balance 零钱 / biz 经营账户
    notify: true,            // 收款提醒
    autoWithdraw: false,     // 自动提现到零钱
    settle: 'T+1',           // 结算周期（展示用）
    feeRate: 0.006,          // 手续费率（展示用，0.6%）
    shopName: '',
    remark: ''
  },
  invoice: { title: '', taxNo: '', address: '', phone: '', bankName: '', bankAccount: '' },
  records: [],               // 收款 / 提现 / 开票申请 流水（一条一行那种）
  invoices: []
};

function readBizAll() {
  if (bizCache) return bizCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, BIZ_FILE), 'utf8')); } catch (e) { raw = null; }
  bizCache = (raw && typeof raw === 'object' && raw.accounts && typeof raw.accounts === 'object') ? raw : { accounts: {} };
  return bizCache;
}
function saveBizAll() { try { writeJson(path.join(DATA_DIR, BIZ_FILE), bizCache); } catch (e) { } }

/** 取某个人的经营账户（没有就按默认值建一个，但不落盘，等真的改了才存） */
function bizOf(userId, create) {
  const all = readBizAll();
  let acc = all.accounts[userId];
  if (!acc && create) {
    acc = JSON.parse(JSON.stringify(DEFAULT_BIZ));
    acc.createdAt = now();
    all.accounts[userId] = acc;
    saveBizAll();
  }
  if (!acc) return JSON.parse(JSON.stringify(DEFAULT_BIZ));
  acc.settings = Object.assign({}, DEFAULT_BIZ.settings, acc.settings || {});
  acc.invoice = Object.assign({}, DEFAULT_BIZ.invoice, acc.invoice || {});
  if (!Array.isArray(acc.records)) acc.records = [];
  if (!Array.isArray(acc.invoices)) acc.invoices = [];
  acc.balance = Math.round((Number(acc.balance) || 0) * 100) / 100;
  return acc;
}

/** 记一笔经营流水（收款 / 提现 / 开票） */
function bizPush(userId, row) {
  const acc = bizOf(userId, true);
  acc.records.unshift(Object.assign({
    id: uid('bz'), orderNo: uid('O'), status: 'done', createdAt: now()
  }, row));
  if (acc.records.length > 2000) acc.records.length = 2000;
  saveBizAll();
  return acc.records[0];
}

/** 收到钱：如果这个人开了经营账户且到账方式选的是经营账户，钱进经营账户余额；否则照旧进零钱。
    两种情况都会记一条收款流水（后台查账看的就是它）。 */
/* ============================================================
   收付款（微信那套）
   付款码池：code -> { userId, exp, used }
   · 18 位数字，和微信一样；60 秒一换；用过（付过一笔）立刻作废
   · 同一秒内重复请求（客户端刷新、网络重试）拿到的还是同一个码，
     不然商家那边刚扫到就过期了
   ============================================================ */
const PAY_CODE_TTL_MS = 60 * 1000;
const payCodes = new Map();

function newPayCode(userId) {
  const t = Date.now();
  payCodes.forEach((v, k) => { if (v.exp <= t) payCodes.delete(k); });
  let exist = '';
  payCodes.forEach((v, k) => {
    if (!exist && v.userId === userId && v.exp > t && !v.used) exist = k;
  });
  if (exist) return exist;
  let code = '1';
  while (code.length < 18) code += String(Math.floor(Math.random() * 10));
  while (payCodes.has(code)) code = '1' + String(Math.floor(Math.random() * 1e17)).padStart(17, '0');
  payCodes.set(code, { userId: userId, exp: t + PAY_CODE_TTL_MS, used: false });
  if (payCodes.size > 5000) payCodes.delete(payCodes.keys().next().value);
  return code;
}

/** 收付款码里的链接基地：优先用请求本身的域名（手机连内网也能扫） */
function payBaseUrl(req) {
  const host = String((req && req.headers && req.headers.host) || '').split(',')[0].trim();
  if (host && /^[0-9A-Za-z.\-]+(:\d+)?$/.test(host)) return 'https://' + host;
  return 'https://' + (process.env.PUBLIC_HOST || 'aa.x8iu.com');
}

/** 「设置金额」那张收款码的金额签名：改一个数字就验不过 */
function payAmountSig(userCd, amountText, exp) {
  return crypto.createHmac('sha256', db.secret)
    .update('payamt:' + userCd + '|' + amountText + '|' + exp)
    .digest('base64url').slice(0, 16);
}

/** 扫到的字符串 → { kind: 'pay' | 'receive', target, amount, code } 或 { error } */
function resolvePayText(raw) {
  const t = String(raw || '').trim();
  if (!t) return { error: '没扫到内容' };
  /* 18 位纯数字 = 付款码（别人扫我，商家扫我） */
  if (/^\d{18}$/.test(t)) {
    const rec = payCodes.get(t);
    if (!rec || rec.used || rec.exp <= Date.now()) return { error: '这个付款码已经过期了，让对方点一下刷新' };
    const u = findUser(rec.userId);
    if (!u) return { error: '付款码的主人找不到了' };
    return { kind: 'pay', target: u, code: t, amount: 0 };
  }
  if (t.indexOf('pay.html') < 0) return { error: '这不是收付款码' };
  /* 付款码的二维码：pay.html?c=18位数字 */
  const mc = /[?&]c=(\d{6,24})/.exec(t);
  if (mc) return resolvePayText(mc[1]);
  /* 收款码：pay.html?u=个人码[&a=金额&e=过期时间&s=签名] */
  const mu = /[?&]u=([A-Za-z0-9._-]{4,80})/.exec(t);
  if (!mu) return { error: '这不是收付款码' };
  const target = findUserByName(usernameFromUserCode(mu[1]));
  if (!target) return { error: '这个收款码无效' };
  let amount = 0;
  const ma = /[?&]a=(\d+(?:\.\d{1,2})?)/.exec(t);
  const me = /[?&]e=(\d{10,16})/.exec(t);
  const ms = /[?&]s=([A-Za-z0-9_-]{8,64})/.exec(t);
  if (ma && me && ms) {
    if (Number(me[1]) < Date.now()) return { error: '这个收款码已经过期了' };
    if (payAmountSig(mu[1], ma[1], me[1]) !== ms[1]) return { error: '这个收款码的金额被改过，让对方重新生成一张' };
    amount = rpRound2(Number(ma[1]) || 0);
  }
  return { kind: 'receive', target: target, amount: amount };
}

/* 扫码付款限流：每人 1 分钟最多付 20 笔（防脚本连着刷） */
const payHits = new Map();
function payRateAllow(userId) {
  const t = Date.now();
  let r = payHits.get(userId);
  if (!r || t - r.t > 60000) { r = { t: t, n: 0 }; payHits.set(userId, r); }
  r.n += 1;
  if (payHits.size > 5000) payHits.clear();
  return r.n <= 20;
}

function bizCollect(user, amount, fromName, fromId, kind, note) {
  const acc = bizOf(user.id, false);
  const toBiz = !!(acc.enabled && acc.settings.arrival === 'biz');
  if (toBiz) {
    const a = bizOf(user.id, true);
    a.balance = Math.round(((Number(a.balance) || 0) + amount) * 100) / 100;
    saveBizAll();
  } else {
    user.balance = Math.round(((Number(user.balance) || 0) + amount) * 100) / 100;
    saveUsers();
  }
  bizPush(user.id, {
    kind: 'collect', amount, fromName: fromName || '', fromId: fromId || '',
    method: kind || 'transfer', note: note || '', settled: !toBiz
  });
  sendTo(user.id, { type: 'balance', balance: Number(user.balance) || 0 });
  return toBiz;
}

/* --------------------------------------------------- 账户升级服务（微信支付那套）
   微信的逻辑：账户分三档，等级越高，收付款额度越大——
   · 0 档「未完善身份信息」：只实名了没有，单笔/单日只能 1000
   · 1 档「已实名」：填了身份证，5000
   · 2 档「已升级」：实名 + 绑了银行卡，20000
   升级动作本身不收费，就是「把该填的填完」；额度按实际完成情况算，不是随便点一下就能变。
   转账 / 发红包 / 提现都要过这个额度检查（和微信一样：超了就提示去升级）。 */
const WALLET_LEVELS = [
  { level: 0, name: '未完善身份信息', tip: '实名认证后额度提升到 5000 元', single: 1000, day: 1000, receive: 1000 },
  { level: 1, name: '已实名', tip: '绑定银行卡后额度提升到 20000 元', single: 5000, day: 5000, receive: 5000 },
  { level: 2, name: '已升级（实名 + 绑卡）', tip: '已经是最高等级', single: 20000, day: 20000, receive: 20000 }
];

function walletLevelOf(user) {
  const real = !!(user.realName && user.idCardHash);
  const bank = (Array.isArray(user.bankCards) ? user.bankCards.length : 0) > 0;
  if (real && bank) return 2;
  if (real) return 1;
  return 0;
}
function walletLevelInfo(user) {
  const lv = walletLevelOf(user);
  return WALLET_LEVELS[lv];
}

/** 今天已经用掉的「转出」额度：转账 + 发红包 + 提现（都不含被退回的） */
function todayOutAmount(userId) {
  const day0 = localDayStart();
  let sum = 0;
  (db.transfers || []).forEach((t) => {
    if (t.fromId !== userId) return;
    if (new Date(t.createdAt).getTime() < day0) return;
    sum += Number(t.amount) || 0;
  });
  (db.redpackets || []).forEach((r) => {
    if (r.fromId !== userId) return;
    if (new Date(r.createdAt).getTime() < day0) return;
    sum += Number(r.total) || 0;
  });
  readWalletOps().ops.forEach((o) => {
    if (o.userId !== userId || o.kind !== 'withdraw') return;
    if (new Date(o.createdAt).getTime() < day0) return;
    sum += Number(o.amount) || 0;
  });
  return Math.round(sum * 100) / 100;
}

/** 花钱前的额度检查：过不去就返回一句人话（微信也是这么提示的） */
function walletLimitCheck(user, amount) {
  const info = walletLevelInfo(user);
  if (amount > info.single) {
    return { error: '单笔最多 ' + money(info.single) + '（你现在的账户等级：' + info.name + '）。升级账户就能提高额度 → 我 → 服务 → 钱包 → 账户升级服务' };
  }
  const used = todayOutAmount(user.id);
  if (used + amount > info.day) {
    return { error: '今天的额度只剩 ' + money(Math.max(0, info.day - used)) + ' 了（单日上限 ' + money(info.day) + '）。升级账户能提高额度' };
  }
  return { ok: true, used, left: Math.round((info.day - used) * 100) / 100, level: info.level };
}

/* --------------------------------------------------- 红包（微信那一套）
   规则和微信对齐：
   · 单聊只发 1 个（普通红包）；群聊可以设个数，分「拼手气」和「普通红包」
   · 发的时候先从发红包的人余额里扣掉全部金额
   · 发红包的人不能抢自己的红包；同一个人在一个红包里只能抢一次
   · 拼手气用「二倍均值」随机分（微信就是这套算法），普通红包每人一样、余数给最后一个
   · 抢完了 status=done；24 小时一到，没被抢完的剩下的钱自动退回给发红包的人
   · 群里每被抢走一个，多一条「XXX 领取了你的红包」灰条
   ------------------------------------------------------------------ */

const rpRound2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

/* ---------------- 红包封面（微信那套：发红包时能挑封面） ----------------
   封面在后台「红包封面」页里配：名字 + 封面图 + 缩略图 + 主题色。
   每个用户可以选一个自己的封面（user.rpCover），发红包时不选就用默认封面。 */
const RP_COVERS_FILE = 'redpacket-covers.json';
let rpCoversCache = null;
const DEFAULT_RP_COVERS = {
  defaultId: 'cv_gold',
  covers: [
    { id: 'cv_gold', name: '金玉满堂', image: '/uploads/rpc-gold.png', thumb: '/uploads/rpc-gold-t.png', color: '#8E1412', enabled: true },
    { id: 'cv_cloud', name: '祥云纳福', image: '/uploads/rpc-cloud.png', thumb: '/uploads/rpc-cloud-t.png', color: '#0E332E', enabled: true },
    { id: 'cv_snow', name: '初雪', image: '/uploads/rpc-snow.png', thumb: '/uploads/rpc-snow-t.png', color: '#183355', enabled: true },
    { id: 'cv_pink', name: '喜欢你', image: '/uploads/rpc-pink.png', thumb: '/uploads/rpc-pink-t.png', color: '#B42C58', enabled: true }
  ]
};

function readRpCovers() {
  if (rpCoversCache) return rpCoversCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, RP_COVERS_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_RP_COVERS, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.covers) || !cfg.covers.length) cfg.covers = DEFAULT_RP_COVERS.covers;
  cfg.covers = cfg.covers.map((c, i) => ({
    id: str(c && c.id, 30) || ('cv' + (i + 1)),
    name: str(c && c.name, 20) || '红包封面',
    image: str(c && c.image, 300),
    thumb: str(c && (c.thumb || c.image), 300),
    color: /^#[0-9a-fA-F]{6}$/.test(String((c && c.color) || '')) ? String(c.color) : '#B3241C',
    enabled: !(c && c.enabled === false)
  })).filter((c) => c.image);
  if (!cfg.covers.length) cfg.covers = DEFAULT_RP_COVERS.covers;
  if (!cfg.covers.some((c) => c.id === cfg.defaultId)) cfg.defaultId = cfg.covers[0].id;
  rpCoversCache = cfg;
  return cfg;
}

function saveRpCovers(next) {
  rpCoversCache = null;
  const cfg = readRpCovers();
  const merged = Object.assign({}, cfg, next || {});
  rpCoversCache = merged;
  try { writeJson(path.join(DATA_DIR, RP_COVERS_FILE), merged); } catch (e) { }
  return merged;
}

/** 这张封面能不能用：不能用就回退到默认封面 */
function rpCoverOf(id) {
  const cfg = readRpCovers();
  const hit = cfg.covers.find((c) => c.id === str(id, 30) && c.enabled);
  if (hit) return hit;
  return cfg.covers.find((c) => c.id === cfg.defaultId && c.enabled) || cfg.covers.find((c) => c.enabled) || null;
}

const rpClaims = (r) => (Array.isArray(r.claims) ? r.claims : []);
const rpClaimed = (r) => rpRound2(rpClaims(r).reduce((a, c) => a + (Number(c.amount) || 0), 0));
const rpLeftCount = (r) => Math.max(0, (Number(r.count) || 1) - rpClaims(r).length);
const rpLeftAmount = (r) => rpRound2((Number(r.total) || 0) - rpClaimed(r));
/** 手气最佳：抢得最多的那个（并列时取先抢的） */
function rpBest(r) {
  const list = rpClaims(r);
  if (!list.length) return null;
  return list.reduce((best, c) => ((Number(c.amount) || 0) > (Number(best.amount) || 0) ? c : best), list[0]);
}

/** 这次该抢到多少钱（微信「二倍均值」：随机区间 0.01 ~ 剩余平均值的两倍） */
function drawRedPacketAmount(r) {
  const leftCount = rpLeftCount(r);
  const leftAmount = rpLeftAmount(r);
  if (leftCount <= 0 || leftAmount <= 0) return 0;
  if (r.type === 'normal') {
    const each = rpRound2((Number(r.total) || 0) / (Number(r.count) || 1));
    return leftCount === 1 ? leftAmount : Math.min(each, leftAmount);
  }
  if (leftCount === 1) return leftAmount;                       // 最后一个把剩下的全拿走
  const avg = leftAmount / leftCount;
  const max = Math.max(0.01, Math.min(leftAmount - (leftCount - 1) * 0.01, avg * 2));
  const amount = rpRound2(0.01 + Math.random() * (max - 0.01));
  return Math.max(0.01, Math.min(amount, leftAmount - (leftCount - 1) * 0.01));
}

function redpacketSnapshot(r) {
  const list = rpClaims(r);
  const cover = rpCoverOf(r.coverId);
  return JSON.stringify({
    id: r.id,
    total: Number(r.total) || 0,
    count: Number(r.count) || 1,
    claimedCount: list.length,
    claimedIds: list.map((c) => c.userId),
    type: r.type || 'normal',            // lucky 拼手气 / normal 普通
    note: r.note || '恭喜发财，大吉大利',
    status: r.status,                    // pending 还有一个没抢 / done 抢完了 / refunded 过期退回
    expired: !!r.expired,                // true = 24 小时到了（还剩的时间就不算了）
    /* 封面：卡片和拆红包页按它画（发的时候用哪张就一直是哪张） */
    coverId: cover ? cover.id : '',
    coverName: cover ? cover.name : '',
    cover: cover ? cover.image : '',
    coverThumb: cover ? cover.thumb : '',
    coverColor: cover ? cover.color : '#B3241C',
    fromId: r.fromId,
    fromName: r.fromName || '',
    createdAt: r.createdAt,
    expiresAt: r.expiresAt,
    refundedAt: r.refundedAt || '',
    refundAmount: r.refundAmount || 0
  });
}

/** 把会话里那条红包消息的内容刷成最新状态（客户端按它画卡片 / 变色） */
function syncRedPacketMessage(r) {
  const chat = db.chats.find((c) => c.id === r.chatId);
  if (!chat) return null;
  const messages = loadMessages(chat.id);
  const msg = messages.find((m) => m.id === r.messageId);
  if (!msg) return null;
      msg.content = redpacketSnapshot(r);
      try {
        saveMessagesFile(chat.id, messages);
      } catch (err) { /* 忽略 */ }
  return msg;
}

function broadcastRedPacket(r, kind) {
  syncRedPacketMessage(r);
  const payload = {
    type: 'redpacket',
    event: kind || 'update',
    chatId: r.chatId,
    messageId: r.messageId,
    redpacket: JSON.parse(redpacketSnapshot(r))
  };
  /* 群红包：会话里每个人都要收到状态更新（谁抢了、抢完没有） */
  const chat = db.chats.find((c) => c.id === r.chatId);
  const targets = chat ? chat.memberIds.slice() : [r.fromId, r.toId];
  targets.filter(Boolean).forEach((id) => sendTo(id, payload));
}

/** 24 小时到了：没抢完的红包，把剩下的钱退回给发红包的人（已经抢走的照旧） */
function expireRedPackets() {
  const t = Date.now();
  let changed = 0;
  (db.redpackets || []).forEach((r) => {
    if (r.status !== 'pending') return;
    if (!(r.expiresAt && r.expiresAt <= t)) return;
    const left = rpLeftAmount(r);
    const from = findUser(r.fromId);
    if (from && left > 0) {
      from.balance = rpRound2((Number(from.balance) || 0) + left);
      sendTo(from.id, { type: 'balance', balance: from.balance });
    }
    r.refundAmount = left;
    r.refundedAt = now();
    /* 一个都没抢走 → refunded；抢过一部分 → done（卡片显示已过期，钱已退剩余） */
    r.status = rpClaims(r).length ? 'done' : 'refunded';
    r.expired = true;
    changed++;
    broadcastRedPacket(r, 'refunded');
  });
  if (changed) { saveUsers(); saveRedPackets(); }
  return changed;
}

/* ---------------------------------------------------------------- 安全中心 */

/** 从 UA 里认一下系统和浏览器，用于「登录设备」展示 */
function describeDevice(ua) {
  const s = String(ua || '');
  if (!s) return '未知设备';
  let os = '未知系统';
  if (/iPhone|iPad|iPod/.test(s)) os = 'iOS';
  else if (/Android/.test(s)) os = 'Android';
  else if (/Windows NT 10/.test(s)) os = 'Windows 10/11';
  else if (/Windows/.test(s)) os = 'Windows';
  else if (/Mac OS X/.test(s)) os = 'macOS';
  else if (/Linux/.test(s)) os = 'Linux';
  let br = '浏览器';
  if (/Edg\//.test(s)) br = 'Edge';
  else if (/OPR\//.test(s)) br = 'Opera';
  else if (/Chrome\//.test(s)) br = 'Chrome';
  else if (/Firefox\//.test(s)) br = 'Firefox';
  else if (/Safari\//.test(s)) br = 'Safari';
  return br + ' · ' + os;
}

function clientInfo(req) {
  const ua = String((req && req.headers && req.headers['user-agent']) || '');
  /* 真实来源 IP：先看连接本身，只有「从本机进来的」（内网穿透/反代都在本机）
     才信转发头 —— 否则局域网里随便伪造 X-Forwarded-For 就能绕过限流和封禁。 */
  let ip = String((req && req.socket && (req.socket.remoteAddress || '')) || '').replace('::ffff:', '');
  if (ip === '127.0.0.1' || ip === '::1' || ip === '') {
    const fwd = String((req && req.headers && req.headers['cf-connecting-ip']) || '').trim() ||
      String((req && req.headers && (req.headers['x-forwarded-for'] || '')) || '').split(',')[0].trim();
    if (fwd) ip = fwd.replace('::ffff:', '').trim();
  }
  ip = ip.replace('::ffff:', '').replace('::1', '127.0.0.1');
  /* 客户端自带的设备标识（iOS 端把 UUID 存 Keychain，请求头 X-Device-Id 带上来）。
     用它可以准确判断「是不是换了设备」，比拿 UA + IP 猜靠谱得多：
     UA 是几百万台 iPhone 共用的，同 UA 不算同一台设备。 */
  const deviceId = String((req && req.headers && req.headers['x-device-id']) || '')
    .replace(/[^0-9A-Za-z\-]/g, '').slice(0, 64);
  return { ip, device: describeDevice(ua), deviceId };
}

/** 记一条登录 / 安全事件 */
function recordSecurity(userId, req, kind, extra) {
  const info = clientInfo(req);
  const row = Object.assign({ id: uid('lg'), userId, kind: kind || 'login', time: now(), ip: info.ip, device: info.device }, extra || {});
  db.security.logins.unshift(row);
  if (db.security.logins.length > 600) db.security.logins.length = 600;
  if (kind && kind !== 'login') { db.security.events.unshift(row); if (db.security.events.length > 300) db.security.events.length = 300; }
  saveSecurity();
  return row;
}

function securityScore(user, logins) {
  let score = 40;
  if (user.passwordUpdatedAt) score += 20;                 // 主动改过密码
  if (user.phone) score += 15;                             // 绑定了手机号
  if (user.region) score += 5;                             // 填了地区
  const devices = {};
  logins.forEach((l) => { devices[l.device] = (devices[l.device] || 0) + 1; });
  if (Object.keys(devices).length <= 2) score += 20;       // 登录设备不多
  else if (Object.keys(devices).length <= 4) score += 10;
  return Math.max(10, Math.min(100, score));
}

/* ============================================================
   安全分（照微信那套机制做的）
   分数区间 550~850，三个维度各 100 分：身份特质 · 支付行为 · 守约历史
   分档：<600 信用较差 · 600-649 信用中等 · 650-699 信用良好
        700-749 信用优秀 · >=750 信用极好
   数据全部来自真实记录（资料 / 登录设备 / 转账 / 记账 / 安全事件 / 违规）。
   ============================================================ */
function creditLevel(score) {
  if (score >= 750) return '信用极好';
  if (score >= 700) return '信用优秀';
  if (score >= 650) return '信用良好';
  if (score >= 600) return '信用中等';
  return '信用较差';
}

function creditScore(user) {
  const logins = db.security.logins.filter((x) => x.userId === user.id);
  const devices = {};
  logins.forEach((l) => { devices[l.device || '未知'] = 1; });
  const deviceCount = Object.keys(devices).length;
  const mineTransfers = (db.transfers || []).filter((t) => t && (t.fromId === user.id || t.toId === user.id));
  const sent = mineTransfers.filter((t) => t.fromId === user.id);
  const got = mineTransfers.filter((t) => t.toId === user.id);
  const gotPaid = got.filter((t) => t.status === 'received').length;
  const gotExpired = got.filter((t) => t.status === 'refunded').length;
  const payFails = logins.filter((l) => l.kind === 'pay-password-fail').length;
  const violated = (opsStore.violations || []).filter((v) => v && v.userId === user.id).length;
  const ledgerRows = (() => {
    try {
      const led = readJson(path.join(DATA_DIR, 'ledger.json'), { items: [] });
      return (Array.isArray(led.items) ? led.items : []).filter((x) => x.userId === user.id).length;
    } catch (e) { return 0; }
  })();
  const days = Math.floor((Date.now() - Date.parse(user.createdAt || now())) / 86400000);

  /* ---------- ① 身份特质：资料越全越像真人 ---------- */
  const idItems = [];
  let identity = 0;
  const addId = (label, ok, point, yes, no) => {
    if (ok) { identity += point; idItems.push({ label: label, ok: true, tip: yes }); }
    else idItems.push({ label: label, ok: false, tip: no });
  };
  addId('实名认证', !!(user.realName && user.idCardHash), 30, '已实名', '去「我 → 设置 → 实名认证」填姓名和身份证号');
  addId('绑定手机号', !!user.phone, 20, '已绑定', '绑手机号能加分，也更安全');
  addId('设置支付密码', hasPayPassword(user), 20, '已设置', '去「设置 → 支付密码」设一个');
  addId('填了地区', !!user.region, 10, '已填', '在「个人信息 → 地区」里选一个');
  addId('有头像和昵称', !!(user.avatar && user.nickname), 10, '已完善', '换张头像、起个昵称');
  addId('账号满 7 天', days >= 7, 10, '已满 ' + days + ' 天', '账号越久越稳，再用几天');
  identity = Math.min(100, identity);

  /* ---------- ② 支付行为：用得多、守规矩 ---------- */
  const payItems = [];
  let payment = 0;
  const sentN = sent.length;
  const payStep = sentN === 0 ? 0 : (sentN < 5 ? 25 : (sentN < 20 ? 45 : 60));
  payment += payStep;
  payItems.push({ label: '转过账', ok: sentN > 0, tip: sentN > 0 ? ('转过 ' + sentN + ' 笔') : '发过一次转账就有分' });
  const gotStep = gotPaid > 0 ? 15 : 0;
  payment += gotStep;
  payItems.push({ label: '收到过转账', ok: gotPaid > 0, tip: gotPaid > 0 ? ('收到 ' + gotPaid + ' 笔') : '别人转给你并收款后加分' });
  const paid = sent.filter((t) => t.status === 'received').length;
  payment += paid >= 5 ? 15 : (paid > 0 ? 8 : 0);
  payItems.push({ label: '完成过收款', ok: paid > 0, tip: paid > 0 ? ('对方收了 ' + paid + ' 笔') : '对方点「收钱」才算完成' });
  payment += ledgerRows > 0 ? 5 : 0;
  payItems.push({ label: '记过账', ok: ledgerRows > 0, tip: ledgerRows > 0 ? ('记了 ' + ledgerRows + ' 笔') : '跟 AI 说「记账 午饭 25」' });
  payment += (Number(user.balance) || 0) > 0 ? 5 : 0;
  payItems.push({ label: '零钱里有余额', ok: (Number(user.balance) || 0) > 0, tip: (Number(user.balance) || 0) > 0 ? '有余额' : '充一点零钱' });
  payment = Math.min(100, payment);

  /* ---------- ③ 守约历史：答应的事做到了没有 ---------- */
  const proItems = [];
  let promise = 0;
  const gotAll = gotPaid + gotExpired;
  const keptRate = gotAll === 0 ? 1 : gotPaid / gotAll;
  const keptPts = gotAll === 0 ? 30 : Math.round(45 * keptRate);
  promise += keptPts;
  proItems.push({
    label: '转账按时收款',
    ok: gotAll === 0 ? true : keptRate >= 0.9,
    tip: gotAll === 0 ? '还没有超时的记录' : (gotPaid + '/' + gotAll + ' 笔按时收了')
  });
  promise += gotExpired === 0 ? 20 : Math.max(0, 20 - gotExpired * 8);
  proItems.push({ label: '没有超时退回', ok: gotExpired === 0, tip: gotExpired === 0 ? '没有退回记录' : (gotExpired + ' 笔超过 24 小时没收') });
  promise += payFails === 0 ? 15 : Math.max(0, 15 - payFails * 5);
  proItems.push({ label: '支付密码没输错过', ok: payFails === 0, tip: payFails === 0 ? '没有错误记录' : ('输错过 ' + payFails + ' 次') });
  promise += violated === 0 ? 10 : 0;
  proItems.push({ label: '没有违规记录', ok: violated === 0, tip: violated === 0 ? '很干净' : ('有 ' + violated + ' 条违规记录') });
  promise += deviceCount <= 2 ? 10 : (deviceCount <= 4 ? 5 : 0);
  proItems.push({ label: '登录设备不多', ok: deviceCount <= 2, tip: deviceCount <= 2 ? (deviceCount + ' 台设备') : ('最近在 ' + deviceCount + ' 台设备上登录过，改个密码更安全') });
  promise = Math.min(100, promise);

  const score = Math.max(550, Math.min(850, 550 + identity + payment + promise));
  const tips = [];
  idItems.concat(payItems, proItems).forEach((it) => {
    if (!it.ok && tips.length < 4) tips.push(it.label + '：' + it.tip);
  });
  if (!tips.length) tips.push('各方面都很好，保持下去就行 👍');

  return {
    score: score,
    level: creditLevel(score),
    min: 550,
    max: 850,
    percent: Math.round(((score - 550) / 300) * 100),
    updatedAt: now(),
    dims: [
      { key: 'identity', label: '身份特质', score: identity, max: 100, items: idItems },
      { key: 'payment', label: '支付行为', score: payment, max: 100, items: payItems },
      { key: 'promise', label: '守约历史', score: promise, max: 100, items: proItems }
    ],
    tips: tips,
    stats: {
      deviceCount: deviceCount,
      sentCount: sentN,
      successCount: paid,
      expiredCount: gotExpired,
      ledgerCount: ledgerRows
    }
  };
}

function messagesFile(chatId) { return path.join(MSG_DIR, chatId + '.jsonl'); }

/* ============================================================
   上传文件（图片/语音/视频/文件）落盘加密
   格式：文件头 4 字节 "LUC1" + 16 字节 IV，后面是 AES-256-CTR 的密文。
   密钥按文件名派生（HMAC-SHA256(secret.key, "file:"+文件名)），**一个文件一把**。
   为什么用 CTR 而不是 GCM：视频/语音要支持 Range 分片（拖进度条），
   流式解密才做得到；媒体文件的完整性由签名链接 + 登录态保证。
   对外服务时在 sendFile 里解密到内存（热文件有缓存），代码看 readUploadPlain。
   ============================================================ */
const UPLOAD_MAGIC = Buffer.from('LUC1');
const uploadPlainCache = new Map();     // name -> Buffer（解密后的）
let uploadPlainCacheBytes = 0;

function uploadFileKey(name) {
  return crypto.createHmac('sha256', String(db.secret || 'chris')).update('file:' + name).digest();
}

function sealUploadBuffer(name, buf) {
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-ctr', uploadFileKey(name), iv);
  return Buffer.concat([UPLOAD_MAGIC, iv, c.update(buf), c.final()]);
}

/** 磁盘上的字节 → 明文；老明文文件（还没有 LUC1 头）原样返回 */
function openUploadBuffer(name, raw) {
  if (raw.length < 20 || !raw.subarray(0, 4).equals(UPLOAD_MAGIC)) return raw;
  const iv = raw.subarray(4, 20);
  const d = crypto.createDecipheriv('aes-256-ctr', uploadFileKey(name), iv);
  return Buffer.concat([d.update(raw.subarray(20)), d.final()]);
}

/** 读一个上传文件的明文（带小缓存：最多 24 个、总量 64MB） */
function readUploadPlain(file) {
  const name = path.basename(file);
  const hit = uploadPlainCache.get(name);
  if (hit) return hit;
  const buf = openUploadBuffer(name, fs.readFileSync(file));
  if (buf.length <= 8 * 1024 * 1024) {
    uploadPlainCache.set(name, buf);
    uploadPlainCacheBytes += buf.length;
    while (uploadPlainCacheBytes > 64 * 1024 * 1024 && uploadPlainCache.size > 1) {
      const first = uploadPlainCache.keys().next().value;
      const old = uploadPlainCache.get(first);
      uploadPlainCacheBytes -= old ? old.length : 0;
      uploadPlainCache.delete(first);
    }
  }
  return buf;
}

/** 只看 4 字节文件头判断「这个上传文件是不是加密落盘的」，不读整个文件 */
function uploadIsSealed(file) {
  let fd = null;
  try {
    fd = fs.openSync(file, 'r');
    const head = Buffer.alloc(4);
    if (fs.readSync(fd, head, 0, 4, 0) < 4) return false;
    return head.equals(UPLOAD_MAGIC);
  } catch (err) {
    return false;
  } finally {
    if (fd !== null) { try { fs.closeSync(fd); } catch (err) { } }
  }
}

/** CTR 计数器按「块偏移」往前推：AES-CTR 的第 N 个 16 字节块用 IV+N 当计数器，
    所以拖进度条要的那一段可以单独解密，不用把整个视频先解一遍。 */
function ctrCounterAt(ivRaw, blockIndex) {
  const counter = Buffer.from(ivRaw);
  let add = blockIndex;
  for (let i = 15; i >= 0 && add > 0; i -= 1) {
    const sum = counter[i] + (add % 256);
    counter[i] = sum & 0xff;
    add = Math.floor(add / 256) + (sum > 255 ? 1 : 0);
  }
  return counter;
}

/** 只解密 [start,end] 这一段明文（视频边下边播 / 拖进度条走这里）。
    以前每个 Range 请求都会把整个文件读出来解一遍再切一刀 —— 一条 12MB 的视频
    拖几下就是几百 MB 的磁盘读 + 解密，服务器白忙，播放器还等不到数据。 */
function readUploadRange(file, name, start, end) {
  const fd = fs.openSync(file, 'r');
  try {
    const ivRaw = Buffer.alloc(16);
    if (fs.readSync(fd, ivRaw, 0, 16, 4) < 16) throw new Error('文件头不完整');
    const blockStart = Math.floor(start / 16) * 16;
    const skip = start - blockStart;
    const need = end - blockStart + 1;
    const cipher = Buffer.alloc(need);
    let got = 0;
    while (got < need) {
      const n = fs.readSync(fd, cipher, got, need - got, 20 + blockStart + got);
      if (!n) break;
      got += n;
    }
    if (got < need) throw new Error('文件不完整');
    const d = crypto.createDecipheriv('aes-256-ctr', uploadFileKey(name), ctrCounterAt(ivRaw, blockStart / 16));
    const plain = Buffer.concat([d.update(cipher), d.final()]);
    return plain.subarray(skip, skip + (end - start + 1));
  } finally {
    try { fs.closeSync(fd); } catch (err) { }
  }
}

/** 整包发一个加密上传文件：边读边解，不再把十几 MB 的视频整块塞进内存 */
function streamUploadPlain(file, res) {
  const name = path.basename(file);
  let ivRaw = null;
  try {
    const fd = fs.openSync(file, 'r');
    try {
      ivRaw = Buffer.alloc(16);
      if (fs.readSync(fd, ivRaw, 0, 16, 4) < 16) ivRaw = null;
    } finally { fs.closeSync(fd); }
  } catch (err) { ivRaw = null; }
  if (!ivRaw) { fs.createReadStream(file).pipe(res); return; }
  const d = crypto.createDecipheriv('aes-256-ctr', uploadFileKey(name), ivRaw);
  const rs = fs.createReadStream(file, { start: 20 });
  const kill = () => { try { rs.destroy(); } catch (err) { } try { res.destroy(); } catch (err) { } };
  rs.on('error', kill);
  d.on('error', kill);
  res.on('close', () => { try { rs.destroy(); } catch (err) { } });
  rs.pipe(d).pipe(res);
}

/** 明文写进上传目录（照样加密落盘），返回文件名 */
function saveUploadPlain(plainBuf, ext) {
  const name = uid('file') + (ext || '.bin');
  fs.writeFileSync(path.join(UPLOAD_DIR, name), sealUploadBuffer(name, plainBuf));
  return name;
}

/** 把刚落盘的上传文件就地加密（先写 .tmp 再改名，避免半截文件被读到）。
    已经是密文的就跳过，返回磁盘上的大小。 */
function sealUploadInPlace(name) {
  const file = path.join(UPLOAD_DIR, name);
  try {
    const raw = fs.readFileSync(file);
    if (raw.length >= 20 && raw.subarray(0, 4).equals(UPLOAD_MAGIC)) return raw.length;
    fs.writeFileSync(file + '.tmp', sealUploadBuffer(name, raw));
    fs.renameSync(file + '.tmp', file);
    return fs.statSync(file).size;
  } catch (err) {
    return 0;
  }
}

/** ffmpeg 读不了加密文件：先解到临时文件，跑完必须删掉（调用方负责） */
function uploadTempPlain(name) {
  const base = path.basename(name).replace(/[^A-Za-z0-9._-]/g, '');
  const tmp = path.join(os.tmpdir(), 'chris-' + crypto.randomBytes(6).toString('hex') + '-' + base);
  fs.writeFileSync(tmp, openUploadBuffer(name, fs.readFileSync(path.join(UPLOAD_DIR, name))));
  return tmp;
}

/** 异步跑一条 ffmpeg/ffprobe：以前用 spawnSync，一张 10MB 视频能把整个服务卡住几十秒
    （所有人都变「一直在转圈」）。改成异步，事件循环一点不占。 */
function runFfAsync(exe, args, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    let err = '';
    let child = null;
    const finish = (r) => { if (!done) { done = true; clearTimeout(timer); resolve(r); } };
    try {
      child = spawn(exe, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    } catch (e) {
      resolve({ ok: false, err: String(e && e.message || e) });
      return;
    }
    if (child.stderr) child.stderr.on('data', (d) => { err = (err + d.toString()).slice(-2000); });
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch (e) { }
      finish({ ok: false, err: 'ffmpeg 超时' });
    }, Math.max(5000, Number(timeoutMs) || 180000));
    child.on('error', (e) => finish({ ok: false, err: String(e && e.message || e) }));
    child.on('close', (code) => finish({ ok: code === 0, code: code, err: err }));
  });
}

/** 把上传目录里还留在磁盘上的明文文件一次性改成密文（启动时跑，可重复） */
function migrateUploadsToEncrypted() {
  let files = 0, bytes = 0, skipped = 0;
  let names = [];
  try { names = fs.readdirSync(UPLOAD_DIR); } catch (err) { return 0; }
  for (const name of names) {
    const file = path.join(UPLOAD_DIR, name);
    let st;
    try { st = fs.statSync(file); } catch (err) { continue; }
    if (!st.isFile() || st.size < 20) { continue; }
    let head = Buffer.alloc(0);
    try { head = fs.readFileSync(file).subarray(0, 4); } catch (err) { continue; }
    if (head.equals(UPLOAD_MAGIC)) { skipped += 1; continue; }
    try {
      const raw = fs.readFileSync(file);
      fs.writeFileSync(file + '.tmp', sealUploadBuffer(name, raw));
      fs.renameSync(file + '.tmp', file);
      files += 1;
      bytes += raw.length;
    } catch (err) { /* 单个失败不影响其它 */ }
  }
  if (files) console.log('[上传加密] ' + files + ' 个文件（' + (bytes / 1024 / 1024).toFixed(1) + ' MB）已从明文改成密文（另有 ' + skipped + ' 个本来就是密文）');
  return files;
}

/* ============================================================
   聊天内容「落盘加密」
   背景：以前消息在服务器上是**明文 JSON**（拿到磁盘/备份就能直接看）。
   现在每条消息用 AES-256-GCM 单独加密后存一行：
     {"e":1,"iv":…,"tag":…,"ct":…}
   密钥不落在这个文件里，而是从 data/secret.key（32 字节）按会话 id 派生
   （HMAC-SHA256(secret, "msg:"+chatId)）—— 不同会话不同密钥，泄露一个不牵连别的。
   每条单独加密的好处：**追加还是 O(1)**（发消息那条热点路径不变慢），
   读取时一行一行解，搜索/审核/机器人也照常工作（服务端手里有密钥）。
   老的明文行仍然能读（openMessage 会认），启动时会一次性改成密文（见 migrateMessages）。
   ============================================================ */
const MSG_CRYPTO = {
  algo: 'aes-256-gcm',
  keyCache: new Map()
};

function chatMessageKey(chatId) {
  const id = String(chatId);
  const hit = MSG_CRYPTO.keyCache.get(id);
  if (hit) return hit;
  const key = crypto.createHmac('sha256', String(db.secret || 'chris')).update('msg:' + id).digest();
  if (MSG_CRYPTO.keyCache.size > 4000) MSG_CRYPTO.keyCache.clear();   // 别无限涨
  MSG_CRYPTO.keyCache.set(id, key);
  return key;
}

/** 把一条消息打成一行密文 */
function sealMessage(chatId, obj) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv(MSG_CRYPTO.algo, chatMessageKey(chatId), iv);
  const ct = Buffer.concat([c.update(Buffer.from(JSON.stringify(obj), 'utf8')), c.final()]);
  return JSON.stringify({
    e: 1,
    iv: iv.toString('base64'),
    tag: c.getAuthTag().toString('base64'),
    ct: ct.toString('base64')
  });
}

/** 读一行：密文解密，老明文原样返回 */
function openMessage(chatId, line) {
  const o = JSON.parse(line);
  if (!o || o.e !== 1) return o;                       // 旧数据（明文）：直接当消息用
  const d = crypto.createDecipheriv(MSG_CRYPTO.algo, chatMessageKey(chatId), Buffer.from(o.iv, 'base64'));
  d.setAuthTag(Buffer.from(o.tag, 'base64'));
  const pt = Buffer.concat([d.update(Buffer.from(o.ct, 'base64')), d.final()]).toString('utf8');
  return JSON.parse(pt);
}

/** 整文件重写（撤回、转账状态更新、导入历史都用它） */
function saveMessagesFile(chatId, list) {
  const body = list.map((m) => sealMessage(chatId, m)).join('\n');
  fs.writeFileSync(messagesFile(chatId), body ? body + '\n' : '', 'utf8');
}

/** 启动时把还留在磁盘上的明文消息文件改成密文（一次性、可重复跑） */
function migrateMessagesToEncrypted() {
  let files = 0, lines = 0, skipped = 0;
  let names = [];
  try { names = fs.readdirSync(MSG_DIR).filter((f) => f.endsWith('.jsonl')); } catch (err) { return 0; }
  for (const f of names) {
    const chatId = f.replace(/\.jsonl$/, '');
    const file = path.join(MSG_DIR, f);
    let raw = '';
    try { raw = fs.readFileSync(file, 'utf8'); } catch (err) { continue; }
    const rows = raw.split('\n').map((s) => s.trim()).filter(Boolean);
    if (!rows.length) continue;
    let plain = 0;
    for (const line of rows) {
      try { const o = JSON.parse(line); if (!o || o.e !== 1) plain += 1; } catch (err) { plain += 1; }
    }
    if (!plain) { skipped += 1; continue; }
    const out = [];
    for (const line of rows) {
      try {
        const obj = openMessage(chatId, line);
        if (obj && !obj.e) out.push(sealMessage(chatId, obj));
      } catch (err) { /* 坏行丢掉 */ }
    }
    try {
      fs.writeFileSync(file + '.tmp', out.join('\n') + '\n', 'utf8');
      fs.renameSync(file + '.tmp', file);
      files += 1;
      lines += out.length;
    } catch (err) { /* 写不动就留着，下次再迁 */ }
  }
  if (files) console.log('[落盘加密] ' + files + ' 个会话、' + lines + ' 条消息已从明文改成密文（另有 ' + skipped + ' 个本来就是密文）');
  return files;
}

function loadMessages(chatId) {
  if (messageCache.has(chatId)) return messageCache.get(chatId);
  const file = messagesFile(chatId);
  const list = [];
  if (fs.existsSync(file)) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    for (const line of lines) {
      const t = line.trim();
      if (!t) continue;
      try { list.push(openMessage(chatId, t)); } catch (err) { /* 跳过坏行 */ }
    }
  }
  const trimmed = list.slice(-MAX_CACHE);
  messageCache.set(chatId, trimmed);
  return trimmed;
}

function appendMessage(chatId, message) {
  fs.appendFileSync(messagesFile(chatId), sealMessage(chatId, message) + '\n', 'utf8');
  // loadMessages 会重新读文件（里面已经有这条了），所以这里只在缓存里没有时才补一次，
  // 否则同一条系统消息会在内存里出现两遍（发公告、面对面建群时都能看到）
  const list = loadMessages(chatId);
  const last = list[list.length - 1];
  if (!last || last.id !== message.id) list.push(message);   // 只看尾巴，几万条也不拖慢
  if (list.length > MAX_CACHE) list.splice(0, list.length - MAX_CACHE);
}

/* ------------------------------------------------------------------ 鉴权 */

/* ------------------------------------------------------------------
   二维码：纯 JS 实现（字节模式 / 纠错等级 L / 版本 1~5，单块不走交织）
   已经和 Python 的 qrcode 库逐格对拍（5 个样例、不同版本和掩码都一致）
   用来做群二维码、授权登录二维码。
   ------------------------------------------------------------------ */
const QR = (function () {
  const CAP = { 1: 19, 2: 34, 3: 55, 4: 80, 5: 108 };
  const EC = { 1: 7, 2: 10, 3: 15, 4: 20, 5: 26 };
  const ALIGN = { 1: 0, 2: 18, 3: 22, 4: 26, 5: 30 };
  const qsize = (v) => v * 4 + 17;
  const EXP = new Array(256), LOG = new Array(256);
  (function () {
    let x = 1;
    for (let i = 0; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) x ^= 0x11d; }
    EXP[255] = EXP[0];
  })();
  const mul = (a, b) => (a === 0 || b === 0) ? 0 : EXP[(LOG[a] + LOG[b]) % 255];
  function rsGenPoly(n) {
    let p = [1];
    for (let i = 0; i < n; i++) {
      const np = new Array(p.length + 1).fill(0);
      for (let j = 0; j < p.length; j++) { np[j] ^= p[j]; np[j + 1] ^= mul(p[j], EXP[i]); }
      p = np;
    }
    return p;
  }
  function rsEncode(data, ecLen) {
    const gen = rsGenPoly(ecLen);
    const res = data.concat(new Array(ecLen).fill(0));
    for (let i = 0; i < data.length; i++) {
      const coef = res[i];
      if (coef === 0) continue;
      for (let j = 0; j < gen.length; j++) res[i + j] ^= mul(gen[j], coef);
    }
    return res.slice(data.length);
  }
  function dataCodewords(bytes, version) {
    const bits = [];
    const push = (v, n) => { for (let i = n - 1; i >= 0; i--) bits.push((v >> i) & 1); };
    push(4, 4);
    push(bytes.length, 8);
    bytes.forEach((b) => push(b, 8));
    const capBits = CAP[version] * 8;
    const term = Math.min(4, capBits - bits.length);
    if (term > 0) push(0, term);
    while (bits.length % 8 !== 0) bits.push(0);
    const out = [];
    for (let i = 0; i < bits.length; i += 8) {
      let b = 0;
      for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
      out.push(b);
    }
    let pad = 0xEC;
    while (out.length < CAP[version]) { out.push(pad); pad = pad === 0xEC ? 0x11 : 0xEC; }
    return out;
  }
  function buildFunctionPatterns(version) {
    const n = qsize(version);
    const m = [], reserved = [];
    for (let i = 0; i < n; i++) { m.push(new Array(n).fill(0)); reserved.push(new Array(n).fill(0)); }
    const mx = { m: m, reserved: reserved };
    const setFn = (x, y, dark) => {
      if (x < 0 || y < 0 || x >= n || y >= n) return;
      m[y][x] = dark ? 1 : 0; reserved[y][x] = 1;
    };
    const finder = (cx, cy) => {
      for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        setFn(cx + dx, cy + dy, d !== 2 && d <= 3);
      }
    };
    finder(3, 3); finder(n - 4, 3); finder(3, n - 4);
    for (let i = 8; i < n - 8; i++) { setFn(i, 6, i % 2 === 0); setFn(6, i, i % 2 === 0); }
    if (version >= 2) {
      const c = ALIGN[version];
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        setFn(c + dx, c + dy, d !== 1);
      }
    }
    for (let i = 0; i <= 8; i++) if (i !== 6) { setFn(i, 8, false); setFn(8, i, false); }
    for (let i = 0; i < 8; i++) { setFn(n - 1 - i, 8, false); setFn(8, n - 1 - i, false); }
    setFn(8, n - 8, true);
    return mx;
  }
  function placeData(mx, codewords) {
    const n = mx.m.length;
    let bitIdx = 0;
    const total = codewords.length * 8;
    const bitAt = (i) => (i < total) ? ((codewords[i >> 3] >> (7 - (i & 7))) & 1) : 0;
    let up = true;
    for (let right = n - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let k = 0; k < n; k++) {
        const y = up ? (n - 1 - k) : k;
        for (let c = 0; c < 2; c++) {
          const x = right - c;
          if (mx.reserved[y][x]) continue;
          mx.m[y][x] = bitAt(bitIdx++);
        }
      }
      up = !up;
    }
  }
  const MASKS = [
    (y, x) => (x + y) % 2 === 0,
    (y) => y % 2 === 0,
    (y, x) => x % 3 === 0,
    (y, x) => (x + y) % 3 === 0,
    (y, x) => (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0,
    (y, x) => ((x * y) % 2) + ((x * y) % 3) === 0,
    (y, x) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
    (y, x) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0
  ];
  function formatBits(mask) {
    const data = (1 << 3) | mask;             // 1 = 纠错等级 L
    let rem = data << 10;
    for (let i = 14; i >= 10; i--) if ((rem >> i) & 1) rem ^= 0x537 << (i - 10);
    return ((data << 10) | rem) ^ 0x5412;
  }
  function drawFormat(m, mask) {
    const n = m.length, bits = formatBits(mask);
    const bit = (i) => (bits >> (14 - i)) & 1;
    for (let i = 0; i <= 5; i++) m[8][i] = bit(i);
    m[8][7] = bit(6); m[8][8] = bit(7); m[7][8] = bit(8);
    for (let i = 9; i <= 14; i++) m[14 - i][8] = bit(i);
    for (let i = 0; i <= 6; i++) m[n - 1 - i][8] = bit(i);
    for (let i = 7; i <= 14; i++) m[8][n - 15 + i] = bit(i);
    m[n - 8][8] = 1;
  }
  function penalty(m) {
    const n = m.length;
    let p = 0;
    const runScore = (line) => {
      let s = 0, run = 1;
      for (let i = 1; i < line.length; i++) {
        if (line[i] === line[i - 1]) run++;
        else { if (run >= 5) s += run - 2; run = 1; }
      }
      if (run >= 5) s += run - 2;
      return s;
    };
    for (let y = 0; y < n; y++) p += runScore(m[y]);
    for (let x = 0; x < n; x++) p += runScore(m.map((r) => r[x]));
    for (let y = 0; y < n - 1; y++) for (let x = 0; x < n - 1; x++) {
      const v = m[y][x];
      if (m[y][x + 1] === v && m[y + 1][x] === v && m[y + 1][x + 1] === v) p += 3;
    }
    let dark = 0;
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) dark += m[y][x];
    p += Math.floor(Math.abs(dark * 100 / (n * n) - 50) / 5) * 10;
    return p;
  }
  function encode(text) {
    const bytes = Array.from(Buffer.from(String(text), 'utf8'));
    let version = 0;
    for (let v = 1; v <= 5; v++) {
      if (Math.ceil((12 + bytes.length * 8) / 8) <= CAP[v]) { version = v; break; }
    }
    if (!version) return null;
    const codewords = dataCodewords(bytes, version).concat(rsEncode(dataCodewords(bytes, version), EC[version]));
    const base = buildFunctionPatterns(version);
    placeData(base, codewords);
    let best = null, bestScore = Infinity;
    for (let mask = 0; mask < 8; mask++) {
      const m = base.m.map((r) => r.slice());
      for (let y = 0; y < m.length; y++) for (let x = 0; x < m.length; x++) {
        if (!base.reserved[y][x] && MASKS[mask](y, x)) m[y][x] ^= 1;
      }
      drawFormat(m, mask);
      const s = penalty(m);
      if (s < bestScore) { bestScore = s; best = m; }
    }
    return { size: best.length, modules: best };
  }
  function svg(text, scale) {
    const r = encode(text);
    if (!r) return '';
    const q = Math.max(2, Math.min(12, Number(scale) || 6));
    const n = r.size, quiet = 2, total = (n + quiet * 2) * q;
    let path = '';
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
      if (r.modules[y][x]) path += 'M' + ((x + quiet) * q) + ' ' + ((y + quiet) * q) + 'h' + q + 'v' + q + 'h-' + q + 'z';
    }
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + total + ' ' + total + '" width="' + total + '" height="' + total + '">'
      + '<rect width="' + total + '" height="' + total + '" fill="#fff"/><path d="' + path + '" fill="#000"/></svg>';
  }
  return { encode: encode, svg: svg };
})();

function hashPassword(password, salt) {
  return crypto.scryptSync(String(password), salt, 64).toString('hex');
}

/** 两个字符串等长时用常量时间比较（防时序侧信道） */
function sameSecret(a, b) {
  const x = Buffer.from(String(a == null ? '' : a));
  const y = Buffer.from(String(b == null ? '' : b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

/* ---------------------------------------------------------------- 密码存储
   规矩：**数据库里不留明文**。登录密码、支付密码一律只有 salt + scrypt 哈希。
   历史包袱：早期版本和几个机器人账号是明文存的 —— 下面这个迁移函数把它们
   就地转成哈希（老密码不变，照旧能登录），然后把明文字段删掉。
   ------------------------------------------------------------------ */

/// 把一个账号的明文密码就地升级成哈希；返回是否改动过
function migrateUserSecrets(user) {
  if (!user) return false;
  let changed = false;
  if (typeof user.password === 'string' && user.password) {
    const salt = user.salt || crypto.randomBytes(16).toString('hex');
    user.salt = salt;
    if (!user.passwordHash) user.passwordHash = hashPassword(user.password, salt);
    delete user.password;
    changed = true;
  }
  if (typeof user.payPassword === 'string' && user.payPassword) {
    const psalt = user.paySalt || crypto.randomBytes(16).toString('hex');
    user.paySalt = psalt;
    if (!user.payPasswordHash) user.payPasswordHash = hashPassword(user.payPassword, psalt);
    delete user.payPassword;
    changed = true;
  }
  return changed;
}

/// 启动时扫一遍所有账号（只动有明文的那几个）
function migrateAllUserSecrets() {
  let n = 0;
  db.users.forEach((u) => { try { if (migrateUserSecrets(u)) n++; } catch (e) { } });
  if (n) {
    saveUsers();
    console.log('[密码迁移] ' + n + ' 个账号的明文密码已转成 scrypt 哈希（原密码不变）');
  }
  return n;
}

function verifyPassword(user, password) {
  if (!user) return false;
  /* 正常路径：salt + scrypt 哈希 */
  if (user.passwordHash && user.salt) {
    const attempt = Buffer.from(hashPassword(password, user.salt), 'hex');
    const stored = Buffer.from(user.passwordHash, 'hex');
    return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
  }
  /* 兜底：万一还有只有明文的账号，比对成功后就地升级（密码不用改） */
  if (typeof user.password === 'string' && user.password) {
    const ok = sameSecret(user.password, password);
    if (ok) { migrateUserSecrets(user); saveUsers(); }
    return ok;
  }
  return false;
}

/* 兼容老调用：以前这里是「假设一定有哈希」的实现，留着这个名字给别处用 */
function verifyPasswordHashed(user, password) {
  const attempt = Buffer.from(hashPassword(password, user.salt), 'hex');
  const stored = Buffer.from(user.passwordHash, 'hex');
  return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
}

/* ------------------------------------------------- 登录限流（防暴力破解）
   同一个 IP/账号 10 分钟内错 8 次 → 封 10 分钟；同一个 IP 连着错 30 次也封。
   成功登录会把计数清零。 */
const LOGIN_FAILS = new Map();          // key -> { n, first, until }
const LOGIN_WINDOW_MS = 10 * 60 * 1000;
const LOGIN_MAX = 8;                    // 单账号
const LOGIN_IP_MAX = 30;                // 单 IP（防止换账号扫）

function loginBlocked(key) {
  const rec = LOGIN_FAILS.get(key);
  if (!rec) return 0;
  if (rec.until && rec.until > Date.now()) return Math.ceil((rec.until - Date.now()) / 1000);
  if (rec.until && rec.until <= Date.now()) { LOGIN_FAILS.delete(key); return 0; }
  if (Date.now() - rec.first > LOGIN_WINDOW_MS) { LOGIN_FAILS.delete(key); return 0; }
  return 0;
}
function noteLoginFail(key) {
  const now = Date.now();
  const rec = LOGIN_FAILS.get(key);
  secStateDirty = true;
  if (!rec || now - rec.first > LOGIN_WINDOW_MS) {
    LOGIN_FAILS.set(key, { n: 1, first: now, until: 0 });
    return;
  }
  rec.n += 1;
  if (rec.n >= LOGIN_MAX) rec.until = now + LOGIN_WINDOW_MS;
}

/** 群二维码的邀请码：不带状态、随时可重算（改了密钥自动失效） */
/** 这条朋友圈给某个看的人看吗（作者自己永远能看） */
/* ---------------- 隐私 / 消息通知设置（照微信那两页的逻辑） ---------------- */
const DEFAULT_PRIVACY = {
  needVerify: true,        // 加我为朋友时需要验证
  strangerMoments: false,  // 允许陌生人查看朋友圈
  addByWx: true,           // 可以通过微信号找到我
  addByPhone: true,        // 可以通过手机号找到我
  addByGroup: true,        // 可以通过群聊加我
  addByQR: true            // 可以通过二维码加我
};
const DEFAULT_NOTIFY = {
  on: true,                // 新消息通知
  sound: true,             // 声音
  vibrate: true,           // 振动
  showDetail: true,        // 通知显示消息详情
  muteStart: '',           // 免打扰开始（HH:MM，空=不启用）
  muteEnd: ''
};
function userPrivacy(u) {
  return Object.assign({}, DEFAULT_PRIVACY, (u && u.privacy) || {});
}
function userNotify(u) {
  return Object.assign({}, DEFAULT_NOTIFY, (u && u.notify) || {});
}

/** 这条朋友圈给某个看的人看吗（作者自己永远能看） */
function momentVisibleTo(m, viewerId) {
  if (!m) return false;
  if (m.authorId === viewerId) return true;
  const v = m.visibility || 'public';
  if (v === 'private') return false;
  if (v === 'partial') return (m.visibleTo || []).includes(viewerId);
  if (v === 'exclude') return !(m.hiddenFrom || []).includes(viewerId);
  return true;
}

/** 群二维码的邀请码：不带状态、随时可重算（改了密钥自动失效） */
/** 个人二维码：每个人的码不一样，扫了能加好友（不带状态，重启也不失效） */
function userCode(username) {
  const u = String(username || '');
  if (!u) return '';
  const sig = crypto.createHmac('sha256', db.secret || 'chris')
    .update('user:' + u).digest('base64url').replace(/[-_]/g, '').slice(0, 12);
  return u + '.' + sig;
}
/** 从个人码反查用户名：签名不对就当无效 */
function usernameFromUserCode(code) {
  const s = String(code || '');
  const i = s.lastIndexOf('.');
  if (i <= 0) return '';
  const u = s.slice(0, i);
  if (userCode(u) !== s) return '';
  return u;
}

/** 群二维码的邀请码：不带状态、随时可重算（改了密钥自动失效） */
function inviteCode(chatId) {
  const sig = crypto.createHmac('sha256', db.secret || 'chris')
    .update('invite:' + chatId).digest('base64url').replace(/[-_]/g, '').slice(0, 12);
  return chatId + '.' + sig;
}
/** 从邀请码反查群 id：签名不对就当无效 */
function chatIdFromInvite(code) {
  const s = String(code || '');
  const i = s.lastIndexOf('.');
  if (i <= 0) return '';
  const chatId = s.slice(0, i);
  if (inviteCode(chatId) !== s) return '';
  return chatId;
}

/** 往会话里塞一条系统消息（通话记录、退群、踢人、解散这种居中灰字），返回这条消息 */
function pushSystemMessage(chat, text) {
  chat.seq = (chat.seq || 0) + 1;
  const msg = {
    id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
    kind: 'system', content: text, createdAt: now(), recalled: false
  };
  appendMessage(chat.id, msg);
  return msg;
}
function clearLoginFails(keys) {
  keys.forEach((k) => LOGIN_FAILS.delete(k));
}

/* ================================================================ 安全总开关
   改 data/security.json 就能调，不用改代码、不用重装：
     signUploads  上传的文件必须带签名才能打开（默认 1）
     autoBan      某个 IP 一直失败就自动封禁（默认 1）
     strictSearch 只能「微信号/手机号」精确搜到人（默认 1，仿微信）
     adminIps     后台只允许这几个 IP（留空 = 只限局域网）
   ------------------------------------------------------------------ */
let secCache = { at: 0, cfg: null };
function secCfg() {
  const t = Date.now();
  if (secCache.cfg && t - secCache.at < 3000) return secCache.cfg;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'security.json'), 'utf8')) || {}; } catch (err) { raw = {}; }
  const cfg = {
    signUploads: raw.signUploads === 0 ? 0 : 1,
    autoBan: raw.autoBan === 0 ? 0 : 1,
    strictSearch: raw.strictSearch === 0 ? 0 : 1,
    allowRecharge: raw.allowRecharge === 1 ? 1 : 0,   // 用户自己「充值」默认关闭（等于自己印钱）
    sliderLogin: raw.sliderLogin === 0 ? 0 : 1,       // 登录要不要先过滑动验证（默认要）
    sessionDays: Number(raw.sessionDays) > 0 ? Number(raw.sessionDays) : 180,   // 用户登录态保留天数
    adminKey: String(raw.adminKey || ''),             // 后台入口暗号（?k=…）
    adminIps: Array.isArray(raw.adminIps) ? raw.adminIps.map(String) : []
  };
  secCache = { at: t, cfg };
  return cfg;
}

/* 通话走谁的通道：data/call.json 里写 { "mode": "self" } 就切到我们自己的通道
   （客户端优先 WebRTC：P2P 打洞 → 我们自己的 TURN；语音连不上回落服务器转发、
   视频连不上再兜腾讯云）。不写或写 "trtc" 就是腾讯云。
   改完客户端重开一次 App 生效；要一键切回去就改这个文件，不用重新出包。 */
const CALL_FILE = path.join(DATA_DIR, 'call.json');
function callMode() {
  try {
    const j = readJson(CALL_FILE, {});
    return j && j.mode === 'self' ? 'self' : 'trtc';
  } catch (e) { return 'trtc'; }
}

/* ------------------------------------------------ 上传文件的「签名链接」
   以前 /uploads/xxx.jpg 谁拿到链接都能看。现在只有两种人能看：
     1) 带正确签名的链接（服务器发出去的每个路径都自动带上，客户端无感）
     2) 已登录的人（网页版带了会话 Cookie 也能直接看）
   签名里带 6 小时对齐的有效期，所以同一个文件在有效期内 URL 不变，缓存照样命中。 */
const UPLOAD_SIG_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const UPLOAD_SIG_WINDOW_MS = 6 * 60 * 60 * 1000;

function uploadSig(name, exp) {
  return crypto.createHmac('sha256', String(db.secret || 'no-secret'))
    .update(name + '|' + exp).digest('hex').slice(0, 32);
}
function signedUploadUrl(name) {
  const exp = Math.floor((Date.now() + UPLOAD_SIG_TTL_MS) / UPLOAD_SIG_WINDOW_MS) * UPLOAD_SIG_WINDOW_MS;
  return '/uploads/' + name + '?e=' + exp + '&s=' + uploadSig(name, exp);
}
function uploadSigOk(name, exp, sig) {
  if (!name || !exp || !sig) return false;
  if (Number(exp) < Date.now()) return false;
  const want = uploadSig(name, Number(exp));
  const a = Buffer.from(String(sig));
  const b = Buffer.from(want);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
/* 出站统一把 /uploads/xxx 换成长签名链接（HTTP 和 WebSocket 都走这里） */
const UPLOAD_URL_RE = /\/uploads\/([A-Za-z0-9._-]+)(?:\?[^"\\]*)?/g;
function signUploadsInText(text) {
  if (!secCfg().signUploads) return text;
  return text.replace(UPLOAD_URL_RE, (m, name) => signedUploadUrl(name));
}

/* ------------------------------------------------ 自动封禁（小黑屋）
   同一个 IP 在 10 分钟里失败 60 次（未登录取数据 / 后台越权 / 传错密码），
   直接关 1 小时。状态写进 data/security-state.json，**重启也不会清空**。 */
const BAN_WINDOW_MS = 10 * 60 * 1000;
const BAN_STRIKES = 60;
const BAN_MS = 60 * 60 * 1000;
const ipStrikes = new Map();     // ip -> { t, n }
const ipBans = new Map();        // ip -> until(ms)
let secStateDirty = false;

function securityStatePath() { return path.join(DATA_DIR, 'security-state.json'); }
function loadSecurityState() {
  try {
    const raw = JSON.parse(fs.readFileSync(securityStatePath(), 'utf8')) || {};
    Object.keys(raw.fails || {}).forEach((k) => {
      const r = raw.fails[k];
      if (r && r.until > Date.now()) LOGIN_FAILS.set(k, { n: r.n || 0, first: r.first || Date.now(), until: r.until });
      else if (r && Date.now() - (r.first || 0) < LOGIN_WINDOW_MS) LOGIN_FAILS.set(k, { n: r.n || 0, first: r.first, until: 0 });
    });
    Object.keys(raw.bans || {}).forEach((ip) => {
      /* 本机/服务器自己的 IP 不封（旧的误封记录也在这里被忽略掉） */
      if (raw.bans[ip] > Date.now() && bannableIp(ip)) ipBans.set(ip, raw.bans[ip]);
    });
    Object.keys(raw.strikes || {}).forEach((ip) => {
      const r = raw.strikes[ip];
      if (r && Date.now() - (r.t || 0) < BAN_WINDOW_MS) ipStrikes.set(ip, { t: r.t, n: r.n || 0 });
    });
  } catch (err) { /* 没有这个文件就是第一次跑 */ }
}
function saveSecurityState() {
  if (!secStateDirty) return;
  secStateDirty = false;
  const fails = {}, bans = {}, strikes = {};
  LOGIN_FAILS.forEach((v, k) => { fails[k] = v; });
  ipBans.forEach((v, k) => { bans[k] = v; });
  ipStrikes.forEach((v, k) => { strikes[k] = v; });
  try { writeJson(securityStatePath(), { fails, bans, strikes, savedAt: now() }); } catch (err) { /* 忽略 */ }
}
setInterval(saveSecurityState, 10 * 1000);
process.on('SIGINT', () => { saveSecurityState(); process.exit(0); });

/** 记一次「不怀好意」的行为，够了就封 */
/* 服务器自己这台机器的 IP（含本机回环）永远不进小黑屋 ——
   不然测试脚本或者自己手滑刷几次，就把自己锁在门外了。 */
let localIpCache = { at: 0, set: null };
function localIpSet() {
  const t = Date.now();
  if (localIpCache.set && t - localIpCache.at < 60000) return localIpCache.set;
  const set = new Set(['127.0.0.1', '::1', 'localhost', '']);
  try {
    const nets = os.networkInterfaces();
    Object.keys(nets).forEach((name) => (nets[name] || []).forEach((x) => {
      if (x.address) set.add(String(x.address).replace('::ffff:', '').replace('::1', '127.0.0.1'));
    }));
  } catch (err) { /* 忽略 */ }
  localIpCache = { at: t, set };
  return set;
}
function bannableIp(ip) {
  return !!ip && !localIpSet().has(String(ip).replace('::ffff:', ''));
}

/** 服务器自己在局域网里的地址（给内置 TURN / 生成链接用） */
function primaryLanIp() {
  try {
    const nets = os.networkInterfaces();
    const names = Object.keys(nets);
    for (let i = 0; i < names.length; i += 1) {
      const list = nets[names[i]] || [];
      for (let k = 0; k < list.length; k += 1) {
        const x = list[k];
        if (x.family === 'IPv4' && !x.internal && /^192\.168\.|^10\.|^172\.(1[6-9]|2\d|3[01])\./.test(x.address)) {
          return x.address;
        }
      }
    }
    for (let i = 0; i < names.length; i += 1) {
      const list = nets[names[i]] || [];
      for (let k = 0; k < list.length; k += 1) {
        if (list[k].family === 'IPv4' && !list[k].internal) return list[k].address;
      }
    }
  } catch (err) { /* 忽略 */ }
  return '127.0.0.1';
}

function strikeIp(ip, why) {
  if (!ip) return;
  const t = Date.now();
  let r = ipStrikes.get(ip);
  if (!r || t - r.t > BAN_WINDOW_MS) { r = { t, n: 0 }; ipStrikes.set(ip, r); }
  r.n += 1;
  secStateDirty = true;
  if (secCfg().autoBan && bannableIp(ip) && r.n >= BAN_STRIKES && !ipBans.has(ip)) {
    ipBans.set(ip, t + BAN_MS);
    secStateDirty = true;
    saveSecurityState();            // 立刻落盘，别等 10 秒的定时器
    console.log('[安全] 自动封禁 IP ' + ip + ' 1 小时（' + why + '，10 分钟内失败 ' + r.n + ' 次）');
  }
}
function ipBanRemain(ip) {
  const until = ipBans.get(ip);
  if (!until) return 0;
  if (until <= Date.now()) { ipBans.delete(ip); return 0; }
  return Math.ceil((until - Date.now()) / 1000);
}

/** 后台能不能访问：白名单优先，其次看「只允许局域网」 */
function adminIpOk(ip) {
  /* 本机和局域网永远放行（服务器上自己 curl、内网办公都靠它） */
  if (ip === '127.0.0.1' || ip === '::1' || isLanAddress(ip)) return true;
  /* 注意：不能读 secCfg()，它只保留自己认识的那几个字段，新加的开关会被它吃掉。
     这里直接读 data/security.json（后台请求很少，读文件不影响性能）。 */
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'security.json'), 'utf8')); } catch (e) { raw = {}; }
  /* 手工白名单优先（写了名单就只认名单） */
  const list = Array.isArray(raw.adminIps) ? raw.adminIps : [];
  if (list.length) return list.indexOf(ip) >= 0;
  /* 只允许国内 IP：后台从此不给境外访问（那个新加坡 IP 就是这么被挡掉的） */
  if (raw.adminCnOnly) return isCnIp(ip);
  return !adminLanOnlyOn();
}

/* ---------- 中国 IPv4 段（APNIC 委派数据，生成在 data/cn-ips.json，二分查找） ---------- */
let cnRangesCache = null;
function cnRanges() {
  if (cnRangesCache) return cnRangesCache;
  try {
    const raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'cn-ips.json'), 'utf8'));
    cnRangesCache = Array.isArray(raw.ranges) ? raw.ranges : [];
  } catch (e) { cnRangesCache = []; }
  return cnRangesCache;
}

function ipToInt(ip) {
  const p = String(ip || '').replace(/^::ffff:/, '').split('.');
  if (p.length !== 4) return -1;
  let n = 0;
  for (const s of p) {
    const v = Number(s);
    if (!(v >= 0 && v <= 255)) return -1;
    n = n * 256 + v;
  }
  return n;
}

/** 这个 IP 是不是国内（表里没有就返回 false，宁可挡错也不放境外进后台） */
function isCnIp(ip) {
  const ranges = cnRanges();
  if (!ranges.length) return false;
  const n = ipToInt(ip);
  if (n < 0) return false;
  let lo = 0, hi = ranges.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const [a, b] = ranges[mid];
    if (n < a) hi = mid - 1;
    else if (n > b) lo = mid + 1;
    else return true;
  }
  return false;
}

/* ============================================================ 管理员后台加固
   ① 保密入口：后台页面要带暗号（?k=…）才能打开，乱试的路由一律 404
   ② 会话绑 IP：令牌里写进登录时的 IP，换个 IP 用不了；有效期缩到 8 小时
   ③ 登录锁定：5 次错密码锁 30 分钟（按账号 + 按 IP 各算一遍） */
const OPS_SESSION_TTL_MS = 8 * 60 * 60 * 1000;
const OPS_LOGIN_MAX = Number(process.env.OPS_LOGIN_MAX) || 20;    // 错 20 次才锁（以前 5 次太容易把自己锁住）
const OPS_LOCK_MS = Number(process.env.OPS_LOCK_MS) || 2 * 60 * 1000;   // 锁 2 分钟（以前 30 分钟）
const opsFails = new Map();          // key -> { n, until }

function opsLoginBlocked(key) {
  const r = opsFails.get(key);
  if (!r) return 0;
  if (r.until && r.until > Date.now()) return Math.ceil((r.until - Date.now()) / 1000);
  if (r.until && r.until <= Date.now()) { opsFails.delete(key); return 0; }
  return 0;
}
function noteOpsFail(key) {
  const t = Date.now();
  let r = opsFails.get(key);
  if (!r || (r.until && r.until <= t)) r = { n: 0, until: 0 };
  r.n += 1;
  if (r.n >= OPS_LOGIN_MAX) r.until = t + OPS_LOCK_MS;
  opsFails.set(key, r);
}
function clearOpsFails(keys) { keys.forEach((k) => opsFails.delete(k)); }

/** 后台入口暗号：data/security.json 里的 adminKey（第一次会自动生成） */
function ensureAdminKey() {
  try {
    const file = path.join(DATA_DIR, 'security.json');
    let raw = {};
    try { raw = JSON.parse(fs.readFileSync(file, 'utf8')) || {}; } catch (err) { raw = {}; }
    /* 已经有密文（adminKeyHash）就不要再生成新的明文了 —— 以前这里会在升级成密文后
       又随机生成一个明文暗号，把用户的旧暗号顶掉，表现就是「暗号不对，进不去」 */
    if (!raw.adminKey && !raw.adminKeyHash) {
      raw.adminKey = crypto.randomBytes(9).toString('base64url').replace(/[-_]/g, '').slice(0, 10);
      writeJson(file, raw);
    }
    secCache = { at: 0, cfg: null };
    return String(raw.adminKey);
  } catch (err) { return ''; }
}
function adminEntryOk(req, params) {
  const q = params && params.get ? String(params.get('k') || '') : '';
  const c = parseCookies(req).chris_admin_key || '';
  /* 暗号在数据里是密文（adminKeyHash + 盐）：这里两个来源都用哈希校验 */
  if (q && adminKeyOk(q)) return true;
  if (c && adminKeyOk(c)) return true;
  return false;
}
/** 登录 IP 指纹：写进后台令牌，换 IP 就失效 */
function ipFingerprint(ip) {
  return crypto.createHmac('sha256', adminAuth.secret).update('ip:' + String(ip || '')).digest('base64url').slice(0, 16);
}

/* 明文 http 登录 App 的提醒：不是拒绝（老 App 还得能用），
   而是在日志和审计里留一条，方便知道哪台设备还在用 http。 */
const plainLoginSeen = new Map();   // ip -> 最后提醒时间
function securityNotePlainLogin(req) {
  try {
    const ip = clientInfo(req).ip;
    const last = plainLoginSeen.get(ip) || 0;
    if (Date.now() - last < 60000) return;
    plainLoginSeen.set(ip, Date.now());
    console.log('[安全提醒] 有设备还在用明文 http 登录（' + ip + '），建议装上内置 https 地址的新版 App');
  } catch (err) { /* 忽略 */ }
}

/* 明文 ws 的提醒（同样只提醒，不拦） */
const plainWsSeen = new Map();
function securityNotePlainWs(ip) {
  const last = plainWsSeen.get(ip) || 0;
  if (Date.now() - last < 120000) return;
  plainWsSeen.set(ip, Date.now());
  console.log('[安全提醒] 有设备还在用明文 ws:// 收发实时消息（' + ip + '）');
}

/** 本机 / 局域网地址。
    明文口（5180）只留给它们：服务器自己的脚本、同一内网的调试机。
    公网来的明文请求一律挡掉 —— 不然密码、令牌会以明文过网（中间人抓包就能用）。 */
function isLocalOrLan(ip) {
  const s = String(ip || '').replace(/^::ffff:/, '');
  if (!s) return false;
  if (s === '127.0.0.1' || s === '::1' || s === 'localhost') return true;
  if (/^10\./.test(s)) return true;
  if (/^192\.168\./.test(s)) return true;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(s)) return true;
  if (/^169\.254\./.test(s)) return true;              // link-local
  if (/^f[cd][0-9a-f]{2}:/i.test(s)) return true;      // IPv6 ULA
  if (/^fe80:/i.test(s)) return true;                  // IPv6 link-local
  return false;
}

/** 后台登录必须走加密通道：明文 http 会把密码暴露给同网段的人 */
function httpsHint(req) {
  const host = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
  return '后台登录必须走加密通道：请用 https://' + host + ':5443/manage.html 打开后台再登录'
    + '（http 明文会被同一个 Wi-Fi 下的人抓到密码和暗号）';
}

/* 一次性免密登录链接（只有超级管理员能生成）：
   用来「点开就直接以某个角色进后台看」，不用输密码。
   安全设计：① 5 分钟过期 ② 只能用一次 ③ 绑定打开它的那个 IP ④ 用掉后立刻从地址里消失 ⑤ 记审计日志 */
const opsMagic = new Map();      // token -> { adminId, exp, used }
function newMagicToken(adminId, minutes) {
  const token = crypto.randomBytes(18).toString('hex');
  opsMagic.set(token, { adminId, exp: Date.now() + Math.min(30, Math.max(1, minutes || 5)) * 60000, used: false });
  if (opsMagic.size > 200) { const first = opsMagic.keys().next().value; opsMagic.delete(first); }
  return token;
}
function takeMagicToken(token) {
  const rec = opsMagic.get(String(token || ''));
  if (!rec) return null;
  opsMagic.delete(String(token));           // 一次性：取出来就作废
  if (rec.used || rec.exp < Date.now()) return null;
  const admin = opsStore.admins.find((a) => a.id === rec.adminId && !a.disabled);
  return admin || null;
}

/* 支付密码（6 位数字，安全中心里设置，转账确认时校验） */
function verifyPayPassword(user, password) {
  if (!user) return false;
  /* 正常路径：salt + scrypt 哈希（和登录密码同一套） */
  if (user.payPasswordHash && user.paySalt) {
    const attempt = Buffer.from(hashPassword(password, user.paySalt), 'hex');
    const stored = Buffer.from(user.payPasswordHash, 'hex');
    return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
  }
  /* 兜底：万一还有明文存的支付密码，比对成功就地升级（原密码不变） */
  if (typeof user.payPassword === 'string' && user.payPassword) {
    const ok = sameSecret(user.payPassword, password);
    if (ok) { migrateUserSecrets(user); saveUsers(); }
    return ok;
  }
  return false;
}

/// 有没有设过支付密码（哈希或历史明文都算）
function hasPayPassword(user) {
  return !!(user && (user.payPasswordHash || user.payPassword));
}

function signToken(userId) {
  // v = 会话版本：改密码 / 退出其他设备时 +1，旧会话立刻失效
  const u = db.users.find((x) => x.id === userId);
  const payload = Buffer.from(JSON.stringify({ sub: userId, v: (u && u.tokenVersion) || 0, exp: Date.now() + userSessionTtlMs() })).toString('base64url');
  const sig = crypto.createHmac('sha256', db.secret).update(payload).digest('base64url');
  return payload + '.' + sig;
}

function verifyTokenData(token) {
  if (!token || typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 2) return null;
  const expect = crypto.createHmac('sha256', db.secret).update(parts[0]).digest('base64url');
  const a = Buffer.from(parts[1]);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const data = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    if (typeof data.exp !== 'number' || data.exp <= Date.now()) return null;
    return data;
  } catch (err) {
    return null;
  }
}

function verifyToken(token) {
  const data = verifyTokenData(token);
  return data ? data.sub : null;
}

/* -------------------------------------------------------------- 管理员鉴权 */

function makeSecretRecord(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  return {
    salt,
    hash: hashPassword(password, salt),
    secret: crypto.randomBytes(32).toString('hex'),
    updatedAt: now()
  };
}

function verifySecretRecord(record, password) {
  if (!record) return false;
  const attempt = Buffer.from(hashPassword(password, record.salt), 'hex');
  const stored = Buffer.from(record.hash, 'hex');
  return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
}

function signAdminToken() {
  const payload = Buffer.from(JSON.stringify({ scope: 'admin', exp: Date.now() + SESSION_TTL_MS })).toString('base64url');
  const sig = crypto.createHmac('sha256', adminAuth.secret).update(payload).digest('base64url');
  return payload + '.' + sig;
}

function verifyAdminToken(token) {
  if (!token || typeof token !== 'string') return false;
  const parts = token.split('.');
  if (parts.length !== 2) return false;
  const expect = crypto.createHmac('sha256', adminAuth.secret).update(parts[0]).digest('base64url');
  const a = Buffer.from(parts[1]);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
  try {
    const data = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    return data.scope === 'admin' && typeof data.exp === 'number' && data.exp > Date.now();
  } catch (err) {
    return false;
  }
}

const isAdmin = (req) => verifyAdminToken(parseCookies(req)[ADMIN_COOKIE]);

function adminCookie(token, maxAgeSeconds) {
  return ADMIN_COOKIE + '=' + encodeURIComponent(token) +
    '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + maxAgeSeconds;
}

function parseCookies(req) {
  const header = req.headers.cookie || '';
  const out = {};
  header.split(';').forEach((pair) => {
    const i = pair.indexOf('=');
    if (i === -1) return;
    const k = pair.slice(0, i).trim();
    if (k) out[k] = decodeURIComponent(pair.slice(i + 1).trim());
  });
  return out;
}

function currentUser(req) {
  /* 令牌来源：优先 Authorization: Bearer（打包进 App 的版本用这个，跨域带不了 Cookie），
     其次才是网页版的会话 Cookie */
  const auth = String((req.headers && req.headers.authorization) || '');
  let token = null;
  if (/^bearer\s+/i.test(auth)) token = auth.replace(/^bearer\s+/i, '').trim();
  if (!token) token = parseCookies(req)[COOKIE_NAME];
  const data = verifyTokenData(token);
  if (!data) return null;
  const user = db.users.find((u) => u.id === data.sub) || null;
  if (!user) return null;
  // 会话版本对不上说明密码改过 / 在其他设备点了「退出其他设备」
  if ((data.v || 0) !== (user.tokenVersion || 0)) return null;
  return user;
}

function sessionCookie(token, maxAgeSeconds) {
  return COOKIE_NAME + '=' + encodeURIComponent(token) +
    '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + maxAgeSeconds;
}

/* -------------------------------------------------------------- 关系与视图 */

const findUser = (id) => db.users.find((u) => u.id === id) || null;

function findUserByName(username) {
  const key = String(username || '').toLowerCase();
  return db.users.find((u) => u.username.toLowerCase() === key) || null;
}

function friendshipBetween(a, b) {
  return db.friendships.find((f) =>
    (f.fromId === a && f.toId === b) || (f.fromId === b && f.toId === a)) || null;
}

function friendIds(userId) {
  return db.friendships
    .filter((f) => f.status === 'accepted' && (f.fromId === userId || f.toId === userId))
    .map((f) => (f.fromId === userId ? f.toId : f.fromId));
}

/* 建一个一对一会话（机器人 / 代发消息 / 欢迎语都用它） */
function createDirectChat(aId, bId) {
  const chat = {
    id: uid('c'), type: 'direct', name: '', avatar: '',
    memberIds: [aId, bId], ownerId: aId, seq: 0, createdAt: now()
  };
  db.chats.push(chat);
  saveChats();
  return chat;
}

function directChatBetween(a, b) {
  // 自己和自己（名片里的「发消息」）：必须两边都是自己，否则会误匹配到别人的单聊
  if (a === b) {
    return db.chats.find((c) =>
      c.type === 'direct' && c.memberIds.length === 2 && c.memberIds.every((id) => id === a)) || null;
  }
  return db.chats.find((c) =>
    c.type === 'direct' && c.memberIds.length === 2 &&
    c.memberIds.includes(a) && c.memberIds.includes(b)) || null;
}

/* 通过好友以后用：给这两个人开一个会话（已有就直接用），返回那个会话。
   —— 新加的好友会立刻出现在「微信」首页，不用等谁先发第一条消息。 */
function openChatForFriendship(aId, bId) {
  const exist = directChatBetween(aId, bId);
  if (exist) return exist;
  return createDirectChat(aId, bId);
}

// 删掉会话只是「对我隐藏」，对方那边不受影响；来了新消息会自动回到列表
const chatsOf = (userId) => db.chats.filter((c) => {
  if (!c.memberIds.includes(userId)) return false;
  if ((c.hiddenFor || []).includes(userId)) return false;
  /* 「在线客服」不占会话列表：它有独立的客服页面（聊天记录还在，客服页照常收发） */
  if (c.type === 'direct') {
    const peerId = c.memberIds.find((id) => id !== userId);
    const peer = peerId ? findUser(peerId) : null;
    if (peer && peer.service) return false;
  }
  return true;
});

function lastReadSeq(userId, chatId) {
  const per = db.reads[userId];
  return (per && per[chatId]) || 0;
}

function unreadCount(userId, chat) {
  const last = lastReadSeq(userId, chat.id);
  const n = loadMessages(chat.id).filter((m) => m.seq > last && m.senderId !== userId && !m.recalled).length;
  if (n > 0) return n;
  /* 左滑「标为未读」：最后一条是自己发的也算未读（微信就是这样，只显示一个小红点） */
  return (chat.flaggedUnread || []).includes(userId) ? 1 : 0;
}

/* 会话列表里「最后一条消息」的预览文字。
   用户要求：转账不显示在会话列表（每个人名字下面），那里只显示真正的会话消息，
   所以最后一条是转账时，往前找最近一条非转账消息来显示。 */
function previewTextOf(m) {
  if (!m) return '';
  if (m.recalled) return '[消息已撤回]';
  /* 会话列表里非文字消息统一显示成 [xx]（和微信一致） */
  switch (m.kind) {
    case 'text': return String(m.content).slice(0, 40);
    case 'image': return '[图片]';
    case 'video': return '[视频]';
    case 'file': {
      // 视频文件按微信显示成 [视频]，其它文件显示 [文件]
      let name = '';
      try { const o = JSON.parse(String(m.content || '{}')); name = String(o.name || o.url || ''); } catch (err) { name = String(m.content || ''); }
      return /\.(mp4|mov|m4v|avi|mkv|webm|3gp|flv|wmv)(\?|$)/i.test(name) ? '[视频]' : '[文件]';
    }
    case 'audio': return '[语音]';
    case 'link': {
      try { const o = JSON.parse(String(m.content || '{}')); return '[' + String(o.title || '链接') + ']'; } catch (err) { return '[链接]'; }
    }
    case 'voicecall':
    case 'call': return '[语音通话]';
    case 'videocall': return '[视频通话]';
    /* 通话记录（系统消息）：微信在会话列表里直接写「通话时长 00:12」/「已取消」/「对方无应答」，
       以前这里没这一支，最后一条是通话记录时列表里显示的是「[system]」——用户说看不到通话记录就是这个 */
    case 'system': return callRecordTextOf(String(m.content || '')).slice(0, 40);
    case 'transfer': return '[转账]';
    case 'gift': return '[礼物]' + (giftNameOf(m.content) ? ' ' + giftNameOf(m.content) : '');
    case 'location': return '[位置]';
    default: return '[' + m.kind + ']';
  }
}

/** 通话记录文案统一成微信那样「通话时长 00:15」：
    老记录里写的是「通话结束 · 时长 0:15」「视频通话结束 · 时长 0:15」，会话列表预览也要跟着统一 */
function callRecordTextOf(text) {
  let t = String(text || '');
  t = t.replace(/^视频通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
  t = t.replace(/^通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
  t = t.replace(/^视频通话时长\s*/, '通话时长 ');
  const mm = t.match(/^通话时长\s+(\d{1,2}):(\d{2})$/);
  if (mm) t = '通话时长 ' + ('0' + mm[1]).slice(-2) + ':' + mm[2];
  return t;
}

function lastPreviewMessage(messages) {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    if (isLegacyTransferText(messages[i])) continue;   // 只跳过早期版本那条「💰 转账」文本
    return messages[i];
  }
  return null;
}

/* 早期版本把「转账」写成了普通文本（💰 转账 ¥xx / 💰 已发起一笔转账），
   这些历史垃圾不进会话列表预览；真正的转账消息（kind=transfer）现在正常显示成 [转账]。
   用户要求：会话列表里 图片 / 语音通话 / 文件 / 视频 / 转账 都按 [xx] 显示。 */
function isLegacyTransferText(m) {
  if (!m || m.kind !== 'text') return false;
  const c = String(m.content || '').trim();
  return c.indexOf('💰 转账') === 0 || c.indexOf('💰 已发起一笔转账') === 0;
}

function chatSummary(chat, forUserId, lastHint) {
  /* 发消息时调用方知道刚写进去的那条，就不用把整个聊天记录读一遍了
     —— 这是压测里最热的一段（每发一条消息要读 2 次聊天文件）。 */
  let last = lastHint || null;
  let previewSrc = lastHint || null;
  if (!lastHint) {
    const messages = loadMessages(chat.id);
    last = messages.length ? messages[messages.length - 1] : null;
    previewSrc = lastPreviewMessage(messages);
  }
  let title = chat.name;
  let avatar = chat.avatar || '';
  /* 会话列表里要能显示好友的「状态」小图标（微信就是这样：头像右下角挂一个 emoji） */
  let moodIcon = '';
  let moodText = '';
  if (chat.type === 'direct') {
    const otherId = chat.memberIds.find((id) => id !== forUserId) || chat.memberIds[0];
    const other = findUser(otherId);
    title = other ? displayNameFor(forUserId, other) : '未知用户';
    avatar = other ? other.avatar : '';
    if (other && moodAlive(other)) {
      moodIcon = other.moodIcon || '';
      moodText = other.moodCaption || other.moodLabel || other.moodText || '';
    }
  }
  let botRank = 9;
  if (chat.type === 'direct') {
    const other = findUser(chat.memberIds.find((id) => id !== forUserId) || '');
    /* 「在线客服」虽然是机器人账号，但会话按时间排，不跟着上面三个机器人置顶 */
    if (other && other.bot && other.username !== 'kefu') {
      botRank = other.username === 'housekeeper' ? 0 : (other.username === AI_USERNAME ? 1 : 2);   // 贾维斯第一 → AI 助手 → 腾讯新闻
    }
  }
  /* 会话列表里那一行预览：群聊里别人发的消息，微信会写成「谁：内容」 */
  let preview = previewSrc ? previewTextOf(previewSrc) : '';
  if (chat.type === 'group' && previewSrc && previewSrc.senderId && previewSrc.senderId !== forUserId) {
    const who = displayNameFor(forUserId, findUser(previewSrc.senderId));
    if (who && preview) preview = who + '：' + preview;
  }
  return {
    id: chat.id,
    type: chat.type,
    title,
    avatar,
    moodIcon,
    moodText,
    /* 只有真的是机器人（AI 助手/管家/腾讯新闻）才给 botRank；
       普通会话给 null —— 老版本 App 是拿「botRank == nil」判断「这是不是机器人」的，
       以前这里一律给 9，导致点好友头像弹出「官方账号」名片（机器人才该弹这个）。 */
    botRank: botRank < 9 ? botRank : null,
    memberIds: chat.memberIds,
    memberCount: chat.memberIds.length,
    lastMessage: last ? {
      id: last.id,
      senderId: (previewSrc || last).senderId,
      senderName: displayNameFor(forUserId, findUser((previewSrc || last).senderId)),
      kind: (previewSrc || last).kind,
      preview,
      /* 时间是最后一条消息的时间（不受转账预览被跳过的影响） */
      createdAt: last.createdAt
    } : null,
    unread: unreadCount(forUserId, chat),
    pinned: (chat.pinnedFor || []).includes(forUserId),
    /* 消息免打扰（群屏蔽）：列表里显示小铃铛划掉，红点不弹 */
    muted: (chat.mutedFor || []).includes(forUserId),
    ownerId: chat.ownerId || '',
    announce: chat.type === 'group' ? (chat.announce || '') : '',
    /* 群禁言：全员禁言 / 我有没有被单独禁言 */
    muteAll: chat.type === 'group' ? !!chat.muteAll : false,
    meMuted: chat.type === 'group' ? (chat.muteMembers || []).includes(forUserId) : false,
    updatedAt: last ? last.createdAt : chat.createdAt
  };
}

/* ---------------------------------------------------------------- 朋友圈 */

function momentAudience(authorId) {
  return Array.from(new Set([authorId].concat(friendIds(authorId))));
}

function visibleMoment(m, viewerId) {
  return {
    id: m.id,
    authorId: m.authorId,
    author: memberProfile(findUser(m.authorId), viewerId),
    content: m.content,
    images: m.images || [],
    location: m.location || '',
    pinned: m.pinned === true,
    createdAt: m.createdAt,
    likes: (m.likes || []).map((l) => ({
      userId: l.userId,
      nickname: displayNameFor(viewerId, findUser(l.userId)),
      at: l.at
    })),
    likedByMe: (m.likes || []).some((l) => l.userId === viewerId),
    comments: (m.comments || []).map((c) => ({
      id: c.id,
      userId: c.userId,
      nickname: displayNameFor(viewerId, findUser(c.userId)),
      replyToName: c.replyTo ? displayNameFor(viewerId, findUser(c.replyTo)) : '',
      content: c.content,
      at: c.at
    })),
    mine: m.authorId === viewerId
  };
}

/* 有多少人加我、我还没处理（「新的朋友」/通讯录上那个红点数字） */
function pendingFriendRequests(userId) {
  let n = 0;
  for (let i = 0; i < db.friendships.length; i += 1) {
    const f = db.friendships[i];
    if (f.toId === userId && f.status === 'pending') n += 1;
  }
  return n;
}

function momentUnread(userId) {
  const last = db.momentViews[userId] || '';
  /* 这里以前是 friends.includes(...) —— 一千个好友 × 几千条动态就是几百万次比较，
     每个请求都要算一遍，CPU 会被打满（朋友圈一多就「崩」就是这个原因）。
     换成 Set 之后是 O(1) 查找。 */
  const mine = new Set(friendIds(userId));
  let n = 0;
  for (let i = 0; i < db.moments.length; i++) {
    const m = db.moments[i];
    if (m.authorId !== userId && mine.has(m.authorId) && String(m.createdAt) > String(last)) n++;
  }
  return n;
}

function broadcastMoment(authorId, payload) {
  momentAudience(authorId).forEach((id) => {
    if (!connections.has(id)) return;          // 离线的人本来也收不到，别再花 CPU 算未读数
    const body = Object.assign({}, payload);
    if (payload.type === 'moment' && payload.action === 'new') {
      body.unread = momentUnread(id);
    }
    sendTo(id, body);
  });
}

/* --------------------------------------------------------------- 实时连接 */

const connections = new Map();
/* 每个账号最近一次连上来的出口 IP：通话前用来判断「两端是不是同一个网络」，
   同一个网络就直连（快、不占服务器带宽），不同网络才强制走中继。 */
const userIps = new Map();

function sendTo(userId, payload) {
  const set = connections.get(userId);
  if (!set) return 0;
  const text = signUploadsInText(JSON.stringify(payload));
  let sent = 0;
  set.forEach((socket) => { if (ws.sendText(socket, text)) sent += 1; });
  return sent;
}

/** 给所有在线的人发一条（配置变更之类的全局通知） */
function sendToAll(payload) {
  const text = signUploadsInText(JSON.stringify(payload));
  let sent = 0;
  connections.forEach((set) => {
    set.forEach((socket) => { if (ws.sendText(socket, text)) sent += 1; });
  });
  return sent;
}

function sendToChat(chat, payload, exceptUserId) {
  let sent = 0;
  chat.memberIds.forEach((id) => {
    if (exceptUserId && id === exceptUserId) return;
    sent += sendTo(id, payload);
  });
  return sent;
}

/** 某个账号当前连接的 App 版本（客户端每个请求都带 X-App-Build） */
function peerBuildOf(userId) {
  const set = connections.get(userId);
  if (!set) return '';
  let out = '';
  set.forEach((s) => { if (!out && s.__appBuild) out = s.__appBuild; });
  return out;
}

function onlineUserIds() {
  const out = [];
  connections.forEach((set, userId) => {
    const who = findUser(userId);
    if (who && who.banned) return;      // 被禁用的人不算在线
    let alive = false;
    set.forEach((s) => { if (!s.destroyed) alive = true; });
    if (alive) out.push(userId);
  });
  return out;
}

function statusOf(userId) {
  const u = findUser(userId);
  return (u && u.status) || 'online';
}

/** 隐身对别人显示成离线 */
function visibleStatus(userId) {
  const st = statusOf(userId);
  return st === 'invisible' ? 'offline' : st;
}

function statusMap() {
  const out = {};
  onlineUserIds().forEach((id) => { out[id] = visibleStatus(id); });
  return out;
}

/* 只给「自己的好友」发在线名单：
   几万人在线时，如果每条连接都塞一份全量名单（1.6 万人在线时那一包就 800KB），
   服务器会被自己的推送压死。前端也只是拿它标记好友在不在线。 */
function onlineFriendsOf(userId) {
  return friendIds(userId).filter((id) => connections.has(id));
}
function friendStatusMap(userId) {
  const out = {};
  onlineFriendsOf(userId).forEach((id) => { out[id] = visibleStatus(id); });
  return out;
}

function notifyPresence(userId, online) {
  const payload = { type: 'presence', userId, online, status: online ? visibleStatus(userId) : 'offline' };
  friendIds(userId).forEach((fid) => sendTo(fid, payload));
}

/* ============================================================
   离线推送（苹果 APNs）
   规则和微信一样：**只有手机当前没连着实时通道**（App 在后台 / 被杀掉 / 没网）
   才推系统通知；连着的时候走长连接就够了，不再弹一条重复的通知。
   配置在 data/push.json：填上苹果开发者后台的 APNs 密钥（.p8 + Key ID + Team ID）
   并打开开关，推送才真的发出去；没配就是"只记日志"，不影响其它功能。
   ============================================================ */
const PUSH_FILE = path.join(DATA_DIR, 'push.json');
let pushCache = null;

function readPush() {
  if (pushCache) return pushCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(PUSH_FILE, 'utf8')); } catch (e) { raw = {}; }
  const cfg = Object.assign({
    enabled: false,
    bundleId: 'com.chris.chatnative',
    teamId: '',
    keyId: '',
    keyPath: '',
    keyText: '',
    sandbox: false,
    onMessage: true,
    onFriend: true,
    onCall: true
  }, raw.config || {});
  pushCache = { config: cfg, tokens: raw.tokens && typeof raw.tokens === 'object' ? raw.tokens : {} };
  return pushCache;
}

function savePush() {
  if (!pushCache) return;
  try { writeJson(PUSH_FILE, pushCache); } catch (e) { /* 磁盘满之类的先放过 */ }
}

/** 推送是不是真的能发（密钥/团队号/开关都齐了） */
function pushReady() {
  const c = readPush().config;
  if (!c.enabled || !c.teamId || !c.keyId || !c.bundleId) return false;
  if (!c.keyText && !c.keyPath) return false;
  if (c.keyPath && !fs.existsSync(c.keyPath)) return false;
  return true;
}

/** 某个人现在有没有活着的实时连接（有就不推系统通知） */
function isUserConnected(userId) {
  const set = connections.get(userId);
  if (!set) return false;
  let alive = false;
  set.forEach((s) => { if (!s.destroyed) alive = true; });
  return alive;
}

/* APNs 用的是 ES256 签的 JWT；苹果要求最多 1 小时换一次，这里 50 分钟换一次 */
let jwtCache = { at: 0, token: '', key: '' };

function apnsJwt() {
  const c = readPush().config;
  const key = c.keyText || (c.keyPath ? fs.readFileSync(c.keyPath, 'utf8') : '');
  const now = Date.now();
  if (jwtCache.token && jwtCache.key === key && now - jwtCache.at < 50 * 60 * 1000) return jwtCache.token;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const head = b64({ alg: 'ES256', kid: c.keyId });
  const claims = b64({ iss: c.teamId, iat: Math.floor(now / 1000) });
  const signing = head + '.' + claims;
  /* ES256 的 JWT 签名必须是 r||s 的原始格式（不是 DER），所以要点名 ieee-p1363 */
  const sig = crypto.sign('sha256', Buffer.from(signing), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  jwtCache = { at: now, token: signing + '.' + sig, key };
  return jwtCache.token;
}

/** 真发一条 APNs 通知；返回 { ok, status, reason } */
function apnsSend(deviceToken, sandbox, payload) {
  return new Promise((resolve) => {
    const c = readPush().config;
    const host = sandbox ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    let done = false;
    let client = null;
    const finish = (r) => {
      if (done) return;
      done = true;
      try { if (client) client.close(); } catch (e) { }
      resolve(r);
    };
    try {
      client = http2.connect(host);
    } catch (e) {
      return finish({ ok: false, status: 0, reason: String(e && e.message || e) });
    }
    client.on('error', (e) => finish({ ok: false, status: 0, reason: String(e && e.message || e) }));
    let req = null;
    try {
      req = client.request({
        ':method': 'POST',
        ':path': '/3/device/' + deviceToken,
        authorization: 'bearer ' + apnsJwt(),
        'apns-topic': c.bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': String(Math.floor(Date.now() / 1000) + 3600),
        'content-type': 'application/json'
      });
    } catch (e) {
      return finish({ ok: false, status: 0, reason: String(e && e.message || e) });
    }
    let status = 0;
    let text = '';
    req.on('response', (h) => { status = Number(h[':status']) || 0; });
    req.setEncoding('utf8');
    req.on('data', (d) => { if (text.length < 400) text += d; });
    req.on('end', () => finish({ ok: status === 200, status, reason: text }));
    req.on('error', (e) => finish({ ok: false, status: 0, reason: String(e && e.message || e) }));
    req.end(JSON.stringify(payload));
    setTimeout(() => finish({ ok: false, status: 0, reason: 'timeout' }), 8000);
  });
}

function pushRemoveToken(userId, token) {
  const p = readPush();
  if (!p.tokens[userId]) return;
  p.tokens[userId] = p.tokens[userId].filter((d) => d.token !== token);
  if (!p.tokens[userId].length) delete p.tokens[userId];
  savePush();
}

/** 记一条推送日志（只留最近 300 条，后台页面能看到发没发出去） */
function pushLog(row) {
  try {
    fs.appendFileSync(path.join(DATA_DIR, 'push-log.jsonl'), JSON.stringify(Object.assign({ at: now() }, row)) + '\n', 'utf8');
  } catch (e) { }
  try {
    const f = path.join(DATA_DIR, 'push-log.jsonl');
    const lines = fs.readFileSync(f, 'utf8').trim().split('\n');
    if (lines.length > 300) fs.writeFileSync(f, lines.slice(-300).join('\n') + '\n', 'utf8');
  } catch (e) { }
}

/** 某个人所有会话的未读总数 —— 推到手机上就是「桌面图标右上角那个数字」 */
function unreadTotalOf(userId) {
  let n = 0;
  chatsOf(userId).forEach((c) => { n += unreadCount(userId, c); });
  return n;
}

function pushPreview(kind, content) {
  if (kind === 'image') return '[图片]';
  if (kind === 'audio') return '[语音]';
  if (kind === 'file') return '[文件]';
  if (kind === 'location') return '[位置]';
  if (kind === 'transfer') return '[转账]';
  if (kind === 'redpacket') return '[红包]';
  if (kind === 'gift') return '[礼物]';
  if (kind === 'link') {
    try { return '[' + (JSON.parse(content).title || '链接') + ']'; } catch (e) { return '[链接]'; }
  }
  return str(content, 80);
}

/**
 * 给一个人推系统通知。
 * opts: { kind: 'message'|'friend'|'call', title, body, chatId, fromId, sound, badge }
 */
async function pushToUser(userId, opts) {
  if (!userId) return { sent: 0, reason: 'no-user' };
  const p = readPush();
  const c = p.config;
  if (opts.kind === 'message' && c.onMessage === false) return { sent: 0, reason: 'off' };
  if (opts.kind === 'friend' && c.onFriend === false) return { sent: 0, reason: 'off' };
  if (opts.kind === 'call' && c.onCall === false) return { sent: 0, reason: 'off' };
  if (!pushReady()) {
    pushLog({ userId, kind: opts.kind, title: opts.title, skipped: 'not-configured' });
    return { sent: 0, reason: 'not-configured' };
  }
  const devices = p.tokens[userId] || [];
  if (!devices.length) return { sent: 0, reason: 'no-device' };
  let sent = 0;
  /* 桌面图标上的红点数字：不传就按「当前未读总数」算，和微信一样 */
  const badge = typeof opts.badge === 'number' ? opts.badge : unreadTotalOf(userId);
  for (const d of devices) {
    const payload = {
      aps: Object.assign({
        alert: { title: String(opts.title || '').slice(0, 60), body: String(opts.body || '').slice(0, 160) },
        sound: opts.sound === false ? undefined : 'default',
        'thread-id': opts.chatId || opts.kind || 'chris',
        'mutable-content': 0
      }, { badge: badge }),
      /* 折叠：同一个会话连着来消息，通知只留最新一条（微信就是这个行为）。
         注意 apns-collapse-id 要放在 payload 顶层，不是 aps 里面。 */
      'apns-collapse-id': opts.collapse ? String(opts.collapse).slice(0, 64) : undefined,
      chatId: opts.chatId || '',
      fromId: opts.fromId || '',
      kind: opts.kind || ''
    };
    const r = await apnsSend(d.token, d.env ? d.env === 'sandbox' : !!c.sandbox, payload);
    if (r.ok) sent += 1;
    const bad = r.status === 400 || r.status === 410 || /BadDeviceToken|Unregistered|DeviceTokenNotForTopic/.test(String(r.reason || ''));
    pushLog({
      userId, kind: opts.kind, title: opts.title, ok: !!r.ok, status: r.status,
      reason: String(r.reason || '').slice(0, 120), token: String(d.token || '').slice(0, 8) + '…'
    });
    if (!r.ok && bad) pushRemoveToken(userId, d.token);
  }
  return { sent, reason: 'ok' };
}

/** 一条消息落库以后：没连着实时通道的人给他推系统通知 */
/** 现在是不是在这个人的「免打扰时段」里（22:00—07:00 这种跨天也算） */
function inQuietHours(n) {
  const a = String((n && n.muteStart) || '').trim();
  const b = String((n && n.muteEnd) || '').trim();
  if (!/^\d{2}:\d{2}$/.test(a) || !/^\d{2}:\d{2}$/.test(b)) return false;
  const toMin = (s) => Number(s.slice(0, 2)) * 60 + Number(s.slice(3, 5));
  const start = toMin(a), end = toMin(b);
  if (start === end) return false;
  const now = new Date();
  const cur = now.getHours() * 60 + now.getMinutes();
  return start < end ? (cur >= start && cur < end) : (cur >= start || cur < end);
}

function pushForMessage(sender, chat, message) {
  const p = readPush().config;
  if (!p.onMessage) return;
  /* 微信那套规则：系统消息、撤回提示不推；自己发的不推；在线的（长连接活着）不推 */
  if (!message || message.kind === 'system' || message.recalled) return;
  const title = chat.type === 'group'
    ? (chat.title || '群聊')
    : (sender.nickname || sender.username || '新消息');
  const detail = chat.type === 'group'
    ? (sender.nickname || sender.username || '') + '：' + pushPreview(message.kind, message.content)
    : pushPreview(message.kind, message.content);
  chat.memberIds.forEach((id) => {
    if (id === sender.id) return;
    const who = findUser(id);
    if (!who || who.bot) return;              // 机器人不用推
    if (isUserConnected(id)) return;          // 在线（连着长连接）就不推，避免重复提醒
    const n = userNotify(who);
    if (n.on === false) return;                                  // 全局「新消息通知」关了
    if ((chat.mutedFor || []).includes(id)) return;              // 这个会话开了消息免打扰
    if (inQuietHours(n)) return;                                 // 免打扰时段：不响不震也不打扰
    /* 「通知显示消息详情」关掉：只提示"你收到一条新消息"（微信就是这样） */
    const body = n.showDetail === false ? '你收到一条新消息' : detail;
    pushToUser(id, {
      kind: 'message', title, body, chatId: chat.id, fromId: sender.id,
      sound: n.sound !== false,
      /* 同一个会话的推送折叠成一条（微信：同一个聊天连着来消息只留最新那条） */
      collapse: chat.id
    }).catch(() => { });
  });
}

/* ============================================================
   朋友资料（微信「设置备注和标签」那套）
   每个人对每个好友可以单独设：备注名、标签、星标、朋友权限（看他朋友圈 / 只聊天）、
   拉黑。数据存在 data/friendmeta.json，按「谁设的 → 设的是谁」两层存。
   备注名是**服务器端替换显示**的：通讯录名字、会话标题、群聊里的发送者名字
   都会用备注 —— 所以老版本 App 不用装包也能看到备注生效。
   ============================================================ */
const FRIEND_META_FILE = path.join(DATA_DIR, 'friendmeta.json');
let friendMetaCache = null;

function readFriendMeta() {
  if (friendMetaCache) return friendMetaCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(FRIEND_META_FILE, 'utf8')); } catch (e) { raw = {}; }
  friendMetaCache = { byOwner: (raw && typeof raw.byOwner === 'object' && raw.byOwner) ? raw.byOwner : {} };
  return friendMetaCache;
}

function saveFriendMeta() {
  if (!friendMetaCache) return;
  try { writeJson(FRIEND_META_FILE, friendMetaCache); } catch (e) { }
}

/** 我对某个人设的资料（没人设过就返回空对象） */
function metaOf(ownerId, friendId) {
  if (!ownerId || !friendId) return {};
  const m = readFriendMeta().byOwner[ownerId];
  const row = m ? m[friendId] : null;
  return row && typeof row === 'object' ? row : {};
}

function setMeta(ownerId, friendId, patch) {
  const dbm = readFriendMeta();
  if (!dbm.byOwner[ownerId]) dbm.byOwner[ownerId] = {};
  const cur = dbm.byOwner[ownerId][friendId] || {};
  const next = Object.assign({}, cur, patch);
  if (!next.remark) delete next.remark;
  if (Array.isArray(next.tags)) {
    next.tags = next.tags.map((t) => String(t).trim().slice(0, 12)).filter(Boolean).slice(0, 10);
    if (!next.tags.length) delete next.tags;
  }
  dbm.byOwner[ownerId][friendId] = next;
  saveFriendMeta();
  return next;
}

/** 显示用的名字：有备注就用备注（微信就是这样），没有就用昵称 */
function displayNameFor(ownerId, user) {
  if (!user) return '';
  const base = user.nickname || user.username || '';
  if (!ownerId) return base;
  const m = metaOf(ownerId, user.id);
  return (m.remark && String(m.remark).trim()) ? String(m.remark).trim() : base;
}

/** 我有没有拉黑他（拉黑以后他发不进来消息、也看不到我的朋友圈） */
function blockedByUser(ownerId, otherId) {
  return metaOf(ownerId, otherId).block === true;
}

/** 两个人之间任何一边拉黑了，就不让单聊消息通过 */
function chatBlockedBetween(aId, bId) {
  return blockedByUser(aId, bId) || blockedByUser(bId, aId);
}

/** 他能不能看我的朋友圈：我有没有「不让他看」（这里用 block + noMoments 表示） */
function momentsHiddenFrom(ownerId, viewerId) {
  const m = metaOf(ownerId, viewerId);
  return m.block === true || m.hideMyMoments === true;
}

/* ------------------------------------------------------------ 语音通话 */

// 进行中的通话：callId -> { id, from, to, state, startedAt, timer }
const calls = new Map();

/** 设备确认登录的登录码：6 位数字、3 分钟有效、一次性 */
const pairCodes = new Map();
const PAIR_TTL_MS = 3 * 60 * 1000;
function prunePairCodes() {
  const t = Date.now();
  pairCodes.forEach((rec, code) => { if (rec.expiresAt <= t) pairCodes.delete(code); });
}
const CALL_RING_MS = 60000;   // 60 秒没人接才算未接（用户要求响久一点）

/** 注册用的图形验证码：2 分钟有效、一次性（仿 QQ 注册页那行验证码） */
const captchas = new Map();
const CAPTCHA_TTL_MS = 2 * 60 * 1000;
function pruneCaptchas() {
  const t = Date.now();
  captchas.forEach((rec, id) => { if (rec.expiresAt <= t) captchas.delete(id); });
}

/* ------------------------------------------------- 验证码（不许带明文）
   以前是把字符直接写进 SVG 的 <text> 里 —— 任何脚本一行正则就能抠出答案，
   等于没有验证码。现在用 5×7 点阵把字符画成一堆小方块，
   SVG 里只有一串坐标，没有文字，脚本要解就得自己写 OCR。
   同时每个字符单独旋转、加噪点干扰线。 */
const CAPTCHA_FONT = {
  A: [14, 17, 17, 31, 17, 17, 17], B: [30, 17, 17, 30, 17, 17, 30],
  C: [14, 17, 16, 16, 16, 17, 14], D: [30, 17, 17, 17, 17, 17, 30],
  E: [31, 16, 16, 30, 16, 16, 31], F: [31, 16, 16, 30, 16, 16, 16],
  G: [14, 17, 16, 23, 17, 17, 15], H: [17, 17, 17, 31, 17, 17, 17],
  J: [7, 2, 2, 2, 2, 18, 12], K: [17, 18, 20, 24, 20, 18, 17],
  L: [16, 16, 16, 16, 16, 16, 31], M: [17, 27, 21, 21, 17, 17, 17],
  N: [17, 25, 21, 19, 17, 17, 17], P: [30, 17, 17, 30, 16, 16, 16],
  Q: [14, 17, 17, 17, 21, 18, 13], R: [30, 17, 17, 30, 20, 18, 17],
  S: [15, 16, 16, 14, 1, 1, 30], T: [31, 4, 4, 4, 4, 4, 4],
  U: [17, 17, 17, 17, 17, 17, 14], V: [17, 17, 17, 17, 17, 10, 4],
  W: [17, 17, 17, 21, 21, 21, 10], X: [17, 17, 10, 4, 10, 17, 17],
  Y: [17, 17, 10, 4, 4, 4, 4], Z: [31, 1, 2, 4, 8, 16, 31],
  2: [14, 17, 1, 2, 4, 8, 31], 3: [31, 2, 4, 2, 1, 17, 14],
  4: [2, 6, 10, 18, 31, 2, 2], 5: [31, 16, 30, 1, 1, 17, 14],
  6: [6, 8, 16, 30, 17, 17, 14], 7: [31, 1, 2, 4, 8, 8, 8],
  8: [14, 17, 17, 14, 17, 17, 14], 9: [14, 17, 17, 15, 1, 2, 12]
};

/* ============================================================
   登录滑动验证（拖滑块拼图）
     ① 客户端 GET /api/slider 领一道题：缺口位置在服务端随机定
     ② 用户把滑块拖到缺口上，客户端把最终位置 POST /api/slider/verify
     ③ 位置对上（±容差）→ 发一张**一次性通行证**（3 分钟、用掉即废）
     ④ 登录时必须带 sliderTicket，服务端验票（且收走）才继续
   想关掉：data/security.json 里写 "sliderLogin": 0，即时生效、不用重启。
   说明：这是「挡脚本、加摩擦」的一层，不是密码学保证 ——
        缺口位置要发给客户端画图，写死的脚本照样能算出来；
        真正的后手是登录限流（10 分钟错 8 次就封）和下面这张一次性票。
   ============================================================ */
const SLIDER_W = 260;          // 坐标系（客户端按这个宽渲染）
const SLIDER_H = 130;
const SLIDER_PIECE = 44;       // 滑块 / 缺口边长
const SLIDER_TOL = 6;          // 允许差几个像素
const SLIDER_TTL_MS = 3 * 60 * 1000;
const sliderChallenges = new Map();   // id -> { x, y, exp, used, fail }
const sliderTickets = new Map();      // ticket -> { exp, used }
const sliderRate = new Map();         // ip -> { n, first }

function pruneSlider() {
  const t = Date.now();
  sliderChallenges.forEach((r, id) => { if (r.exp <= t) sliderChallenges.delete(id); });
  sliderTickets.forEach((r, k) => { if (r.exp <= t || r.used) sliderTickets.delete(k); });
  sliderRate.forEach((r, k) => { if (t - r.first > 10 * 60 * 1000) sliderRate.delete(k); });
}

/** 出题：缺口左边缘的 x、上边缘的 y 都由服务端随机定 */
function makeSliderChallenge() {
  pruneSlider();
  const pad = 8;
  const x = pad + Math.round(Math.random() * (SLIDER_W - SLIDER_PIECE - pad * 2));
  const y = pad + Math.round(Math.random() * (SLIDER_H - SLIDER_PIECE - pad * 2));
  const id = uid('sld');
  sliderChallenges.set(id, { x, y, exp: Date.now() + SLIDER_TTL_MS, used: false, fail: 0 });
  return {
    id,
    width: SLIDER_W,
    height: SLIDER_H,
    piece: SLIDER_PIECE,
    // 给客户端画图和画缺口用（缺口就在这个位置）
    targetX: x,
    targetY: y,
    tolerance: SLIDER_TOL,
    // 背景图案用这个种子生成：客户端自己不发送任何图案，只报位置
    seed: Math.floor(Math.random() * 100000),
    expiresIn: Math.round(SLIDER_TTL_MS / 1000)
  };
}

/** 校验滑块位置；对了发一张一次性通行证 */
function checkSlider(id, x, y) {
  pruneSlider();
  const rec = sliderChallenges.get(id);
  if (!rec || rec.used || rec.exp <= Date.now()) return { error: '这道题过期了，重新滑一次' };
  /* 只看横向位置：缺口和滑块都在同一条水平线上，客户端也拖不动纵向 */
  const dx = Math.abs(Number(x) - rec.x);
  if (!isFinite(dx) || dx > SLIDER_TOL) {
    rec.fail = (rec.fail || 0) + 1;
    if (rec.fail >= 5) sliderChallenges.delete(id);
    return { error: '没对上，再试一次' };
  }
  rec.used = true;
  sliderChallenges.delete(id);
  const ticket = crypto.randomBytes(24).toString('hex');
  sliderTickets.set(ticket, { exp: Date.now() + SLIDER_TTL_MS, used: false });
  return { ticket, expiresIn: Math.round(SLIDER_TTL_MS / 1000) };
}

/** 登录时验票：票只能用一次，用过 / 过期都不认 */
function consumeSliderTicket(ticket) {
  pruneSlider();
  const key = String(ticket || '');
  if (!key) return false;
  const rec = sliderTickets.get(key);
  if (!rec || rec.used || rec.exp <= Date.now()) return false;
  rec.used = true;
  sliderTickets.delete(key);
  return true;
}

/** 同一个 IP 10 分钟最多换 40 次题（防刷题脚本） */
function sliderRateAllow(ip) {
  const t = Date.now();
  const r = sliderRate.get(ip);
  if (!r || t - r.first > 10 * 60 * 1000) { sliderRate.set(ip, { n: 1, first: t }); return true; }
  r.n += 1;
  return r.n <= 40;
}

function makeCaptcha() {
  pruneCaptchas();
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let text = '';
  for (let i = 0; i < 4; i++) text += chars[Math.floor(Math.random() * chars.length)];
  const id = uid('cap');
  captchas.set(id, { text, expiresAt: Date.now() + CAPTCHA_TTL_MS });
  const colors = ['#0f7cff', '#0a5ce0', '#2fa8ff', '#1e40af'];
  let glyphs = '';
  for (let i = 0; i < text.length; i++) {
    const bits = CAPTCHA_FONT[text[i]] || CAPTCHA_FONT.A;
    const ox = 18 + i * 36, oy = 14 + Math.round((Math.random() - 0.5) * 6);
    const rot = Math.round((Math.random() - 0.5) * 34);
    const fill = colors[Math.floor(Math.random() * colors.length)];
    let px = '';
    for (let r = 0; r < 7; r++) {
      for (let c = 0; c < 5; c++) {
        if (!(bits[r] & (1 << (4 - c)))) continue;
        px += '<rect x="' + (ox + c * 5.4) + '" y="' + (oy + r * 5.4) + '" width="4.6" height="4.6" rx="1.4"/>';
      }
    }
    glyphs += '<g fill="' + fill + '" transform="rotate(' + rot + ' ' + ox + ' ' + oy + ')">' + px + '</g>';
  }
  let noise = '';
  for (let i = 0; i < 6; i++) {
    noise += '<path d="M' + Math.round(Math.random() * 156) + ' ' + Math.round(Math.random() * 62) +
      ' Q' + Math.round(Math.random() * 156) + ' ' + Math.round(Math.random() * 62) +
      ' ' + Math.round(Math.random() * 156) + ' ' + Math.round(Math.random() * 62) +
      '" stroke="rgba(15,124,255,0.35)" fill="none" stroke-width="1.4"/>';
  }
  let dots = '';
  for (let i = 0; i < 40; i++) {
    dots += '<circle cx="' + Math.round(Math.random() * 156) + '" cy="' + Math.round(Math.random() * 62) +
      '" r="1.1" fill="rgba(15,124,255,0.35)"/>';
  }
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="64" viewBox="0 0 160 64">' +
    '<rect width="160" height="64" rx="12" fill="#f2f6ff"/>' + noise + dots + glyphs + '</svg>';
  return { id, svg };
}

function checkCaptcha(id, answer) {
  pruneCaptchas();
  const rec = captchas.get(String(id || ''));
  if (!rec) return false;
  captchas.delete(String(id || ''));   // 一次性，用完作废
  return String(answer || '').trim().toUpperCase() === rec.text;
}

function callSend(userId, payload) { return sendTo(userId, payload); }

/** 通话结束后往两个人的会话里插一条系统消息（微信也是这么记的）。
    meta 里带通话本身的信息（音频/视频、接通没接通、时长），
    客户端拿它画电话图标和「通话时长 00:12」这种行，而不是靠猜文字。 */
function callLog(fromId, toId, text, meta) {
  const a = findUser(fromId);
  const b = findUser(toId);
  if (!a || !b) return;
  let chat = directChatBetween(fromId, toId);
  if (!chat) {
    chat = {
      id: uid('c'), type: 'direct', name: '', avatar: '',
      memberIds: [fromId, toId], ownerId: fromId, seq: 0, createdAt: now()
    };
    db.chats.push(chat);
  }
  chat.hiddenFor = (chat.hiddenFor || []).filter((id) => id !== fromId && id !== toId);
  chat.seq = (chat.seq || 0) + 1;
  const message = {
    id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
    kind: 'system', content: text, createdAt: now(), recalled: false
  };
  /* 通话记录要带上「谁打的」：客户端靠它把这条记录摆到左边还是右边（微信就是这么摆的）。
     老记录里没有 from，客户端会退回「居中一行灰字」。 */
  if (meta) message.call = Object.assign({}, meta, { from: fromId, to: toId });
  appendMessage(chat.id, message);
  saveChats();
  chat.memberIds.forEach((id) => {
    sendTo(id, { type: 'message', message, chat: chatSummary(chat, id), clientId: null });
  });
}

/** 接通后的通话时长文案：微信通话记录里就是「通话时长 00:12」这种 */
function callDuration(call) {
  const secs = Math.max(1, Math.round((Date.now() - call.startedAt) / 1000));
  const mm = Math.floor(secs / 60);
  const ss = ('0' + (secs % 60)).slice(-2);
  /* 微信里语音/视频都写「通话时长 分:秒」，靠前面那个图标区分语音还是视频 */
  return { secs: secs, text: '通话时长 ' + ('0' + mm).slice(-2) + ':' + ss };
}

/* 通话流水：谁打给谁、什么动作、最后为什么结束、对面当时在不在线。
   写在 data/call-trace.log 里，「聊天页怎么没有提示」这种问题一看就知道
   是没打出去、对面不在线，还是打了但没接。 */
function callTrace(line) {
  try {
    fs.appendFileSync(path.join(DATA_DIR, 'call-trace.log'),
      '[' + new Date().toISOString() + '] ' + line + '\n', 'utf8');
  } catch (err) { /* 记不上就算了，不能因为日志把通话弄挂 */ }
}

function callEnd(call, reason, extra) {
  if (call.timer) clearTimeout(call.timer);
  /* 宽限期定时器要清掉：不然通话都结束了它还会再结束一次（日志里会出现重复的 end） */
  if (call.dcTimer) { clearTimeout(call.dcTimer); call.dcTimer = null; }
  calls.delete(call.id);
  callTrace('end ' + call.from + ' -> ' + call.to + ' reason=' + reason
    + ' media=' + (call.media || 'audio') + ' state=' + call.state
    /* 这通电话两边各发了多少帧语音：0 = 那边的麦克风没起来（听不到就是这么来的） */
    + ' 语音帧 主叫发的=' + (((call.audioSeen || {})[call.from]) || 0)
    + ' 被叫发的=' + (((call.audioSeen || {})[call.to]) || 0));
  const other = { from: call.to, to: call.from, callId: call.id, reason, media: call.media || 'audio' };
  callSend(call.from, Object.assign({ type: 'call', action: 'end' }, other, extra || {}, { peerId: call.to }));
  callSend(call.to, Object.assign({ type: 'call', action: 'end' }, other, extra || {}, { peerId: call.from }));
  const media = call.media || 'audio';
  if (reason === 'hangup' || reason === 'disconnected') {
    const t = callDuration(call);
    callLog(call.from, call.to, t.text,
      { media: media, state: 'answered', secs: t.secs });
  } else if (reason === 'rejected') {
    callLog(call.from, call.to, '对方已拒绝', { media: media, state: 'rejected' });
  } else if (reason === 'cancel') {
    callLog(call.from, call.to, '已取消', { media: media, state: 'cancelled' });
  } else if (reason === 'timeout') {
    /* 响了 45 秒没人接：微信两边都记「对方无应答」 */
    callLog(call.from, call.to, '对方无应答', { media: media, state: 'noAnswer' });
  } else if (reason === 'offline') {
    /* 对面根本没在线（App 没开 / 长连接断着）：以前这里什么都不记，
       所以用户打完一看聊天页「没有提示」。微信这种也会留一条。 */
    callLog(call.from, call.to, '对方不在线', { media: media, state: 'offline' });
  }
}

/* 每条连接每秒钟收了多少帧（防穷举/刷屏），socket 断开自动回收 */
const wsFrames = new Map();

function handleClientMessage(user, socket, raw) {
  let msg;
  try { msg = JSON.parse(raw); } catch (err) { return; }
  if (!msg || typeof msg.type !== 'string') return;

  /* 单条连接的信令频率限制：正常聊天/通话每秒撑死几十条，
     有人拿一条连接猛刷（比如穷举 callId、刷屏）就直接断开。 */
  {
    const nowMs = Date.now();
    let r = wsFrames.get(socket);
    if (!r || nowMs - r.t > 1000) { r = { t: nowMs, n: 0 }; wsFrames.set(socket, r); }
    r.n += 1;
    if (r.n > 200) {
      try { socket.destroy(); } catch (err) { }
      return;
    }
    if (wsFrames.size > 2000) wsFrames.clear();
  }

  if (msg.type === 'ping') {
    ws.sendText(socket, JSON.stringify({ type: 'pong', t: Date.now() }));
    return;
  }

  if (msg.type === 'typing') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    sendToChat(chat, {
      type: 'typing', chatId: chat.id, userId: user.id, nickname: user.nickname, at: Date.now()
    }, user.id);
    return;
  }

  if (msg.type === 'read') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    sendToChat(chat, { type: 'read', chatId: chat.id, userId: user.id, seq: lastSeq }, user.id);
    return;
  }

  if (msg.type === 'send') {
    const result = deliverMessage(user, msg.chatId, msg.kind, msg.content, msg.clientId);
    if (result.error) {
      ws.sendText(socket, JSON.stringify({ type: 'error', clientId: msg.clientId, error: result.error }));
    }
    return;
  }

  /* ---------------------------------------------------------- 直播信令（真视频直播）
     主播把画面推给每个观众（一路一个 WebRTC 连接），这里只做「转发」：
       hello 观众举手 → 转给主播；sig 是 offer/answer/ice → 原样转给对方；
       bye 谁走了 → 告诉另一头收摊。 */
  if (msg.type === 'live' && (msg.action === 'hello' || msg.action === 'sig' || msg.action === 'bye')) {
    const roomId = str(msg.roomId, 40);
    const to = str(msg.to, 40);
    if (!roomId || !to) return;
    /* 只允许同一个房间里的人互相发（观众↔主播） */
    const viewers = liveViewers.get(roomId);
    const inRoom = (viewers && viewers.has(user.id)) || (viewers && viewers.has(to));
    if (!inRoom) return;
    if (msg.action === 'hello') {
      liveHosts.set(roomId, user.id);          // 谁举手谁是主播（同一个房间只认一个）
      callTrace('直播 ' + user.id + ' 申请开播 room=' + roomId);
    }
    const payload = {
      type: 'live', action: msg.action, roomId: roomId,
      sigKind: str(msg.sigKind, 20), from: user.id,
      sdp: msg.sdp || null, candidate: msg.candidate || null
    };
    const delivered = sendTo(to, payload);
    if (!delivered && msg.action === 'hello') {
      /* 主播不在线：告诉观众一声 */
      sendTo(user.id, { type: 'live', action: 'hostGone', roomId: roomId });
    }
    return;
  }

  /* ---------------------------------------------------------- 语音通话信令 */
  if (msg.type === 'call') {
    const action = String(msg.action || '');
    const callId = str(msg.callId, 60);

    /* 通话排查：凡是带 SDP 的消息（invite / answer / sdp）都记一行候选摘要 ——
       网页版把候选打包在 SDP 里发，光看 ice 消息是看不到它带了什么的。 */
    if (msg.sdp && msg.sdp.sdp) {
      try {
        const s = String(msg.sdp.sdp);
        const lines = s.split('\n').filter((l) => l.indexOf('a=candidate:') === 0);
        const tcp = lines.filter((l) => /\stcp\s/.test(l)).length;
        const relay = lines.filter((l) => / typ relay/.test(l)).length;
        const host = lines.filter((l) => / typ host/.test(l)).length;
        const srflx = lines.filter((l) => / typ srflx/.test(l)).length;
        callTrace('sdp ' + (user.username || user.id) + ' ' + action + ' 候选=' + lines.length
          + ' tcp=' + tcp + ' relay=' + relay + ' srflx=' + srflx + ' host=' + host
          + (lines[0] ? ' 首条=' + lines[0].replace('a=candidate:', '').slice(0, 80) : ''));
      } catch (e) { }
    }

    /* 通话前先问一句：对端和我是不是同一个网络？
       same=true  → 客户端直连（快，不占服务器带宽）
       same=false → 客户端强制走中继（4G↔宽带这种打洞经常只通一半） */
    if (action === 'net') {
      const peer = findUser(str(msg.peerId, 40));
      const mine = userIps.get(user.id) || '';
      const his = peer ? (userIps.get(peer.id) || '') : '';
      const same = !!his && !!mine && his === mine;
      ws.sendText(socket, JSON.stringify({ type: 'call', action: 'net', peerId: peer ? peer.id : '', same }));
      callTrace('net ' + user.id + ' (' + mine + ') vs ' + (peer ? peer.id : '?') + ' (' + his + ') same=' + same);
      return;
    }
    if (!callId) return;

    if (action === 'invite') {
      const target = findUser(str(msg.toUserId, 40));
      if (!target) return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '用户不存在' }));
      if (target.id === user.id) return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '不能给自己打电话' }));
      if (!friendIds(user.id).includes(target.id)) return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '先加为好友才能通话' }));
      callTrace('invite ' + user.id + ' -> ' + target.id + ' media=' + (msg.media === 'video' ? 'video' : 'audio')
        + ' 对方在线=' + connections.has(target.id)
        + ' 主叫版本=' + (socket.__appBuild || '?')
        + ' 被叫版本=' + (peerBuildOf(target.id) || '?'));
      const busy = Array.from(calls.values()).find((c) => c.state !== 'ended' && (c.from === target.id || c.to === target.id));
      if (busy) {
        callLog(user.id, target.id, '对方忙线中', { media: msg.media === 'video' ? 'video' : 'audio', state: 'busy' });
        return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: target.nickname + ' 正在通话中' }));
      }
      const media = msg.media === 'video' ? 'video' : 'audio';
      const call = { id: callId, from: user.id, to: target.id, state: 'ringing', startedAt: Date.now(), timer: null, media };
      /* 先记住 invite 里的 SDP：对方待会儿才上线时，可以原样再送一遍 */
      call.sdp = msg.sdp || null;
      call.timer = setTimeout(() => {
        const cur = calls.get(callId);
        if (cur && cur.state === 'ringing') callEnd(cur, 'timeout');
      }, CALL_RING_MS);
      calls.set(callId, call);
      const delivered = callSend(target.id, {
        type: 'call', action: 'incoming', callId, media,
        peerId: user.id, peerName: user.nickname, peerAvatar: user.avatar || '', sdp: msg.sdp || null
      });
      if (!delivered) {
        /* 对方手机没连着（在后台 / 被杀掉）→ 推一条通知，至少让 TA 看到有人打过电话 */
        pushToUser(target.id, {
          kind: 'call',
          title: media === 'video' ? '视频通话' : '语音通话',
          body: (user.nickname || user.username || '有人') + ' 邀请你' + (media === 'video' ? '视频' : '语音') + '通话'
        }).catch(() => { });
        /* 微信那样：推送叫醒对方，但**先别挂断** —— 继续响铃 45 秒。
           对方点通知/打开 App 上线后，我们会把这次 invite 再送一遍（见 WS 连接处），就能接上；
           45 秒还没接才结束，并记一条「对方无应答」。 */
        return ws.sendText(socket, JSON.stringify({
          type: 'call', action: 'ringing', callId, media,
          peerId: target.id, peerName: target.nickname, peerAvatar: target.avatar || '',
          offline: true
        }));
      }
      ws.sendText(socket, JSON.stringify({ type: 'call', action: 'ringing', callId, media, peerId: target.id, peerName: target.nickname, peerAvatar: target.avatar || '' }));
      return;
    }

    const call = calls.get(callId);
    // 通话不存在了（对方已挂断、或这条是迟到的候选）就静默忽略：
    // 不能回 call-error，否则会把对方那边还在进行的通话状态带崩
    if (!call) return;
    /* 安全：只有这通电话的双方能操作它。
       以前只校验了 accept —— 别人只要猜到 callId，就能掐断你的通话（reject/cancel/hangup），
       或者往你的通话里塞 SDP/ICE（劫持媒体）。callId 是 "call+毫秒+4位随机"，是能撞出来的。 */
    if (call.from !== user.id && call.to !== user.id) {
      ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '这通电话跟你没关系' }));
      return;
    }
    const peer = call.from === user.id ? call.to : call.from;

    if (action === 'accept') {
      if (call.to !== user.id) return;
      callTrace('accept ' + user.id + ' callId=' + callId);
      call.state = 'active';
      call.startedAt = Date.now();
      if (call.timer) { clearTimeout(call.timer); call.timer = null; }
      callSend(peer, { type: 'call', action: 'accepted', callId, media: call.media || 'audio', peerId: user.id });
      if (msg.sdp) callSend(call.from, { type: 'call', action: 'sdp', callId, peerId: user.id, sdp: msg.sdp });
      return;
    }

    if (action === 'reject') { if (call.to !== user.id) return; callTrace('reject ' + user.id + ' callId=' + callId); callEnd(call, 'rejected'); return; }
    /* 客户端「响了很久没人接」自己挂断时会带 reason:'timeout'，
       这样记的是「对方无应答」而不是「已取消」（用户明确要分开） */
    if (action === 'cancel') {
      if (call.from !== user.id) return;
      callTrace('cancel ' + user.id + ' callId=' + callId + ' reason=' + (msg.reason || ''));
      callEnd(call, msg.reason === 'timeout' ? 'timeout' : 'cancel');
      return;
    }
    if (action === 'hangup') callTrace('hangup ' + user.id + ' callId=' + callId);
    if (action === 'hangup') { callEnd(call, call.state === 'active' ? 'hangup' : 'cancel'); return; }

    // 一端把摄像头降级成语音时，通知对端也切成语音界面
    if (action === 'media') {
      call.media = msg.media === 'video' ? 'video' : 'audio';
      callSend(peer, { type: 'call', action: 'media', callId, peerId: user.id, media: call.media });
      return;
    }

    // 媒体协商：offer / answer / ice 原样转发给对方
    if (action === 'sdp' || action === 'ice') {
      const payload = { type: 'call', action, callId, peerId: user.id };
      if (action === 'sdp') payload.sdp = msg.sdp;
      else payload.candidate = msg.candidate;
      callSend(peer, payload);
      return;
    }

    /* 局域网语音通话：手机采好的音频帧（base64）原样转给对方。
       只在通话真正接通后才转发，没接通 / 已挂断的一律丢掉；
       一帧限长一点，防止有人拿这个通道灌大包。 */
    if (action === 'audio') {
      /* 语音通话兜底：被叫的 App 已经在推音频帧，说明 TA 那边确实点了接听
         （老版本客户端走语音这条路时**只推帧、不发 accept**）。
         不在这里补一刀的话：通话状态会一直卡在 ringing，下面那行直接把两边
         的音频帧全部丢掉 —— 表现就是「双方界面都写着通话中，但一个字都听不见」，
         主叫那边还一直停在「正在呼叫…」。 */
      if (call.state === 'ringing' && call.to === user.id) {
        call.state = 'active';
        call.startedAt = Date.now();
        if (call.timer) { clearTimeout(call.timer); call.timer = null; }
        callTrace('被叫开始推语音帧，视为已接听 ' + callId + '（老客户端不发 accept）');
        callSend(call.from, {
          type: 'call', action: 'accepted', callId, media: call.media || 'audio', peerId: user.id
        });
      }
      if (call.state !== 'active') return;
      const data = typeof msg.data === 'string' ? msg.data : '';
      if (!data || data.length > 24000) return;      // 约 18KB 原始音频
      /* 通话排查：每边第一帧记一行，之后每 200 帧记一次（看谁没在发声音） */
      if (!call.audioSeen) call.audioSeen = {};
      call.audioSeen[user.id] = (call.audioSeen[user.id] || 0) + 1;
      if (call.audioSeen[user.id] === 1 || call.audioSeen[user.id] % 200 === 0) {
        const other = findUser(call.from === user.id ? call.to : call.from);
        callTrace('audio ' + (user.username || user.id) + ' → ' + ((other && (other.username || other.id)) || '?')
          + ' 第 ' + call.audioSeen[user.id] + ' 帧');
      }
      callSend(peer, { type: 'call', action: 'audio', callId, peerId: user.id, data });
      return;
    }
    return;
  }

  if (msg.type === 'shake') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    sendToChat(chat, {
      type: 'shake', chatId: chat.id, from: user.id, nickname: user.nickname
    }, user.id);
  }
}

/* ============================================================
   腾讯云 TRTC（音视频通话）
   服务端只做两件事：
     ① 存 sdkAppId + SDK 密钥（data/trtc.json，**密钥不下发给客户端**）
     ② 给客户端签一张 UserSig（官方 TLSSigAPIv2 算法），并算一个双方一致的房间号
   客户端拿到 { sdkAppId, userId, userSig, roomId } 直接进房，
   媒体走腾讯云（不依赖自己的 TURN，所以家里的 UDP 被挡也不影响通话）。
   ============================================================ */
const TRTC_FILE = path.join(DATA_DIR, 'trtc.json');
const TRTC_DEFAULT = { enabled: false, sdkAppId: 0, secretKey: '', expireSeconds: 604800 };

function readTrtcCfg() {
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(TRTC_FILE, 'utf8')) || {}; } catch (err) { raw = {}; }
  /* 老后台是配在 branding.json 的 trtc 字段里的，这里兼容一下 */
  if (!raw.sdkAppId) {
    try {
      const b = readJson(path.join(DATA_DIR, 'branding.json'), {});
      if (b && b.trtc && b.trtc.sdkAppId) raw = b.trtc;
    } catch (err) { /* 忽略 */ }
  }
  return {
    enabled: raw.enabled === true,
    sdkAppId: Number(raw.sdkAppId) || 0,
    secretKey: String(raw.secretKey || ''),
    expireSeconds: Number(raw.expireSeconds) > 0 ? Number(raw.expireSeconds) : TRTC_DEFAULT.expireSeconds,
    /* 语音走不走 TRTC 的总开关（默认走）。设成 false 就一键退回自建转发：
       客户端对语音取签名会拿到失败，自己继续用服务器转发通道，不用重装 App。 */
    voiceEnabled: raw.voiceEnabled !== false
  };
}

/* 官方的 TLSSigAPIv2：HMAC-SHA256 签一段固定格式的文本，再压进一个 JSON 里做 deflate+base64。
   注：不带 userbuf 时，签名用的文本里**只有** identifier/sdkappid/time/expire 四行
   （userbuf 那行整行都不出现；这一点和官方 tls-sig-api-v2 逐字节对齐过）。 */
function trtcUserSig(userId, expireSeconds, nowSeconds) {
  const cfg = readTrtcCfg();
  if (!cfg.sdkAppId || !cfg.secretKey) return '';
  const time = Number(nowSeconds) || Math.floor(Date.now() / 1000);
  const expire = Number(expireSeconds) > 0 ? Number(expireSeconds) : cfg.expireSeconds;
  const raw = 'TLS.identifier:' + userId + '\n'
    + 'TLS.sdkappid:' + cfg.sdkAppId + '\n'
    + 'TLS.time:' + time + '\n'
    + 'TLS.expire:' + expire + '\n';
  const sig = crypto.createHmac('sha256', cfg.secretKey).update(raw).digest('base64');
  const doc = {
    'TLS.ver': '2.0',
    'TLS.identifier': String(userId),
    'TLS.sdkappid': Number(cfg.sdkAppId),
    'TLS.time': time,
    'TLS.expire': expire,
    'TLS.sig': sig
  };
  return zlib.deflateSync(Buffer.from(JSON.stringify(doc), 'utf8'))
    .toString('base64')
    .replace(/\+/g, '*')
    .replace(/\//g, '-')
    .replace(/=/g, '_');
}

/* 房间号：TRTC 的房间号是 32 位无符号整数，这里把会话 id 稳定地映射成一个数字，
   两边用同一个会话 id 算出来的房间号一定一样。 */
function trtcRoomId(seed) {
  const s = String(seed || 'room');
  let h = 2166136261;
  for (let i = 0; i < s.length; i += 1) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const n = (h >>> 0) % 2000000000;
  return n < 1000 ? n + 1000 : n;
}

function handleSocket(user, socket) {
  if (!connections.has(user.id)) connections.set(user.id, new Set());
  const set = connections.get(user.id);
  const first = set.size === 0;
  set.add(socket);
  if (first) notifyPresence(user.id, true);
  /* 重连回来了：把「闪断宽限期」取消掉，这一通电话继续（声音会接着传） */
  if (first) {
    calls.forEach((call) => {
      if (call.from !== user.id && call.to !== user.id) return;
      if (!call.dcTimer) return;
      clearTimeout(call.dcTimer);
      call.dcTimer = null;
      callTrace('重连回来，通话继续 ' + call.id);
    });
  }
  callTrace('ws 连上 ' + user.id + '（' + (user.nickname || user.username) + '）'
    + (socket.encrypted ? ' wss' : ' ws'));

  ws.sendText(socket, JSON.stringify({
    type: 'ready',
    user: publicUser(user),
    online: onlineFriendsOf(user.id),      // 只发好友，不发全站（见 friendStatusMap 上面的说明）
    onlineCount: connections.size,
    statuses: friendStatusMap(user.id),
    momentUnread: momentUnread(user.id),
    /* 重连时顺手把「待处理好友申请」也带上：手机在后台没收到推送，
       一回来就能把通讯录红点点亮，不用等用户去点通讯录 */
    friendRequests: pendingFriendRequests(user.id)
  }));

  ws.attach(socket, {
    onMessage: (text) => handleClientMessage(user, socket, text),
    onClose: () => {
      const s = connections.get(user.id);
      if (!s) return;
      s.delete(socket);
      if (s.size === 0) {
        connections.delete(user.id);
        callTrace('ws 断开 ' + user.id + '（' + (user.nickname || user.username) + '）');
        notifyPresence(user.id, false);
        /* 长连接偶尔会闪断（切 4G/Wi-Fi、进电梯、锁屏一下）：
           以前一断就把通话直接结束 → 表现是「打着打着自动挂断 + 中间那段没声音」。
           现在给 20 秒宽限期：这期间重连回来就继续这一通电话，
           只有真的 20 秒没回来才结束（响铃中的话仍然立刻取消，免得对面一直响）。 */
        calls.forEach((call) => {
          if (call.from !== user.id && call.to !== user.id) return;
          if (call.state !== 'active') {
            callEnd(call, 'cancel');
            return;
          }
          if (call.dcTimer) return;
          callTrace('ws 闪断：通话进入 20 秒宽限期 ' + call.id);
          call.dcTimer = setTimeout(() => {
            const c = calls.get(call.id);
            if (!c) return;
            callTrace('20 秒没重连回来，通话结束 ' + c.id);
            callEnd(c, 'disconnected');
          }, 20000);
        });
      }
    }
  });
}

/* ------------------------------------------------------------------ 消息 */

function deliverMessage(user, chatId, kind, content, clientId) {
  if (user.banned) return { error: '账号已被管理员禁用，无法发送消息' };
  const chat = db.chats.find((c) => c.id === chatId);
  if (!chat) return { error: '会话不存在' };
  if (!chat.memberIds.includes(user.id)) return { error: '你不在这个会话里' };
  /* 单聊：任何一边拉黑了，消息就不通（微信里对方看到「消息已发出，但被对方拒收了」） */
  if (chat.type === 'direct') {
    const peerId = chat.memberIds.find((id) => id !== user.id);
    if (peerId && chatBlockedBetween(user.id, peerId)) {
      return {
        error: blockedByUser(peerId, user.id)
          ? '消息已发出，但被对方拒收了'
          : '你已经把对方拉黑，先去资料页解除才能发消息'
      };
    }
  }

  /* 群禁言：全员禁言时只有群主能说话；被单独禁言的人也不能说 */
  if (chat.type === 'group') {
    const isOwner = chat.ownerId === user.id;
    if (chat.muteAll && !isOwner) return { error: '群主开启了全员禁言' };
    if (!isOwner && (chat.muteMembers || []).includes(user.id)) return { error: '你被群主禁言了' };
  }

  const allowed = ['text', 'image', 'file', 'audio', 'gift', 'transfer', 'location', 'redpacket', 'link'];
  const type = allowed.includes(kind) ? kind : 'text';
  /* IM 模块的开关：管理员关了哪一类就发不出去 */
  const imBlock = imKindBlocked(type);
  if (imBlock) return { error: imBlock };
  /* 视频通话/视频：type 里没有单独的 video，用「视频通话」开关拦 call 之外的视频文件 */
  if (type === 'file' && !readIm().video && /\.(mp4|mov|m4v|avi|mkv|webm|3gp|flv|wmv)(\?|$)/i.test(String(content || ''))) {
    return { error: '视频被管理员关闭了' };
  }
  /* 单个会话里发得太快 / 文字太长 */
  if (type === 'text' && String(content || '').length > readIm().maxTextLen) {
    return { error: '文字太长了（最多 ' + readIm().maxTextLen + ' 字）' };
  }
  /* 安全：非文本消息（图片/文件/语音）存的只是 /uploads 路径和少量参数，
     以前允许 200 万字符，客户端一发就能把聊天记录文件撑爆，现在压到 8000。 */
  let body = str(content, type === 'text' ? 4000 : 8000);
  /* 图片消息里塞的必须是本站图片 / 很小的 data:image，外链和脚本一律不收 */
  if (type === 'image') {
    const v = safeImageRef(body);
    if (v === null) return { error: '图片地址不合法' };
    body = v;
  }
  /* 链接卡片（AI 发的「点外卖 / 买东西」）：只收自家格式，网址必须是 http(s) */
  if (type === 'link') {
    let o = null;
    try { o = JSON.parse(body); } catch (e) { }
    if (!o || typeof o.url !== 'string' || !/^https?:\/\//.test(o.url)) return { error: '链接不合法' };
    body = JSON.stringify({
      title: String(o.title || '').slice(0, 40),
      sub: String(o.sub || '').slice(0, 80),
      url: o.url.slice(0, 500),
      scheme: String(o.scheme || '').slice(0, 300)
    });
  }
  if (!body) return { error: '消息内容为空' };

  /* 网关层敏感词过滤：命中直接拦下来，并记一条违规告警给审核员 */
  if (type === 'text') {
    const hit = sensitiveHit(body);
    if (hit) {
      recordViolation(user, chat, body, hit);
      return { error: '消息包含敏感词「' + hit + '」，已被拦截' };
    }
  }

  chat.seq = (chat.seq || 0) + 1;
  // 有新消息就把「已删除会话」的隐藏标记清掉，会话重新出现在双方列表里
  if (Array.isArray(chat.hiddenFor) && chat.hiddenFor.length) chat.hiddenFor = [];
  const message = {
    id: uid('m'),
    chatId: chat.id,
    seq: chat.seq,
    senderId: user.id,
    kind: type,
    content: body,
    createdAt: now(),
    recalled: false
  };
  appendMessage(chat.id, message);
  noteMessage();
  /* 落盘改成「攒一下再写」：以前每发一条消息都要重写整个 chats.json（1.5MB），
     压测时这是最大的瓶颈。现在最多 1.5 秒写一次，进程退出前再补一次。 */
  chatsDirty = true;

  if (!db.reads[user.id]) db.reads[user.id] = {};
  db.reads[user.id][chat.id] = message.seq;
  readsDirty = true;

  // 每个接收者的未读数不同，所以摘要要按人各算一份
  chat.memberIds.forEach((id) => {
    sendTo(id, {
      type: 'message',
      message,
      chat: chatSummary(chat, id, message),
      clientId: id === user.id ? (clientId || null) : null
    });
  });
  /* 手机没连着（在后台 / 被杀掉 / 没网）→ 给他推一条系统通知，微信也是这个逻辑 */
  try { pushForMessage(user, chat, message); } catch (e) { }
  /* 发给「AI 助手 / 管家」→ 机器人自动回一句（异步，不卡发送方） */
  const bot = botInChat(chat, user.id);
  if (bot && bot.username === 'kefu') {
    /* 客服：人工在后台「客服中心」回。没人在的时候先按知识库自动答一轮 */
    const sc = readSupport();
    const ac = readAiCfg();
    if (type === 'text') {
      /* 先看后台配的关键词自动回复：命中就直接回你配的文案（比 AI 更可控） */
      const hit = botInChat(chat, user.id) ? autoReplyHit(body) : '';
      if (hit) {
        try { deliverMessage(bot, chat.id, 'text', hit, null); } catch (e) { }
      }
      /* 用户说「人工 / 转人工」：不再让 AI 答，直接生成一张工单进后台，并告诉他人工会跟进 */
      /* 只要短句里提到「人工」就算要转人工（要人工 / 转人工 / 人工客服 / 找人工都算） */
      const wantHuman = !hit && body.replace(/[\s。！!?？，,.]/g, '').length <= 8
        && body.indexOf('人工') >= 0;
      if (wantHuman) {
        try {
          const ticket = {
            id: uid('tk'), userId: user.id, username: user.username || '',
            nickname: user.nickname || '', category: '转人工',
            title: '用户要求转人工',
            content: '用户在聊天里直接要求转人工（会话 ' + chat.id + '）',
            contact: '', status: 'pending', reply: '',
            createdAt: now(), repliedAt: '', doneAt: '', chatId: chat.id
          };
          appendSupportTicket(ticket);
          const tip = supportOffDuty()
            ? ('已经帮你转人工了。' + (sc.offTimeNote || '现在不在人工值班时间，你的问题已经记下来了，上班后会有人跟进。'))
            : '已经帮你转人工了。客服看到会尽快在这里回复你，也可以先把问题说清楚（比如什么时候、在哪个页面、点了什么），这样处理更快。';
          deliverMessage(bot, chat.id, 'text', tip, null);
        } catch (e) { }
      } else if (sc.autoReply && ac.apiKey && ac.enabled !== false) {
        /* 关键词命中过了就不再让 AI 答（后台配的文案优先） */
        if (!hit) {
        supportBotAnswer(user, body).then((reply) => {
          if (!reply) return;
          /* 人工下班了：AI 答完补一句「明天有人跟进」 */
          const out = supportOffDuty() ? (reply + '\n' + (sc.offTimeNote || '')) : reply;
          deliverMessage(bot, chat.id, 'text', out, null);
        }).catch((e) => { console.error('[客服] ' + ((e && e.message) || e)); });
        }
      }
    }
  } else if (bot && type === 'text') scheduleBotReply(bot, chat, user, body);
  /* 对方的自动回复开着、又不在线 → 用 AI 替他先回一句 */
  if (!bot && type === 'text') {
    const cfg = readAiCfg();
    if (cfg.enabled && cfg.autoReply && cfg.apiKey) {
      const peerId = chat.memberIds.find((id) => id !== user.id);
      const peer = peerId ? findUser(peerId) : null;
      if (peer && !peer.bot && !onlineUserIds().includes(peer.id)) scheduleAutoReply(peer, chat, user, body);
    }
  }
  return { message };
}


/* ---------------- 腾讯新闻（给「腾讯新闻」页和 AI 用） ----------------
   走腾讯新闻的热点榜接口，5 分钟缓存一次；手机上不直连（避免跨域），统一由这里转发。 */
let newsCache = { at: 0, list: [] };
async function fetchTencentNews(limit) {
  const n = Math.max(5, Math.min(30, Number(limit) || 20));
  if (newsCache.list.length && Date.now() - newsCache.at < 5 * 60 * 1000) return newsCache.list.slice(0, n);
  const url = 'https://r.inews.qq.com/gw/event/hot_ranking_list?ids_hash=&offset=0&page_size=' + (n + 5);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        Referer: 'https://news.qq.com/'
      },
      signal: controller.signal
    });
    const data = await res.json().catch(() => ({}));
    const raw = ((data.idlist || [])[0] || {}).newslist || [];
    const list = raw.map((it) => ({
      id: String(it.id || ''),
      title: String(it.title || '').trim(),
      summary: String(it.abstract || it.nlpAbstract || '').trim(),
      source: String(it.source || it.chlname || '腾讯新闻').trim(),
      url: String(it.url || it.surl || it.short_url || '').trim(),
      img: String((it.thumbnails && it.thumbnails[0]) || it.fimgUrl || it.bigImage || '').trim(),
      time: (function () { const t = Number(it.timestamp || 0) || 0; return t && t < 1e12 ? t * 1000 : t; })()   // 腾讯给的是秒
    })).filter((x) => x.title && !/每10分钟更新一次/.test(x.title));
    if (list.length) newsCache = { at: Date.now(), list };
    return list.slice(0, n);
  } catch (e) {
    console.error('[news] ' + (e && e.message));
    return newsCache.list.slice(0, n);
  } finally { clearTimeout(timer); }
}

/* ==================================================================== 机器人
   两个账号：ai（AI 助手）· housekeeper（管家）
   · AI 助手：聊天问答，需要最新信息时自动联网搜索
   · 管家：提醒 / 天气 / 时间 / 记账 / 代发消息 / 发朋友圈，其它问题转给 AI
   配置在 data/ai.json（密钥、模型、人设），后台 /ai.html 也能改。 */
function readAiCfg() {
  const raw = readJson(path.join(DATA_DIR, AI_FILE), {});
  return Object.assign({}, AI_DEFAULT, raw && typeof raw === 'object' ? raw : {});
}
function saveAiCfg(patch) {
  const next = Object.assign(readAiCfg(), patch || {});
  writeJson(path.join(DATA_DIR, AI_FILE), next);
  return next;
}
function findBot(name) { return db.users.find((u) => u.username === name) || null; }
function botInChat(chat, senderId) {
  if (!chat || chat.type !== 'direct') return null;
  const bot = chat.memberIds.map(findUser).find((u) => u && u.bot);
  if (!bot || bot.id === senderId) return null;
  return bot;
}
/* 建机器人账号，并让它们成为所有人的好友 */
function ensureBots() {
  const bots = [
    { username: AI_USERNAME, nickname: 'AI 助手', avatar: '/uploads/bot-ai.png', bio: '有问题随时问我，还能帮你查最新资讯～' },
    { username: 'housekeeper', nickname: 'AI助手', avatar: '/uploads/bot-housekeeper-v2.png', bio: '您的私人助理：提醒、天气、记账、代发消息，随时为您效劳' },
    { username: 'qqnews', nickname: '腾讯新闻', avatar: '/uploads/bot-news-v2.png', bio: '热点新闻、时事资讯，想听哪条跟我说' }
  ];
  let changed = false;
  bots.forEach((cfg) => {
    let bot = findBot(cfg.username);
    if (!bot) {
      /* 机器人账号也用哈希存（以前这里直接写明文 —— 谁也没法用它登录，
         但数据库里不该出现明文密码） */
      const botSalt = crypto.randomBytes(16).toString('hex');
      bot = {
        id: uid('u'), username: cfg.username, nickname: cfg.nickname,
        salt: botSalt,
        passwordHash: hashPassword(crypto.randomBytes(24).toString('hex'), botSalt),
        avatar: cfg.avatar, bio: cfg.bio,
        gender: 'male', region: '', status: 'online', tokenVersion: 0, createdAt: now(), bot: true
      };
      db.users.push(bot);
      changed = true;
    } else if (bot.bot !== true) {
      bot.bot = true;
      changed = true;
    }
    db.users.forEach((u) => {
      if (u.id === bot.id || u.bot) return;
      const f = friendshipBetween(u.id, bot.id);
      if (!f) {
        db.friendships.push({ id: uid('f'), fromId: bot.id, toId: u.id, status: 'accepted', createdAt: now() });
        changed = true;
      } else if (f.status !== 'accepted') {
        f.status = 'accepted';
        changed = true;
      }
    });
  });
  if (changed) { saveUsers(); saveFriendships(); }
  /* 每个账号和机器人的会话都固定置顶（取消不了） */
  let chatChanged = false;
  db.users.forEach((u) => {
    if (u.bot) return;
    db.users.filter((b) => b.bot && !b.service).forEach((b) => {
      const chat = directChatBetween(u.id, b.id);
      if (!chat) return;
      const set = new Set(chat.pinnedFor || []);
      if (!set.has(u.id)) { set.add(u.id); chat.pinnedFor = Array.from(set); chatChanged = true; }
      // 之前被「不显示」藏起来的，开服自动放回来
      const hidden = (chat.hiddenFor || []).filter((id) => id !== u.id);
      if (hidden.length !== (chat.hiddenFor || []).length) { chat.hiddenFor = hidden; chatChanged = true; }
    });
  });
  if (chatChanged) saveChats();
  return findBot(AI_USERNAME);
}

/* ---------------- 大模型 ---------------- */
async function llmChat(messages, cfg) {
  const cfgNow = cfg || readAiCfg();
  if (!cfgNow.apiKey) throw new Error('还没配置 AI 密钥');
  const url = String(cfgNow.baseUrl || AI_DEFAULT.baseUrl).replace(/\/+$/, '') + '/chat/completions';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60000);
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + cfgNow.apiKey },
      body: JSON.stringify({
        model: cfgNow.model || AI_DEFAULT.model,
        messages,
        temperature: Number(cfgNow.temperature) || 1.1,
        max_tokens: Number(cfgNow.maxTokens) || 800,
        stream: false
      }),
      signal: controller.signal
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data.error && data.error.message) || ('接口返回 ' + res.status));
    const text = data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
    return String(text || '').trim();
  } finally { clearTimeout(timer); }
}

/* ---------------- 联网搜索（Bing，不用密钥） ---------------- */
function stripTags(s) {
  return String(s || '').replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\s+/g, ' ').trim();
}
async function webSearch(q) {
  const url = 'https://cn.bing.com/search?q=' + encodeURIComponent(q) + '&setlang=zh-CN';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      signal: controller.signal
    });
    const html = await res.text();
    const out = [];
    const re = /<li class="b_algo"[\s\S]*?<h2[^>]*>([\s\S]*?)<\/h2>([\s\S]*?)<\/li>/g;
    let m;
    while ((m = re.exec(html)) && out.length < 5) {
      const title = stripTags(m[1]);
      const body = stripTags(m[2]);
      if (title) out.push(title + ' —— ' + body.slice(0, 220));
    }
    return out;
  } catch (e) {
    return [];
  } finally { clearTimeout(timer); }
}
function needsSearch(text) {
  return /最新|今天|今日|现在|实时|新闻|股价|价格|多少钱|汇率|比分|天气|谁是|什么时候|上映|发布|开售|政策|规定|怎么样|推荐|附近|几点|几号|是哪/.test(String(text || ''));
}

/* ---------------- 天气（wttr.in，不用密钥） ---------------- */
async function getWeather(city) {
  const c = String(city || '上海').trim() || '上海';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const res = await fetch('https://wttr.in/' + encodeURIComponent(c) + '?format=%l：%C %t，体感%f，湿度%h，风%w&lang=zh', {
      headers: { 'User-Agent': 'curl/8.0' },
      signal: controller.signal
    });
    let t = (await res.text()).trim();
    if (!t || t.length > 160) return '';
    const map = {
      Sunny: '晴', Clear: '晴', 'Partly cloudy': '多云', Cloudy: '多云', Overcast: '阴',
      Mist: '薄雾', Fog: '雾', Haze: '霾', 'Light rain': '小雨', 'Moderate rain': '中雨',
      'Heavy rain': '大雨', 'Light drizzle': '毛毛雨', 'Patchy rain nearby': '局部有雨',
      'Light snow': '小雪', Snow: '雪', 'Heavy snow': '大雪', Thunderstorm: '雷阵雨',
      'Patchy light rain': '零星小雨', 'Moderate or heavy rain shower': '阵雨'
    };
    Object.keys(map).forEach((k) => { t = t.split(k).join(map[k]); });
    return t;
  } catch (e) { return ''; } finally { clearTimeout(timer); }
}

/* ---------------- 提醒 ---------------- */
function remindersFile() { return path.join(DATA_DIR, 'reminders.json'); }
function loadReminders() { const d = readJson(remindersFile(), { items: [] }); return Array.isArray(d.items) ? d.items : []; }
function saveReminders(items) { writeJson(remindersFile(), { items }); }
function scheduleReminderTick() {
  setInterval(() => {
    const items = loadReminders();
    if (!items.length) return;
    const t = Date.now();
    let changed = false;
    items.forEach((r) => {
      if (r.done || r.at > t) return;
      r.done = true;
      changed = true;
      const bot = findBot('housekeeper');
      const user = findUser(r.userId);
      if (!bot || !user) return;
      let chat = directChatBetween(bot.id, user.id);
      if (!chat) chat = createDirectChat(bot.id, user.id);
      try { deliverMessage(bot, chat.id, 'text', '⏰ 提醒你：' + r.text, null); } catch (e) { }
    });
    if (changed) saveReminders(items.filter((r) => !r.done || !r.at || r.at > t - 7 * 24 * 3600 * 1000));
  }, 20000);
}

/* ---------------- 点餐 / 购物（贾维斯当店员） ---------------- */
function shopFile() { return path.join(DATA_DIR, 'shop.json'); }
function loadShop() {
  const d = readJson(shopFile(), {});
  const food = Array.isArray(d.food) && d.food.length ? d.food : [
    { name: '美式咖啡', price: 18 }, { name: '拿铁', price: 22 }, { name: '牛肉面', price: 26 },
    { name: '黄焖鸡米饭', price: 28 }, { name: '水果拼盘', price: 25 }
  ];
  const goods = Array.isArray(d.goods) && d.goods.length ? d.goods : [
    { name: '抽纸 3 包', price: 25 }, { name: '矿泉水一箱', price: 20 }, { name: '零食大礼包', price: 49 }
  ];
  return { food, goods };
}
function ordersFile() { return path.join(DATA_DIR, 'orders.json'); }
function loadOrders() { const d = readJson(ordersFile(), { items: [] }); return Array.isArray(d.items) ? d.items : []; }
function saveOrders(items) { writeJson(ordersFile(), { items }); }
function lastMenu(userId) { return (lastShopMenu.get(userId) || null); }
function money(n) { return '¥' + (Math.round(Number(n || 0) * 100) / 100).toFixed(2); }

/* ---------------- 机器人回话 ---------------- */
const lastDraft = new Map();          // userId -> 最后一条朋友圈草稿
const lastShopMenu = new Map();       // userId -> { kind, items }（刚给过的菜单/商品）
const aiTodo = new Map();             // userId -> 等用户「确认」的那件事（转账 / 建群 / 发消息）

function historyFor(chatId, botId, limit) {
  const msgs = loadMessages(chatId).filter((m) => !m.recalled && m.kind !== 'system').slice(-limit);
  return msgs.map((m) => ({
    role: m.senderId === botId ? 'assistant' : 'user',
    content: m.kind === 'text' ? String(m.content || '').slice(0, 1000)
      : m.kind === 'image' ? '（对方发了一张图片）'
        : m.kind === 'location' ? '（对方发了一个位置）'
          : ('（对方发了一条' + m.kind + '消息）')
  })).filter((m) => m.content);
}
/* 点餐/购物发图片：图是提前做好的（data/uploads/shop_*.png），这里只负责把 URL 发出去 */
async function sendShopImages(bot, chat, items, kind, max) {
  const n = Math.min(max || 6, items.length);
  for (let i = 0; i < n; i++) {
    const it = items[i];
    if (!it || !it.img) continue;
    try { deliverMessage(bot, chat.id, 'image', it.img, null); } catch (e) { }
    await new Promise((r) => setTimeout(r, 120));
  }
}

/* 帮用户找联系人：精确 → 前缀 → 包含（备注/昵称/用户名都行） */
function findContacts(user, name) {
  const kw = String(name || '').trim().toLowerCase();
  if (!kw) return [];
  const all = db.users.filter((u) => u.id !== user.id);
  let hits = all.filter((u) => (u.nickname || '').toLowerCase() === kw || (u.username || '').toLowerCase() === kw);
  if (!hits.length) hits = all.filter((u) => (u.nickname || '').toLowerCase().startsWith(kw) || (u.username || '').toLowerCase().startsWith(kw));
  if (!hits.length) hits = all.filter((u) => (u.nickname || '').toLowerCase().includes(kw) || (u.username || '').toLowerCase().includes(kw));
  return hits;
}
function openChatWith(user, target) {
  let chat = directChatBetween(user.id, target.id);
  if (!chat) chat = createDirectChat(user.id, target.id);
  const f = friendshipBetween(user.id, target.id);
  if (!f) db.friendships.push({ id: uid('f'), fromId: user.id, toId: target.id, status: 'accepted', createdAt: now() });
  else if (f.status !== 'accepted') f.status = 'accepted';
  saveFriendships();
  return chat;
}

/* 「腾讯新闻」这个号的回答：报热点 / 讲第N条 / 其他问题用新闻+联网作答 */
async function newsBotAnswer(bot, chat, user, text) {
  const t = String(text || '').trim();
  const list = await fetchTencentNews(10);
  if (!list.length) return '这会儿取不到腾讯新闻，稍后再问我一次。';
  const map = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10 };
  const m = t.match(/讲讲?第\s*(\d{1,2}|[一二三四五六七八九十])\s*条/);
  if (m) {
    const idx = (map[m[1]] || Number(m[1]) || 1) - 1;
    const it = list[idx];
    if (!it) return '没找到第 ' + (idx + 1) + ' 条，先跟我说「新闻」看看今天的列表。';
    const cfg = readAiCfg();
    const hits = await webSearch(it.title);
    const msgs = [{ role: 'system', content: '你是腾讯新闻的编辑，用三句话讲清楚这条新闻：发生了什么、为什么重要，口语一点，不要 Markdown。' },
      { role: 'user', content: it.title + (it.summary ? ('\n摘要：' + it.summary) : '') + (hits.length ? ('\n联网补充：' + hits.slice(0, 3).join('\n')) : '') }];
    const out = await llmChat(msgs, cfg);
    return (out || it.title) + '\n（来源：' + (it.source || '腾讯新闻') + '）';
  }
  if (/^(你好|您好|在吗|hi|hello|嗨|新闻|今天的?新闻|热点|头条)/i.test(t)) {
    const d = new Date();
    const pad = (n) => ('0' + n).slice(-2);
    return '腾讯新闻热点（' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + '）：\n' +
      list.slice(0, 6).map((x, i) => (i + 1) + '. ' + x.title).join('\n') +
      '\n想看哪条细节？说「讲讲第 2 条」就行。';
  }
  /* 其它内容：只从新闻里找，不做别的回答 */
  const kw = t.replace(/[？?。，,！!、\s]/g, '');
  const hit = kw ? list.find((x) => (x.title + (x.summary || '')).indexOf(kw.slice(0, 6)) >= 0) : null;
  if (hit) {
    return '看到一条相关的：\n· ' + hit.title + '（' + (hit.source || '腾讯新闻') + '）\n想看细节就说「讲讲第 ' +
      (list.indexOf(hit) + 1) + ' 条」。';
  }
  return '我只负责报新闻～\n发「新闻」看今天的热点，或者说「讲讲第 2 条」让我讲细一点。';
}

/* 管家的固定命令：不走大模型，快又稳 */
async function housekeeperCommand(user, text, chat, bot) {
  const t = String(text || '').trim();
  if (/^(几点|现在几点|时间|日期|今天几号)/.test(t)) {
    const d = new Date();
    const pad = (n) => ('0' + n).slice(-2);
    return '现在是 ' + d.getFullYear() + ' 年 ' + (d.getMonth() + 1) + ' 月 ' + d.getDate() + ' 日 ' +
      pad(d.getHours()) + ':' + pad(d.getMinutes()) + '（' + ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][d.getDay()] + '）';
  }
  let m = t.match(/^天气\s*([\u4e00-\u9fa5]{2,10})?$/) || t.match(/^([\u4e00-\u9fa5]{2,10})的?天气$/);
  if (m) {
    const city = m[1] || user.region || '上海';
    const w = await getWeather(city);
    return w ? '🌤 ' + w : ('没查到 ' + city + ' 的天气，换个城市名试试？');
  }
  /* 提醒：支持「提醒我 8:30 开会」和「晚上 9 点提醒我吃药」两种说法 */
  m = t.match(/(?:提醒我?|叫我|记得)\s*(明天|今天|今晚)?\s*(\d{1,2})\s*[点:：]\s*(\d{1,2})?\s*分?\s*(.*)/) ||
      t.match(/(早上|上午|中午|下午|傍晚|晚上|今晚|明天|今天)?\s*(\d{1,2})\s*[点:：]\s*(\d{1,2})?\s*分?\s*(?:提醒我?|叫我|记得)\s*(.*)/);
  if (m) {
    let dayWord = '', period = '', hh = 0, mm = 0, what = '';
    if (/^(明天|今天|今晚)?$/.test(m[1] || '')) {          // 第一种写法
      dayWord = m[1] || '';
      hh = Number(m[2]); mm = Number(m[3] || 0); what = String(m[4] || '').trim();
    } else {                                                // 第二种写法（时间在前）
      period = m[1] || ''; dayWord = /明/.test(period) ? '明天' : (/今/.test(period) ? '今天' : '');
      hh = Number(m[2]); mm = Number(m[3] || 0); what = String(m[4] || '').trim();
      if (/下午|傍晚|晚上/.test(period) && hh < 12) hh += 12;
      if (/中午/.test(period) && hh < 11) hh += 12;
    }
    what = what.replace(/^[，,：:。\s]+/, '') || '该做事啦';
    const at = new Date();
    at.setSeconds(0, 0);
    at.setHours(Math.min(23, Math.max(0, hh)), Math.min(59, Math.max(0, mm)));
    if (dayWord === '明天' || at.getTime() <= Date.now()) at.setDate(at.getDate() + 1);
    const items = loadReminders();
    items.push({ id: uid('rm'), userId: user.id, text: what, at: at.getTime(), done: false, createdAt: now() });
    saveReminders(items);
    const isToday = at.toDateString() === new Date().toDateString();
    return '好，' + (isToday ? '今天' : '明天') + ' ' + ('0' + at.getHours()).slice(-2) + ':' + ('0' + at.getMinutes()).slice(-2) +
      ' 提醒你「' + what + '」。';
  }
  if (/^(我的)?提醒(列表|事项)?$/.test(t)) {
    const items = loadReminders().filter((r) => r.userId === user.id && !r.done && r.at > Date.now());
    if (!items.length) return '现在没有待办提醒。跟我说「提醒我 8:30 开会」就行。';
    return '你有 ' + items.length + ' 个提醒：\n' + items.map((r) => '· ' + new Date(r.at).toLocaleString('zh-CN', { hour12: false }) + ' ' + r.text).join('\n');
  }
  m = t.match(/^记账\s*([^\s\d]{1,14})\s*(\d+(?:\.\d{1,2})?)/);
  if (m) {
    const p = path.join(DATA_DIR, 'ledger.json');
    const led = readJson(p, { items: [] });
    if (!Array.isArray(led.items)) led.items = [];
    led.items.push({ id: uid('gd'), userId: user.id, what: m[1], amount: Number(m[2]), at: now() });
    writeJson(p, led);
    const month = led.items.filter((x) => x.userId === user.id && String(x.at || '').slice(0, 7) === now().slice(0, 7));
    const sum = month.reduce((s, x) => s + Number(x.amount || 0), 0);
    return '记好了：' + m[1] + ' ' + m[2] + ' 元。这个月一共 ' + sum.toFixed(2) + ' 元。';
  }
  if (/^(账本|这个月花了多少|花了多少钱)/.test(t)) {
    const led = readJson(path.join(DATA_DIR, 'ledger.json'), { items: [] });
    const items = Array.isArray(led.items) ? led.items : [];
    const month = items.filter((x) => x.userId === user.id && String(x.at || '').slice(0, 7) === now().slice(0, 7));
    if (!month.length) return '这个月还没记过账。跟我说「记账 午饭 25」就行。';
    const sum = month.reduce((s, x) => s + Number(x.amount || 0), 0);
    return '这个月记了 ' + month.length + ' 笔，共 ' + sum.toFixed(2) + ' 元。\n' +
      month.slice(-10).map((x) => '· ' + x.what + ' ' + x.amount + ' 元').join('\n');
  }
  /* ---------- 点餐 / 购物 ---------- */
  /* 淘宝那种卡片：App 收到就**直接跳转**（装了淘宝跳淘宝 App，没装用 App 内网页打开） */
  const sendShopCard = (title, sub, url, scheme) => {
    try {
      deliverMessage(bot, chat.id, 'link', JSON.stringify({ title: title, sub: sub, url: url, scheme: scheme || '' }), null);
    } catch (e) { }
  };
  m = t.match(/^(?:帮我)?(点餐|点外卖|点个外卖|外卖|我想吃点|我想吃|饿了|点单)$/) || t.match(/^帮我点(?:个|份)?(.{1,10})$/);
  if (m) {
    const shop = loadShop();
    const want = (m[1] || '').trim();
    let items = shop.food, kind = 'food';
    if (want && !/^(餐|外卖|单|个外卖)$/.test(want)) {
      const hit = shop.food.filter((x) => x.name.indexOf(want) >= 0);
      if (hit.length) items = hit;
    }
    lastShopMenu.set(user.id, { kind, items });
    const food = (want && !/^(餐|外卖|单|个外卖)$/.test(want)) ? want : items[0].name;
    const kw = encodeURIComponent(food);
    sendShopCard('美团外卖 · 点外卖', '附近商家 · 30 分钟送到（搜「' + food + '」）',
      'https://h5.waimai.meituan.com/', 'imeituan://www.meituan.com/waimai');
    return '点外卖走美团外卖，我已经给你跳过去了 👆\n想吃「' + food + '」在里边搜一下就行；' +
      '\n想用零钱在我这儿下单也行，说「点第 1 个」。余额 ' + money(user.balance);
  }
  m = t.match(/^(?:帮我)?(购物|买东西|买点东西|商城|逛商城|日用品)(?:\s+(.{1,12}))?$/) ||
      t.match(/^(?:帮我)?(?:在淘宝)?买\s*(.{1,12})$/) ||
      t.match(/^我想(?:买|要)\s*(.{1,12})$/);
  if (m && !/^第?\s*\d/.test(String(m[2] || m[1] || '').trim())) {
    const shop = loadShop();
    const want = String(m[2] || m[1] || '').trim();
    lastShopMenu.set(user.id, { kind: 'goods', items: shop.goods });
    const goods = (want && !/^(东西|点东西|商城|日用品)$/.test(want)) ? want : shop.goods[0].name;
    const kw2 = encodeURIComponent(goods);
    sendShopCard('淘宝 · 买「' + goods + '」', '同款比价 · 直接下单',
      'https://s.m.taobao.com/h5?q=' + kw2, 'taobao://s.taobao.com/search?q=' + kw2);
    return '买东西走淘宝，我已经给你跳过去了 👆\n在里边搜「' + goods + '」就能买；' +
      '\n想用零钱在我这儿下单也行，说「买第 1 个」。余额 ' + money(user.balance);
  }
  /* 点外卖的入口 / 逛淘宝：都给出去 */
  if (/^(美团|美团外卖|附近有什么吃的|点外卖的入口|饿了么)$/.test(t)) {
    sendShopCard('美团外卖', '附近商家 · 30 分钟送到', 'https://h5.waimai.meituan.com/', 'imeituan://www.meituan.com/waimai');
    return '这就给你打开美团外卖 👆 想吃什么直接告诉我，我帮你搜。';
  }
  if (/^(淘宝闪购|闪购)$/.test(t)) {
    sendShopCard('美团外卖 · 点外卖', '点外卖用美团，30 分钟送到', 'https://h5.waimai.meituan.com/', 'imeituan://www.meituan.com/waimai');
    return '点外卖用美团外卖最顺，我给你跳过去了 👆';
  }
  if (/^(淘宝|去淘宝|逛淘宝|淘宝首页)$/.test(t)) {
    sendShopCard('淘宝', '想买什么直接搜', 'https://main.m.taobao.com/', 'taobao://');
    return '这就给你打开淘宝 👆 要买什么直接说「买 耳机」，我帮你搜。';
  }
  m = t.match(/^(?:帮我)?(?:点|要|买|来|下单)\s*第?\s*(\d{1,2})\s*(?:个|份|号|杯|碗)?$/);
  if (m) {
    const menu = lastMenu(user.id);
    if (!menu) return '先跟我说「点餐」或者「购物」，我把清单给你。';
    const it = menu.items[Number(m[1]) - 1];
    if (!it) return '清单里只有 ' + menu.items.length + ' 项，你再说一次序号？';
    const bal = Number(user.balance) || 0;
    if (bal < it.price) return '余额不够啦（' + money(bal) + ' / 需要 ' + money(it.price) + '）。我 → 服务 → 充值余额 充一点就行。';
    user.balance = Math.round((bal - it.price) * 100) / 100;
    saveUsers();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    const order = { id: uid('od'), userId: user.id, kind: menu.kind, name: it.name, price: it.price, at: now(), status: '已下单' };
    const orders = loadOrders();
    orders.unshift(order);
    saveOrders(orders.slice(0, 200));
    /* 顺手设个提醒：外卖 30 分钟、商品明天上午 */
    const at = new Date(Date.now() + (menu.kind === 'food' ? 30 * 60 * 1000 : 12 * 3600 * 1000));
    const rms = loadReminders();
    rms.push({ id: uid('rm'), userId: user.id, text: (menu.kind === 'food' ? '外卖应该到了：' : '记得收快递：') + it.name, at: at.getTime(), done: false, createdAt: now() });
    saveReminders(rms);
    const plat = 'https://s.m.taobao.com/h5?q=';
    return '下单成功 ✅\n· ' + it.name + '　' + money(it.price) + '\n· 已用零钱支付，余额 ' + money(user.balance) +
      '\n' + (menu.kind === 'food' ? '大概 30 分钟送到，我到点提醒你。' : '明天上午送到，我到点提醒你。') +
      '\n' + (menu.kind === 'food' ? '想再点别的，淘宝闪购：https://shangou.m.taobao.com/' : '想再买别的，淘宝：https://main.m.taobao.com/') +
      '\n同款比价：' + plat + encodeURIComponent(it.name);
  }
  if (/^(我的)?(订单|单子)$/.test(t)) {
    const mine = loadOrders().filter((x) => x.userId === user.id).slice(0, 5);
    if (!mine.length) return '你还没在我这儿下过单。说「点餐」或者「购物」试试。';
    return '你最近的订单：\n' + mine.map((x) => '· ' + x.name + '　' + money(x.price) + '　' + x.status).join('\n');
  }
  if (/^(AI)?余额(还剩多少)?$|^还剩多少(AI)?余额$|^api余额$/.test(t.replace(/\s/g, '')) && /AI|api/i.test(t)) {
    try {
      const cfgB = readAiCfg();
      const r = await fetch(String(cfgB.baseUrl || AI_DEFAULT.baseUrl).replace(/\/+$/, '') + '/user/balance', {
        headers: { Authorization: 'Bearer ' + cfgB.apiKey }, signal: AbortSignal.timeout(10000)
      });
      const d = await r.json().catch(() => ({}));
      const info = (d.balance_infos || [])[0] || {};
      return 'AI 账户余额：' + (info.currency === 'CNY' ? '¥' : '') + (info.total_balance || '0') + '（可用：' + (d.is_available ? '是' : '否，去 platform.deepseek.com 充一点') + '）';
    } catch (e) { return '查余额失败：' + (e && e.message); }
  }
  if (/^(余额|零钱|我还有多少钱|查余额)$/.test(t)) {
    return '你的零钱余额是 ' + money(user.balance) + '。要充值得去「我 → 服务 → 充值余额」。';
  }
  /* 用户说「和X聊天 / 找X」这种：不替他开聊天，只给个提示 */
  m = t.match(/^(?:帮我|替我)?(?:和|跟|找|联系|打开)\s*([^\s，,：:]{1,14})\s*(?:聊天|聊两句|聊一下|说话|的聊天)$/);
  if (m) return '这个我帮不上——你直接在通讯录里点他就能聊。要我替你带句话就说「给' + m[1] + '发消息 内容」。';

  /* 代发消息：给张三发消息 你好（名字可以只写一部分） */
  m = t.match(/^(?:帮我|替我)?给\s*([^\s，,：:]{1,14})\s*(?:发消息|发个消息|发条消息|说|留言)\s*[：:，,]?\s*([\s\S]+)$/);
  if (m) {
    const hits = findContacts(user, m[1]);
    if (!hits.length) return '没找到「' + m[1] + '」这个人，名字再准一点？';
    if (hits.length > 2) {
      return '有几个同名的，你要发给哪一个？\n' + hits.slice(0, 5).map((u, i) => (i + 1) + '. ' + (u.nickname || u.username)).join('\n');
    }
    const target = hits[0];
    const chat = openChatWith(user, target);
    deliverMessage(user, chat.id, 'text', m[2].trim(), null);
    return '已经帮你发给「' + (target.nickname || target.username) + '」：' + m[2].trim();
  }
  /* ---------- 朋友圈：写草稿 / 直接发 / 带刚才发的图 ---------- */
  function recentImage() {
    if (!chat) return '';
    const msgs = loadMessages(chat.id).filter((x) => !x.recalled);
    for (let i = msgs.length - 1; i >= 0 && i >= msgs.length - 6; i--) {
      if (msgs[i].kind === 'image') return String(msgs[i].content || '');
    }
    return '';
  }
  async function draftMoment(topic) {
    const cfg = readAiCfg();
    const ask = '帮用户写一条微信朋友圈文案' + (topic ? ('，主题是：' + topic) : '（就写今天的生活小感想）') +
      '。要求：口语化、真实、不超过 40 个字、可以带 1-2 个 emoji、不要引号也不要解释，只给文案本身。';
    let text = '';
    try { text = await llmChat([{ role: 'system', content: (cfg.housekeeperPrompt || AI_DEFAULT.housekeeperPrompt) }, { role: 'user', content: ask }], cfg); } catch (e) { }
    text = String(text || '').replace(/^["“”']|["“”']$/g, '').trim();
    return text || (topic || '今天也要好好生活呀 ☀️');
  }
  function postMoment(content, images) {
    const moment = { id: uid('mo'), authorId: user.id, content: String(content || '').slice(0, 1000), images: images || [], createdAt: now(), likes: [], comments: [] };
    db.moments.unshift(moment);
    saveMoments();
    broadcastMoment(user.id, { type: 'moment', action: 'new', authorId: user.id, moment: visibleMoment(moment, user.id) });
    return moment;
  }
  /* 写朋友圈（只要草稿，不发） */
  m = t.match(/^(?:帮我)?写(?:条|个)?(?:朋友圈|动态)(?:文案)?\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const draft = await draftMoment(m[1].trim());
    lastDraft.set(user.id, draft);
    return '草稿给你：\n' + draft + '\n\n满意就说「发吧」，不满意就说「换一条」，也可以自己改。';
  }
  /* 发朋友圈：带内容就发内容，只写「帮我发朋友圈」就让它自己写一条 */
  m = t.match(/^(?:帮我|替我|你)?发(?:条|个)?(?:朋友圈|动态)\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const body = m[1].trim();
    const img = recentImage();
    const images = img ? [img] : [];
    let content = body;
    if (!content || /^(吧|呗|一条|一条吧|随便|你写|你来写|自己写)?$/.test(content) || /^主题[：:]/.test(content) || content.length <= 2) {
      content = await draftMoment(content.replace(/^主题[：:]/, '').trim());
    }
    postMoment(content, images);
    return '朋友圈已经发出去啦' + (images.length ? '（带上了你刚发的那张图）' : '') + '：「' + content + '」\n不满意就说「重发一条 主题：…」，我把刚才那条删了重发。';
  }
  if (/^(发吧|直接发|发出去|发这个|就发这个|可以发|发$|发了|发一条|发吧发吧)/.test(t)) {
    const draft = lastDraft.get(user.id);
    if (!draft) return '你想发什么内容？先说「写条朋友圈 主题」让我写，或者直接说「发朋友圈 内容」。';
    postMoment(draft, []);
    lastDraft.delete(user.id);
    return '好嘞，已经帮你发到朋友圈了：「' + draft + '」';
  }
  if (/^(换一条|换一个|不满意|重写|再来一条)/.test(t)) {
    const draft = await draftMoment('');
    lastDraft.set(user.id, draft);
    return '换一条：\n' + draft + '\n满意就说「发吧」。';
  }
  m = t.match(/^(?:重发|重新发)(?:一条)?\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const mine = db.moments.filter((x) => x.authorId === user.id).sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
    if (mine) { db.moments = db.moments.filter((x) => x.id !== mine.id); saveMoments(); }
    const content = await draftMoment(m[1].replace(/^主题[：:]/, '').trim());
    postMoment(content, (mine && mine.images) || []);
    return '好，重发了一条：「' + content + '」';
  }
  /* 改签名 */
  m = t.match(/^(?:帮我)?(?:改|写)(?:个)?签名\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const cfg2 = readAiCfg();
    let bio = m[1].trim();
    if (!bio) {
      try { bio = await llmChat([{ role: 'system', content: '你帮用户想一句微信个性签名：中文、不超过 20 字、有点个性、不要引号，只给签名本身。' }], cfg2); } catch (e) { }
    }
    bio = String(bio || '').replace(/^["“”']|["“”']$/g, '').trim().slice(0, 40);
    if (!bio) return '你想写什么样的签名？比如「改签名 岁月静好」。';
    user.bio = bio;
    saveUsers();
    return '签名已改成：' + bio;
  }
  if (/^(开启|打开).*(自动回复)/.test(t)) {
    saveAiCfg({ autoReply: true });
    return '好的，自动回复已开启：你不在线的时候，收到消息我先替你回一句。想关掉就说「关闭自动回复」。';
  }
  if (/^(关闭|取消).*(自动回复)/.test(t)) {
    saveAiCfg({ autoReply: false });
    return '自动回复已经关掉了。';
  }

  /* ============================================================
     替用户在 App 里干活（微信「小微」那种）。下面这些命令都不走大模型，
     说一句就直接把事办了 —— 建群 / 加好友 / 改昵称 / 会话管理 /
     查聊天记录 / 朋友圈点赞评论 / 转账 / 账单 / 谁在线 / 清空记录
     ============================================================ */

  /* ① 建群：建个群 张三 李四 */
  m = t.match(/^(?:帮我|替我)?(?:建|开|拉|创)(?:个|一个)?(?:群|群聊|讨论组)\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const names = m[1].trim().split(/[\s、,，+和跟与]+/).map((x) => x.trim()).filter(Boolean);
    if (!names.length) return '要拉谁进群？这样说：「建个群 张三 李四」。';
    const picked = [];
    const missing = [];
    names.forEach((n) => {
      const hits = findContacts(user, n).filter((u) => !u.bot);
      if (hits.length) { if (!picked.some((x) => x.id === hits[0].id)) picked.push(hits[0]); }
      else missing.push(n);
    });
    if (!picked.length) return '没找到这些人：' + names.join('、') + '。名字写准一点再试一次。';
    const gname = ((user.nickname || user.username || '我') + '、' +
      picked.map((u) => u.nickname || u.username).join('、')).slice(0, 30);
    const gchat = {
      id: uid('c'), type: 'group', name: gname, avatar: '',
      memberIds: [user.id].concat(picked.map((u) => u.id)),
      ownerId: user.id, seq: 0, createdAt: now()
    };
    db.chats.push(gchat);
    try { buildGroupAvatar(gchat); } catch (e) { }
    saveChats();
    gchat.memberIds.forEach((id) => {
      if (id !== user.id) sendTo(id, { type: 'chat', action: 'created', chat: chatSummary(gchat, id) });
    });
    return '群建好了：「' + gchat.name + '」（' + gchat.memberIds.length + ' 人）' +
      (missing.length ? '\n没找到：' + missing.join('、') : '') + '\n在「微信」第一页就能看到这个群。';
  }

  /* ② 加好友：加好友 wzy245441549 */
  m = t.match(/^(?:帮我|替我)?(?:加|添加|新增|加上)\s*(?:好友|朋友|联系人|微信号)?\s*[：:，,]?\s*([A-Za-z0-9_\-.\u4e00-\u9fa5]{2,24})$/);
  if (m) {
    const kw = m[1].trim();
    const target = findUserByName(kw) || findContacts(user, kw).filter((u) => !u.bot)[0];
    if (!target) return '没找到「' + kw + '」这个人。把微信号发我（比如「加好友 wzy245441549」）。';
    if (target.id === user.id) return '这是你自己呀～';
    const who = target.nickname || target.username;
    if (friendIds(user.id).includes(target.id)) return '你和「' + who + '」已经是好友了，直接聊就行。';
    const f = friendshipBetween(user.id, target.id);
    if (f) {
      if (f.status === 'accepted') return '你们已经是好友了。';
      if (f.fromId === user.id) return '好友申请已经发过了，等「' + who + '」在「新的朋友」里通过。';
      f.status = 'accepted';
      saveFriendships();
      openChatForFriendship(f.fromId, f.toId);
      sendTo(target.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      return '「' + who + '」之前加过你，现在你们互相是好友了，可以聊天了。';
    }
    db.friendships.push({ id: uid('f'), fromId: user.id, toId: target.id, status: 'pending', createdAt: now(),
      note: str(body.message, 60) });
    saveFriendships();
    sendTo(target.id, { type: 'friend', action: 'request', user: publicUser(user) });
    return '好友申请已经发给「' + who + '」了，等对方通过。';
  }

  /* ③ 改昵称：改昵称 小明 */
  m = t.match(/^(?:帮我)?(?:改|换)(?:个)?(?:昵称|名字)\s*[：:，,]?\s*(\S{1,20})$/);
  if (m && !/签名/.test(t)) {
    const nn = m[1].trim().slice(0, 20);
    user.nickname = nn;
    saveUsers();
    return '昵称已经改成「' + nn + '」了。';
  }

  /* ④ 会话管理：置顶 / 免打扰 / 删掉 / 清空记录 */
  const chatActs = {
    '置顶': 'pin', '取消置顶': 'unpin',
    '免打扰': 'mute', '取消免打扰': 'unmute',
    '静音': 'mute', '取消静音': 'unmute',
    '删掉': 'del', '删除': 'del', '隐藏': 'del',
    '清空': 'clear', '清空记录': 'clear', '清空聊天记录': 'clear'
  };
  m = t.match(/^(?:帮我)?(?:把)?\s*(?:和|跟)?\s*([^\s，,：:的]{1,14})\s*(?:的)?\s*(?:聊天记录|聊天|会话|对话)?\s*(置顶|取消置顶|免打扰|取消免打扰|静音|取消静音|删掉|删除|隐藏|清空|清空记录|清空聊天记录)$/)
    || t.match(/^(?:帮我)?(置顶|取消置顶|免打扰|取消免打扰|静音|取消静音|删掉|删除|隐藏|清空|清空记录|清空聊天记录)\s*(?:和|跟)?\s*([^\s，,：:的]{1,14})\s*(?:的)?\s*(?:聊天记录|聊天|会话|对话)?$/);
  if (m && Object.prototype.hasOwnProperty.call(chatActs, m[1] === undefined ? '' : m[1])) {
    /* 两种语序：名字在前 or 动作在前 */
    const firstIsAct = Object.prototype.hasOwnProperty.call(chatActs, m[1]);
    const name = String((firstIsAct ? m[2] : m[1]) || '').trim();
    const act = chatActs[firstIsAct ? m[1] : m[2]];
    const hits = findContacts(user, name).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + name + '」这个人。';
    const target = hits[0];
    const who = target.nickname || target.username;
    const chat = directChatBetween(user.id, target.id);
    if (!chat) return '你和「' + who + '」还没有会话。';
    if (act === 'pin' || act === 'unpin') {
      const set = new Set(chat.pinnedFor || []);
      if (act === 'pin') set.add(user.id); else set.delete(user.id);
      chat.pinnedFor = Array.from(set);
      saveChats();
      return act === 'pin' ? '已经把「' + who + '」置顶了。' : '已经取消置顶了。';
    }
    if (act === 'mute' || act === 'unmute') {
      const set = new Set(chat.mutedFor || []);
      if (act === 'mute') set.add(user.id); else set.delete(user.id);
      chat.mutedFor = Array.from(set);
      saveChats();
      sendTo(user.id, { type: 'chat', action: 'updated', chat: chatSummary(chat, user.id) });
      return act === 'mute' ? '已经给「' + who + '」设成消息免打扰了。' : '已经取消免打扰了。';
    }
    if (act === 'del') {
      chat.hiddenFor = Array.from(new Set((chat.hiddenFor || []).concat([user.id])));
      saveChats();
      sendTo(user.id, { type: 'chat', action: 'removed', chatId: chat.id });
      return '已经把和「' + who + '」的会话从列表里去掉（对方不受影响，再来消息会重新出现）。';
    }
    const msgs = loadMessages(chat.id);
    const lastSeq = msgs.length ? msgs[msgs.length - 1].seq : 0;
    if (!db.cleared[user.id]) db.cleared[user.id] = {};
    db.cleared[user.id][chat.id] = lastSeq;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    return '和「' + who + '」的聊天记录在你这台设备上清空了（对方那边还在）。';
  }

  /* ⑤ 查聊天记录：我和张三聊了什么 / 找张三说过 合同 */
  m = t.match(/^(?:找|搜|查)\s*([^\s，,：:的]{1,14})\s*(?:说过|说的|发过|发的)\s*[：:，,]?\s*([\s\S]{1,20})$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + m[1] + '」这个人。';
    const target = hits[0];
    const who = target.nickname || target.username;
    const chat = directChatBetween(user.id, target.id);
    if (!chat) return '你和「' + who + '」还没有聊天记录。';
    const kw = m[2].trim();
    const found = loadMessages(chat.id).filter((x) => !x.recalled && String(x.content || '').indexOf(kw) >= 0).slice(-5);
    if (!found.length) return '你和「' + who + '」的聊天里没找到「' + kw + '」。';
    return '在「' + who + '」那儿找到 ' + found.length + ' 条：\n' +
      found.map((x) => '· ' + (x.senderId === user.id ? '我：' : (who + '：')) + String(x.content || '').slice(0, 40)).join('\n');
  }
  m = t.match(/^(?:我和|查|看看|找)\s*([^\s，,：:的]{1,14})\s*(?:的)?(?:聊天记录|聊天|聊了什么|聊了啥|记录)$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + m[1] + '」这个人。';
    const target = hits[0];
    const who = target.nickname || target.username;
    const chat = directChatBetween(user.id, target.id);
    if (!chat) return '你和「' + who + '」还没有聊过。';
    const msgs = loadMessages(chat.id).filter((x) => !x.recalled).slice(-8);
    if (!msgs.length) return '你和「' + who + '」还没有聊天记录。';
    return '你和「' + who + '」最近 ' + msgs.length + ' 条：\n' +
      msgs.map((x) => '· ' + (x.senderId === user.id ? '我：' : (who + '：')) + (x.kind === 'text' ? String(x.content || '').slice(0, 40) : '[' + x.kind + ']')).join('\n');
  }

  /* ⑥ 朋友圈：点赞 / 评论 */
  m = t.match(/^(?:帮我)?(?:给)?\s*([^\s，,：:的]{1,14})\s*(?:的)?(?:最新)?(?:朋友圈|动态)\s*(?:点个赞|点赞)$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    const target = hits[0];
    if (!target) return '没找到「' + m[1] + '」这个人。';
    const who = target.nickname || target.username;
    const mm = db.moments.filter((x) => x.authorId === target.id)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
    if (!mm) return '「' + who + '」最近没发朋友圈。';
    if (!momentAudience(mm.authorId).includes(user.id)) return '看不到「' + who + '」的朋友圈（对方设了权限）。';
    if (!mm.likes) mm.likes = [];
    if (!mm.likes.some((l) => l.userId === user.id)) mm.likes.push({ userId: user.id, at: now() });
    saveMoments();
    broadcastMoment(mm.authorId, { type: 'moment', action: 'like', momentId: mm.id, authorId: mm.authorId, userId: user.id, liked: true });
    return '已经给「' + who + '」的朋友圈点了个赞 👍';
  }
  m = t.match(/^(?:帮我)?(?:给)?\s*([^\s，,：:的]{1,14})\s*(?:的)?(?:最新)?(?:朋友圈|动态)\s*评论\s*[：:，,]?\s*([\s\S]{1,120})$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    const target = hits[0];
    if (!target) return '没找到「' + m[1] + '」这个人。';
    const who = target.nickname || target.username;
    const mm = db.moments.filter((x) => x.authorId === target.id)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
    if (!mm) return '「' + who + '」最近没发朋友圈。';
    if (!momentAudience(mm.authorId).includes(user.id)) return '看不到「' + who + '」的朋友圈（对方设了权限）。';
    if (!mm.comments) mm.comments = [];
    mm.comments.push({ id: uid('cm'), userId: user.id, content: m[2].trim(), replyTo: null, at: now() });
    saveMoments();
    const views = visibleMoment(mm, user.id);
    momentAudience(mm.authorId).forEach((id) => {
      sendTo(id, {
        type: 'moment', action: 'comment', momentId: mm.id, authorId: mm.authorId,
        comment: views.comments[views.comments.length - 1], commentCount: views.comments.length
      });
    });
    return '已经在「' + who + '」的朋友圈下面评论了：' + m[2].trim();
  }

  /* ⑦ 转账：先报一句「给张三转 50」，我说确认才真的转 */
  if (/^(算了|取消|不转了|不用了)$/.test(t) && aiTodo.get(user.id)) {
    aiTodo.delete(user.id);
    return '好，那件事取消了。';
  }
  m = t.match(/^(?:帮我|替我)?(?:给)?\s*([^\s，,：:]{1,14}?)\s*(?:转账|转钱|转|打钱)\s*([0-9]+(?:\.[0-9]{1,2})?)\s*(?:元|块钱|块|元整)?$/)
    || t.match(/^(?:帮我|替我)?(?:转账|转钱|转)\s*([0-9]+(?:\.[0-9]{1,2})?)\s*(?:元|块钱|块)?\s*(?:给)?\s*([^\s，,：:]{1,14})$/);
  if (m) {
    let name = '', amt = 0;
    if (/^[0-9]/.test(m[1])) { amt = Number(m[1]); name = String(m[2] || '').trim(); }
    else { name = String(m[1] || '').trim(); amt = Number(m[2]); }
    if (!(amt > 0)) return '转账金额要大于 0，比如「给张三转 50」。';
    if (amt > 200000) return '单笔最多 20 万。';
    const limit = user.transferLimit === undefined ? 20000 : (Number(user.transferLimit) || 0);
    if (limit > 0 && amt > limit) return '超过你的单笔限额 ' + money(limit) + ' 了。';
    const hits = findContacts(user, name).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + name + '」这个人。';
    const who = hits[0].nickname || hits[0].username;
    aiTodo.set(user.id, { kind: 'transfer', toId: hits[0].id, name: who, amount: amt });
    return '确认给「' + who + '」转 ' + money(amt) + ' 吗？\n确认就回「确认转账' +
      (hasPayPassword(user) ? ' 支付密码' : '') + '」，不想转就说「算了」。';
  }
  m = t.match(/^(?:确认转账|确认付款|确认付款码|转吧|确认)\s*([0-9]{4,8})?$/);
  if (m) {
    const todo = aiTodo.get(user.id);
    if (!todo || todo.kind !== 'transfer') {
      return '现在没有等你确认的转账哦。想转就说「给张三转 50」，我先跟你确认一遍再转。';
    }
    const pwd = String(m[1] || '').trim();
    if (hasPayPassword(user) && !pwd) return '要支付密码才能转，回我「确认转账 你的支付密码」。';
    if (hasPayPassword(user) && !verifyPayPassword(user, pwd)) return '支付密码不对，再试一次。';
    const target = findUser(todo.toId);
    if (!target) { aiTodo.delete(user.id); return '这个人找不到了，重新说一次吧。'; }
    const bal = Number(user.balance) || 0;
    if (bal < todo.amount) {
      aiTodo.delete(user.id);
      return '余额不够（' + money(bal) + ' / 要 ' + money(todo.amount) + '）。去「我 → 服务 → 充值余额」充一点。';
    }
    user.balance = Math.round((bal - todo.amount) * 100) / 100;
    saveUsers();
    const c = openChatWith(user, target);
    const tr = {
      id: uid('tr'), chatId: c.id, fromId: user.id, toId: target.id, amount: todo.amount,
      note: '', method: 'balance', status: 'pending', createdAt: now(),
      expiresAt: Date.now() + TRANSFER_TTL_MS, receivedAt: '', refundedAt: '', messageId: ''
    };
    db.transfers.unshift(tr);
    if (db.transfers.length > 800) db.transfers.length = 800;
    const sent = deliverMessage(user, c.id, 'transfer', transferSnapshot(tr), null);
    if (sent && sent.error) {
      db.transfers = db.transfers.filter((x) => x.id !== tr.id);
      user.balance = Math.round(bal * 100) / 100;
      saveUsers();
      aiTodo.delete(user.id);
      return '转账没发出去：' + sent.error;
    }
    tr.messageId = sent.message.id;
    syncTransferMessage(tr);
    saveTransfers();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    aiTodo.delete(user.id);
    return '已经转 ' + money(todo.amount) + ' 给「' + (target.nickname || target.username) + '」了' +
      '，对方点「收钱」才进他余额。你现在余额 ' + money(user.balance) + '。';
  }

  /* ⑧ 账单 */
  if (/^(我的)?(账单|收支|消费记录|交易记录|转账记录)$/.test(t)) {
    const rows = (db.transfers || []).filter((x) => x.fromId === user.id || x.toId === user.id).slice(0, 6);
    if (!rows.length) return '你和别人还没有转账记录。';
    return '最近 ' + rows.length + ' 笔：\n' + rows.map((x) => {
      const out = x.fromId === user.id;
      const other = findUser(out ? x.toId : x.fromId) || {};
      const st = x.status === 'received' ? '已收款' : (x.status === 'refunded' ? '已退回' : '待收款');
      return '· ' + (out ? '转出 ' : '收到 ') + money(x.amount) + '　' + (other.nickname || '') + '　' + st;
    }).join('\n');
  }

  /* ⑨ 谁在线 */
  if (/^(谁在线|都有谁在线|在线的人|谁在)$/.test(t)) {
    const online = onlineUserIds();
    const list2 = friendIds(user.id).filter((id) => online.includes(id)).map(findUser)
      .filter((u) => u && !u.bot);
    if (!list2.length) return '现在好友里没有人在线。';
    return '在线的好友（' + list2.length + ' 个）：' + list2.slice(0, 10).map((u) => u.nickname || u.username).join('、');
  }

  return '';
}
async function botAnswer(bot, chat, user, text) {
  const cfg = readAiCfg();
  const query = String(text || '').slice(0, 800);
  const isHousekeeper = bot.username === 'housekeeper';
  if (bot.username === 'qqnews') return newsBotAnswer(bot, chat, user, query);
  if (isHousekeeper) {
    const cmd = await housekeeperCommand(user, query, chat, bot);
    if (cmd) return cmd;
  }
  const who = (user.nickname || user.username || '用户');
  const howToCall = user.gender === 'female' ? '女士' : (user.gender === 'male' ? '先生' : '您');
  const whoLine = '\n【记住】当前跟你说话的是「' + who + '」（账号资料里的性别是「' + (user.gender === 'female' ? '女' : (user.gender === 'male' ? '男' : '未填')) + '」），称呼对方用「' + howToCall + '」，别叫错、也别问对方性别。';
  const sys = isHousekeeper
    ? (cfg.housekeeperPrompt || AI_DEFAULT.housekeeperPrompt || cfg.systemPrompt) + whoLine
    : ((cfg.assistantPrompt || AI_DEFAULT.assistantPrompt || cfg.systemPrompt) + whoLine);
  const messages = [{ role: 'system', content: sys }];
  const histLimit = isHousekeeper ? 8 : (Number(cfg.history) || 12);
  if (needsSearch(query)) {
    const hits = await webSearch(query);
    if (hits.length) {
      messages.push({
        role: 'system',
        content: '下面是刚刚联网查到的资料，请据此回答（不要编造，拿不准就直说）：\n' + hits.map((h, i) => (i + 1) + '. ' + h).join('\n')
      });
    }
  }
  historyFor(chat.id, bot.id, histLimit).forEach((m) => messages.push(m));
  const useCfg = isHousekeeper ? Object.assign({}, cfg, { temperature: 0.7 }) : cfg;
  const reply = await llmChat(messages, useCfg);
  let out = reply || '我刚才走神了，您再说一遍？';
  if (user.gender === 'male' || user.gender === 'female') {          // 称呼兜底，保证不会叫错
    const want = user.gender === 'female' ? '女士' : '先生';
    const wrong = user.gender === 'female' ? '先生' : '女士';
    out = out.split(wrong).join(want);
  }
  return out;
}
function scheduleBotReply(bot, chat, fromUser, text) {
  const cfg = readAiCfg();
  if (!cfg.enabled) return;
  if (!cfg.apiKey) {
    try { deliverMessage(bot, chat.id, 'text', '（还没配置 AI 密钥：打开 ' + '/ai.html' + ' 填一下就能聊了）', null); } catch (e) { }
    return;
  }
  botAnswer(bot, chat, fromUser, text).then((reply) => {
    if (reply) deliverMessage(bot, chat.id, 'text', reply, null);
  }).catch((err) => {
    const msg = String((err && err.message) || '');
    console.error('[bot] ' + msg);
    let tip = '我这边网络卡了一下，再发一次试试～';
    if (/insufficient|balance|余额|402/i.test(msg)) {
      tip = '不好意思，AI 的余额用完了，我得先停一下。\n去 platform.deepseek.com 充一点就行（充 5 块能用很久），充完直接跟我说句话我就继续干活。';
    } else if (/abort|timeout|timed out/i.test(msg)) {
      tip = '这次等太久了（网络慢），你再说一遍，我重新算。';
    } else if (/401|api key|unauthor/i.test(msg)) {
      tip = 'AI 密钥好像不对了，去后台 ai.html 重新贴一下密钥。';
    }
    try { deliverMessage(bot, chat.id, 'text', tip, null); } catch (e) { }
  });
}


/* 自动回复：对方不在线时，用 AI 以「对方本人」的口吻回一句 */
/* 第一次上线：给主要账号各开一个和机器人的会话，并打声招呼 */
/* 新注册的用户也要有机器人：加好友 + 开个欢迎会话（否则他的会话列表是空的） */
function attachBotsFor(user) {
  if (!user || user.bot) return;
  const hello = {
    ai: '你好，我是 AI 助手 👋\n只负责这个 App 怎么用：哪找不到、怎么操作都可以问我。',
    housekeeper: '您好，我是 AI 助手，随时为您效劳 👋\n可以这样使唤我：\n· 提醒我 8:30 开会\n· 天气 上海\n· 记账 午饭 25\n· 给张三发消息 你好\n· 发朋友圈 今天天气真好',
    qqnews: '我是腾讯新闻，想看什么新闻跟我说一声就行。'
  };
  let changed = false;
  /* service 账号（在线客服）不算这里的「机器人」：不给所有人建欢迎会话 */
  db.users.filter((u) => u.bot && !u.service).forEach((bot) => {
    if (bot.id === user.id) return;
    const f = friendshipBetween(user.id, bot.id);
    if (!f) {
      db.friendships.push({ id: uid('f'), fromId: bot.id, toId: user.id, status: 'accepted', createdAt: now() });
      changed = true;
    } else if (f.status !== 'accepted') {
      f.status = 'accepted';
      changed = true;
    }
    let chat = directChatBetween(user.id, bot.id);
    if (!chat) chat = createDirectChat(user.id, bot.id);
    const msgs = loadMessages(chat.id);
    if (!msgs.some((m) => m.senderId === bot.id)) {
      try {
        const r = deliverMessage(bot, chat.id, 'text', hello[bot.username] || '你好，我是机器人', null);
        if (r && r.error) console.log('[bots] 给 ' + user.username + ' 发 ' + bot.username + ' 的欢迎语失败：' + r.error);
      } catch (e) { console.log('[bots] 异常：' + e.message); }
    }
  });
  if (changed) saveFriendships();
}

function welcomeBots() {
  const main = db.users.find((u) => u.username === 'jdhhehe');
  if (!main) return;
  const hello = {
    ai: '你好，我是 AI 助手，只负责这个 App 的使用问题 👋\n哪找不到、怎么操作都可以问我，比如「怎么换头像」「朋友圈在哪发」。',
    housekeeper: '您好，我是 AI 助手，随时为您效劳 👋 整个微信里的事都能使唤我：\n· 给张三发消息 你好\n· 建个群 张三 李四　· 加好友 wzy245441549\n· 提醒我 8:30 开会　· 天气 上海　· 记账 午饭 25 / 账本\n· 发朋友圈 今天天气真好 / 写条朋友圈 加班 / 改签名 岁月静好\n· 给张三的朋友圈点赞 / 评论张三的朋友圈：好看\n· 置顶 张三 / 免打扰 张三 / 删掉 张三 / 清空和张三的聊天记录\n· 我和张三聊了什么 / 找张三说过 合同\n· 给张三转 50　· 我的账单　· 谁在线　· 余额'
  };
  db.users.filter((u) => u.bot && !u.service).forEach((bot) => {
    let chat = directChatBetween(main.id, bot.id);
    if (!chat) chat = createDirectChat(main.id, bot.id);
    const msgs = loadMessages(chat.id);
    if (msgs.some((m) => m.senderId === bot.id)) return;
      try {
        const r = deliverMessage(bot, chat.id, 'text', hello[bot.username] || '你好，我是机器人', null);
        if (r && r.error) console.log('[bots] 给 ' + user.username + ' 发 ' + bot.username + ' 欢迎语失败：' + r.error);
      } catch (e) { console.log('[bots] 给 ' + user.username + ' 发欢迎语异常：' + e.message); }
  });
}

function scheduleAutoReply(owner, chat, fromUser, text) {
  const cfg = readAiCfg();
  const sys = '你是「' + (owner.nickname || owner.username) + '」，正在微信里跟朋友聊天。现在你没空看手机，' +
    '先自动回一句客气、简短、自然的中文（20 字以内），不要暴露你是 AI，也不要承诺具体时间。';
  const messages = [{ role: 'system', content: sys }];
  historyFor(chat.id, owner.id, 6).slice(-6).forEach((m) => messages.push(m));
  llmChat(messages, Object.assign({}, cfg, { maxTokens: 120 })).then((reply) => {
    if (reply) deliverMessage(owner, chat.id, 'text', reply, null);
  }).catch((err) => { console.error('[autoreply] ' + (err && err.message)); });
}

function recallMessage(user, chatId, messageId) {
  const chat = db.chats.find((c) => c.id === chatId);
  if (!chat || !chat.memberIds.includes(user.id)) return { error: '会话不存在' };
  const messages = loadMessages(chat.id);
  const msg = messages.find((m) => m.id === messageId);
  if (!msg) return { error: '消息不存在' };
  if (msg.senderId !== user.id) return { error: '只能撤回自己的消息' };
  const windowMs = readIm().recallMinutes > 0 ? readIm().recallMinutes * 60 * 1000 : RECALL_WINDOW_MS;
  if (readIm().recallMinutes === 0) return { error: '管理员关闭了消息撤回' };
  if (Date.now() - new Date(msg.createdAt).getTime() > windowMs) {
    return { error: '超过 ' + readIm().recallMinutes + ' 分钟，不能撤回' };
  }
    msg.recalled = true;
    saveMessagesFile(chat.id, messages);
  sendToChat(chat, { type: 'recall', chatId: chat.id, messageId: msg.id });
  return { message: msg };
}

/* ------------------------------------------------------------------ HTTP */

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  /* 视频/音频要给对类型：返回 octet-stream 时播放器只能靠猜格式，
     有的机型会直接黑屏或者卡一下才开始播 */
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.ogg': 'audio/ogg',
  '.wav': 'audio/wav',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.eot': 'application/vnd.ms-fontobject',
  '.webm': 'audio/webm',
  '.ogg': 'audio/ogg',
  '.oga': 'audio/ogg',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav'
};

/** 「媒体外挂」地址：后台 branding.mediaBase（空 = 还是走本机） */
let mediaBaseCache = { at: 0, url: '' };
function mediaBaseUrl() {
  if (Date.now() - mediaBaseCache.at < 30000) return mediaBaseCache.url;
  let url = '';
  try {
    const b = readJson(path.join(DATA_DIR, 'branding.json'), {});
    const v = String((b.branding && b.branding.mediaBase) || '').trim().replace(/\/+$/, '');
    if (/^https?:\/\//i.test(v)) url = v;
  } catch (e) { url = ''; }
  mediaBaseCache = { at: Date.now(), url };
  return url;
}

function sendJson(res, status, payload, headers) {
  /* 界面打包进 App 的版本是从 file:// / 自定义协议发请求的，跨域带不了 Cookie，
     所以只要这次响应里在发会话 Cookie，就顺手把同一个令牌放进响应体，
     客户端存下来，之后用 Authorization: Bearer 带上。网页版完全不受影响。 */
  try {
    const setCookie = headers && headers['Set-Cookie'];
    const raw = Array.isArray(setCookie) ? setCookie.join(';') : String(setCookie || '');
    const m = raw.match(new RegExp(COOKIE_NAME + '=([^;]+)'));
    if (m && payload && payload.ok !== false && payload.data && !payload.data.token && m[1]) {
      payload.data = Object.assign({}, payload.data, { token: m[1] });
    }
  } catch (err) { /* 忽略 */ }
  /* 出站把上传文件路径换成长签名链接：别人拿到链接也打不开 */
  let body = signUploadsInText(JSON.stringify(payload));
  /* 「媒体外挂」开关：后台 branding.mediaBase 填了地址（CDN 域名 / 你自己电脑上的服务），
     所有 /uploads/xxx 的地址都会改写成那个地址 —— 视频、图片就不再走这台服务器。
     不填就是空操作，一切照旧。App 和网页版都认绝对地址，所以不用装包。 */
  const mediaBase = mediaBaseUrl();
  if (mediaBase && body.indexOf('/uploads/') >= 0) {
    body = body.split('"/uploads/').join('"' + mediaBase + '/uploads/');
  }
  /* JSON 压缩：列表类接口（通讯录、朋友圈、会话）在 4G 上能少传一半以上，
     手机上"转圈"的时间明显缩短。gzip 是 Node 自带的，不装任何东西。 */
  const head = Object.assign({
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',       // 不让浏览器猜类型（防 XSS 的一个基础项）
    'Referrer-Policy': 'no-referrer'
  }, headers || {});
  /* 客户端说了要 gzip、而且内容够大（>1KB）才压，小响应压了反而多花时间 */
  const wantsGzip = /\bgzip\b/.test(String((res.__req && res.__req.headers['accept-encoding']) || ''));
  if (wantsGzip && Buffer.byteLength(body) > 1024) {
    zlib.gzip(body, (err, zipped) => {
      if (err || !zipped || zipped.length >= Buffer.byteLength(body)) {
        head['Content-Length'] = Buffer.byteLength(body);
        res.writeHead(status, head);
        res.end(body);
        return;
      }
      head['Content-Encoding'] = 'gzip';
      head['Content-Length'] = zipped.length;
      head['Vary'] = 'Accept-Encoding';
      res.writeHead(status, head);
      res.end(zipped);
    });
    return;
  }
  head['Content-Length'] = Buffer.byteLength(body);
  res.writeHead(status, head);
  res.end(body);
}

const ok = (res, data, headers) => sendJson(res, 200, { ok: true, data }, headers);
const fail = (res, status, error, details) => sendJson(res, status, { ok: false, error, details: details || null });

function readBody(req) {
  /* 同一个请求可能被两个分支先后读（比如 /me/status 既是「结束我的状态」又是「改在线状态」），
     缓存一下，第二次读直接拿同一份，不会因为流已经读完而拿到空对象。 */
  if (req.__bodyPromise) return req.__bodyPromise;
  req.__bodyPromise = new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('请求体过大'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch (err) { reject(Object.assign(new Error('JSON 解析失败'), { status: 400 })); }
    });
    req.on('error', reject);
  });
  return req.__bodyPromise;
}

/* -------------------------------------------------------------- 管理后台 */

function dirSize(dir) {
  let total = 0;
  const walk = (d) => {
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (err) { return; }
    entries.forEach((entry) => {
      const p = path.join(d, entry.name);
      if (entry.isDirectory()) walk(p);
      else { try { total += fs.statSync(p).size; } catch (err) { /* 忽略 */ } }
    });
  };
  walk(dir);
  return total;
}

function closeUserConnections(userId) {
  const set = connections.get(userId);
  if (!set) return;
  set.forEach((socket) => { try { socket.end(); } catch (err) { /* 忽略 */ } });
  connections.delete(userId);
  notifyPresence(userId, false);
}

/* ================================================================
   封禁 / 解封：一处收口，保证每种入口封出来都一样有效
   以前只在后台「用户账号」里改了个字段，被封的人手里那台手机
   还留着有效登录态：长连接断了会被踢，但刷新一下照样能看会话、
   看通讯录、看朋友圈，等于没封住。现在封禁要做三件事：
     ① banned 标记（登录接口、发消息、长连接都会拦）
     ② tokenVersion +1 → 该账号所有设备上的登录态立刻作废
     ③ 关掉正在连的长连接，并通知好友「他下线了」
   ================================================================ */
function setUserBanned(u, banned, reason, by) {
  if (!u) return false;
  const on = !!banned;
  const was = !!u.banned;
  u.banned = on;
  if (on) {
    u.banReason = str(reason, 100) || u.banReason || '违规';
    u.bannedAt = now();
    u.bannedBy = by || '';
    /* 登录令牌里带的是签发时的 tokenVersion，这里 +1 之后
       对方手机上的 token 立刻对不上，所有接口都会 401。 */
    u.tokenVersion = (Number(u.tokenVersion) || 0) + 1;
    closeUserConnections(u.id);
  } else {
    u.banReason = '';
    u.bannedAt = 0;
    u.bannedBy = '';
  }
  saveUsers();
  return was !== on;      // 状态真的变了才返回 true（给审计用）
}

/* 统一的封禁提示：带上后台填的原因，用户在登录页就知道为什么进不去 */
function banMsg(u) {
  const why = u && u.banReason ? '（' + u.banReason + '）' : '';
  return '该账号已被管理员禁用' + why + '，可在登录页点「自助解封」用身份证解封';
}

/* ================================================================
   身份证自助解封
   被封 · 号的人可以在登录页点「自助解封」，填账号密码 + 身份证号；
   号码要能过下面这套校验（18 位、省份、生日、校验位），
   通过就把账号解封并直接登录。同一张身份证只能绑一个账号，
   所以随便编一个号码是解不开别人的号的。
   ================================================================ */
const ID_WEIGHTS = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const ID_CHECK = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];
const ID_PROVINCE = new Set(['11', '12', '13', '14', '15', '21', '22', '23', '31', '32', '33', '34', '35',
  '36', '37', '41', '42', '43', '44', '45', '46', '50', '51', '52', '53', '54', '61', '62', '63', '64',
  '65', '71', '81', '82', '91']);
const normalizeIdCard = (v) => String(v == null ? '' : v).trim().toUpperCase().replace(/[\s-]/g, '');
function isValidIdCard(raw) {
  const id = normalizeIdCard(raw);
  if (!/^\d{17}[\dX]$/.test(id)) return false;              // 18 位，最后一位可以是 X
  if (!ID_PROVINCE.has(id.slice(0, 2))) return false;       // 省份代码
  const y = Number(id.slice(6, 10));
  const m = Number(id.slice(10, 12));
  const d = Number(id.slice(12, 14));
  if (y < 1900 || y > new Date().getFullYear()) return false;
  const dt = new Date(y, m - 1, d);
  if (dt.getFullYear() !== y || dt.getMonth() !== m - 1 || dt.getDate() !== d) return false;   // 生日得真实存在
  if (dt.getTime() > Date.now()) return false;
  let sum = 0;
  for (let i = 0; i < 17; i += 1) sum += Number(id[i]) * ID_WEIGHTS[i];
  return ID_CHECK[sum % 11] === id[17];                     // 校验位
}
const maskIdCard = (id) => id.slice(0, 6) + '********' + id.slice(14);
const idCardHash = (id) => crypto.createHash('sha256').update('chris-idcard:' + id).digest('hex');

/* 未实名的账号能不能碰钱？—— 和微信一样：**聊天不受影响**，但转账/红包/收付款/零钱
   这些「钱」的动作必须先实名。返回 true 表示已经拦下（调用方直接 return 即可）。
   文案照着微信的口气：「根据国家规定，请先完成实名认证」。 */
function blockedByRealName(res, user) {
  try {
    if (!user) return false;
    if (user.realName && user.idCardHash) return false;      // 已经实名
    fail(res, 403, '根据国家规定，请先完成实名认证后再使用（我 → 设置 → 实名认证）', { needRealName: true });
    return true;
  } catch (e) { return false; }
}
const unbanHits = new Map();
function unbanRateAllow(ip) {
  const t = Date.now();
  const r = unbanHits.get(ip);
  if (!r || t - r.t > 10 * 60 * 1000) { unbanHits.set(ip, { t, n: 1 }); return true; }
  r.n += 1;
  if (unbanHits.size > 5000) unbanHits.clear();
  return r.n <= 20;                                          // 10 分钟最多试 20 次，防拿号码库猜号
}

/* 实名认证：同一台设备 10 分钟最多提交 10 次（防拿号码库试） */
const realNameHits = new Map();
function realNameRateAllow(key) {
  const t = Date.now();
  const r = realNameHits.get(key);
  if (!r || t - r.t > 10 * 60 * 1000) { realNameHits.set(key, { t, n: 1 }); return true; }
  r.n += 1;
  if (realNameHits.size > 5000) realNameHits.clear();
  return r.n <= 10;
}

function adminStats() {
  const chats = db.chats;
  return {
    users: db.users.length,
    banned: db.users.filter((u) => u.banned).length,
    online: onlineUserIds().length,
    friends: db.friendships.filter((f) => f.status === 'accepted').length,
    pendingRequests: db.friendships.filter((f) => f.status === 'pending').length,
    chats: chats.length,
    directChats: chats.filter((c) => c.type === 'direct').length,
    groupChats: chats.filter((c) => c.type === 'group').length,
    messages: chats.reduce((sum, c) => sum + loadMessages(c.id).length, 0),
    moments: db.moments.length,
    momentLikes: db.moments.reduce((s, m) => s + (m.likes || []).length, 0),
    momentComments: db.moments.reduce((s, m) => s + (m.comments || []).length, 0),
    announcements: db.announcements.length,
    storageBytes: dirSize(DATA_DIR)
  };
}


/* ==================== 新版后台：参考「一对一视频社交」后台的结构 ==================== */

/** 后台左侧菜单（照参考后台的分组，路径换成我们自己的 dataset 名） */
const ADMIN_NAV = [
  { key: 'dash', text: '数据总览', icon: 'dashboard' },
  { text: '设置', children: [
    { key: 'site', text: '网站信息' },
    { key: 'ui', text: '界面图标' },
    { key: 'font', text: '字体字号' },
    { key: 'theme', text: '界面配色' },
    { key: 'chatbg', text: '聊天背景' },
    { key: 'ice', text: '通话服务器' },
    { key: 'configpri', text: '私密设置' },
    { key: 'slide', text: '幻灯片管理' },
    { key: 'guide', text: '引导页' },
    { key: 'recommend', text: '推荐设置' },
    { key: 'system', text: '系统信息' }
  ] },
  { text: '用户管理', children: [
    { key: 'users', text: '本站用户' },
    { key: 'auth', text: '实名认证管理' },
    { key: 'authorauth', text: '主播认证管理' }
  ] },
  { text: '用户举报', children: [
    { key: 'reportclass', text: '举报分类' },
    { key: 'report', text: '举报列表' }
  ] },
  { text: '相册管理', children: [
    { key: 'photofee', text: '私密价格' },
    { key: 'photo', text: '相册列表' }
  ] },
  { text: '直播管理', children: [
    { key: 'liveclass', text: '分类列表' },
    { key: 'liveban', text: '禁播管理' },
    { key: 'liveshut', text: '禁言管理' },
    { key: 'livekick', text: '踢人管理' },
    { key: 'liveing', text: '直播列表' },
    { key: 'monitorz', text: '直播监控' },
    { key: 'liverecord', text: '直播记录' }
  ] },
  { text: '动态管理', children: [
    { key: 'dynamicreportclass', text: '举报类型' },
    { key: 'dynamicreport', text: '举报列表' },
    { key: 'dynamicpass', text: '审核通过列表' },
    { key: 'dynamic', text: '等待审核列表' },
    { key: 'dynamicnopass', text: '未通过列表' },
    { key: 'dynamiclower', text: '下架列表' }
  ] },
  { text: '视频管理', children: [
    { key: 'videofee', text: '私密价格' },
    { key: 'video', text: '视频列表' },
    { key: 'videoreportclass', text: '举报分类' },
    { key: 'videoreport', text: '举报列表' }
  ] },
  { text: '私聊管理', children: [
    { key: 'feevideo', text: '视频价格' },
    { key: 'feevoice', text: '语音价格' }
  ] },
  { text: '鉴黄管理', children: [
    { key: 'reflectshot', text: '直播截图' },
    { key: 'reflectyellow', text: '鉴黄记录' },
    { key: 'reflectblock', text: '封禁列表' }
  ] },
  { key: 'calls', text: '通话记录' },
  { key: 'callmonitor', text: '通话监控' },
  { text: '财务管理', children: [
    { key: 'voterecord', text: '云票记录' },
    { key: 'chargerule', text: '充值规则' },
    { key: 'charge', text: '充值记录' },
    { key: 'manual', text: '手动充值' },
    { key: 'cash', text: '提现记录' },
    { key: 'coinrecord', text: '消费记录' }
  ] },
  { text: '礼物管理', children: [ { key: 'gift', text: '礼物列表' } ] },
  { text: '等级管理', children: [
    { key: 'level', text: '经验等级' },
    { key: 'levelanchor', text: '主播等级' }
  ] },
  { text: '标签管理', children: [
    { key: 'label', text: '形象标签' },
    { key: 'evaluate', text: '评价标签' }
  ] },
  { text: '邀请奖励', children: [
    { key: 'agent', text: '邀请关系' },
    { key: 'agentprofit', text: '邀请收益' }
  ] },
  { text: '公会管理', children: [
    { key: 'family', text: '公会列表' },
    { key: 'familyuser', text: '成员管理' },
    { key: 'divideapply', text: '分成申请列表' }
  ] },
  { text: 'VIP管理', children: [
    { key: 'vip', text: 'VIP列表' },
    { key: 'vipuser', text: 'VIP用户' },
    { key: 'viporder', text: 'VIP订单' }
  ] },
  { text: '内容管理', children: [ { key: 'page', text: '页面管理' }, { key: 'chats', text: '会话管理' }, { key: 'broadcast', text: '系统公告' } ] }
];

/** 通用数据表：没有专门存储的模块统一放这里（礼物 / 等级 / 标签 / 充值规则 …） */
const EMPTY_TABLES = {
  gift: { cols: ['ID', '名称', '图标', '价格', '动效', '排序', '状态'], rows: [] },
  level: { cols: ['ID', '等级', '经验值', '图标', '排序'], rows: [] },
  levelanchor: { cols: ['ID', '等级', '经验值', '分成比例', '排序'], rows: [] },
  label: { cols: ['ID', '名称', '排序'], rows: [] },
  evaluate: { cols: ['ID', '名称', '排序'], rows: [] },
  reportclass: { cols: ['ID', '名称', '英文名', '排序'], rows: [] },
  dynamicreportclass: { cols: ['ID', '名称', '英文名', '排序'], rows: [] },
  videoreportclass: { cols: ['ID', '名称', '英文名', '排序'], rows: [] },
  chargerule: { cols: ['ID', '充值金额', '到账云票', '赠送', '排序'], rows: [] },
  photofee: { cols: ['ID', '价格', '等级', '排序'], rows: [] },
  videofee: { cols: ['ID', '价格', '等级', '排序'], rows: [] },
  feevideo: { cols: ['ID', '价格/分', '等级', '排序'], rows: [] },
  feevoice: { cols: ['ID', '价格/分', '等级', '排序'], rows: [] },
  liveclass: { cols: ['ID', '名称', '排序'], rows: [] },
  recommend: { cols: ['ID', '推荐位', '用户', '排序'], rows: [] },
  slide: { cols: ['ID', '封面', '链接', '排序'], rows: [] },
  guide: { cols: ['ID', '类型', '图片/视频', '排序'], rows: [] },
  page: { cols: ['ID', '标题', '标识', '更新时间'], rows: [] },
  vip: { cols: ['ID', '名称', '价格', '天数', '排序'], rows: [] }
};

function tableStore(name) {
  if (!db.tables) db.tables = {};
  if (!db.tables[name]) db.tables[name] = JSON.parse(JSON.stringify(EMPTY_TABLES[name] || { cols: ['ID', '名称'], rows: [] }));
  return db.tables[name];
}

function saveTables() {
  try { fs.writeFileSync(path.join(DATA_DIR, 'tables.json'), JSON.stringify(db.tables || {}, null, 2), 'utf8'); } catch (err) { /* 忽略 */ }
}

/** 数据总览：照参考后台的 5 组卡片，用我们自己的真实数据算 */
function dashboardStats() {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const yest = new Date(today.getTime() - 86400000);
  const dayOf = (t) => { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };
  const usersToday = db.users.filter((u) => dayOf(u.createdAt || 0) === today.getTime()).length;
  const usersYest = db.users.filter((u) => dayOf(u.createdAt || 0) === yest.getTime()).length;
  // 通话：从聊天里的系统消息里统计（「通话结束 · 时长 m:ss」「视频通话结束 · 时长 m:ss」）
  let calls = [], voiceMin = 0, videoMin = 0, callsToday = 0, callsYest = 0;
  try {
    const files = fs.readdirSync(path.join(DATA_DIR, 'messages'));
    files.forEach((f) => {
      const lines = fs.readFileSync(path.join(DATA_DIR, 'messages', f), 'utf8').split('\n').filter(Boolean);
      lines.forEach((line) => {
        let m; try { m = JSON.parse(line); } catch (e) { return; }
        if (m.kind !== 'system' || !/通话/.test(String(m.content || ''))) return;
        const video = /视频/.test(m.content);
        const mm = String(m.content).match(/(\d+):(\d\d)/);
        const mins = mm ? (Number(mm[1]) * 60 + Number(mm[2])) / 60 : 0;
        const rec = { chatId: f.replace(/\.jsonl$/, ''), at: m.createdAt, type: video ? '视频通话' : '语音通话', content: m.content, mins: Math.round(mins * 100) / 100 };
        calls.push(rec);
        if (!/未接听|已取消|已拒绝|无应答|对方不在线|忙线/.test(m.content)) { if (video) videoMin += mins; else voiceMin += mins; }
        if (dayOf(m.createdAt) === today.getTime()) callsToday++;
        if (dayOf(m.createdAt) === yest.getTime()) callsYest++;
      });
    });
  } catch (err) { /* 忽略 */ }
  calls.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  const moments = (db.moments || []);
  const pending = moments.filter((m) => m.status === 'pending').length;
  const pct = (cur, prev) => prev > 0 ? Math.round((cur - prev) / prev * 100) + '%' : (cur > 0 ? '+100%' : '0%');
  return {
    groups: [
      { title: '用户统计', items: [
        { label: '今日注册人数', value: usersToday, sub: '较于前一日：' + pct(usersToday, usersYest), sub2: '昨日：' + usersYest, total: '平台总注册人数：' + db.users.length }
      ] },
      { title: '审核统计', items: [
        { label: '动态未审核数', value: pending, sub: '较于前一日：0%', sub2: '昨日：0', total: '总动态数：' + moments.length }
      ] },
      { title: '通话统计', items: [
        { label: '今日通话数', value: callsToday, sub: '较于前一日：' + pct(callsToday, callsYest), sub2: '昨日：' + callsYest, total: '通话记录总数：' + calls.length },
        { label: '语音通话时间（分钟）', value: Math.round(voiceMin), sub: '', sub2: '', total: '语音通话总时间：' + Math.round(voiceMin) },
        { label: '视频通话时间（分钟）', value: Math.round(videoMin), sub: '', sub2: '', total: '视频通话总时间：' + Math.round(videoMin) },
        { label: '总通话时间（分钟）', value: Math.round(voiceMin + videoMin), sub: '', sub2: '', total: '通话时间总数：' + Math.round(voiceMin + videoMin) }
      ] }
    ],
    recentCalls: calls.slice(0, 10),
    allCalls: calls
  };
}

/** 通用列表：每个 dataset 返回 { cols, rows, total } */
function datasetRows(name, query) {
  const q = (k) => String(query.get(k) || '').trim();
  const page = Math.max(1, Number(query.get('page')) || 1);
  const pageSize = Math.min(200, Number(query.get('pageSize')) || 30);
  let cols = [], rows = [];
  if (name === 'users') {
    cols = ['ID', '用户名', '昵称', '手机号', '注册时间', '状态', '操作'];
    let list = db.users.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    if (q('uid')) list = list.filter((u) => String(u.id).includes(q('uid')));
    if (q('keyword')) { const k = q('keyword').toLowerCase(); list = list.filter((u) => (u.username || '').toLowerCase().includes(k) || (u.nickname || '').toLowerCase().includes(k) || String(u.phone || '').includes(k)); }
    if (q('status') === 'banned') list = list.filter((u) => u.banned);
    if (q('status') === 'ok') list = list.filter((u) => !u.banned);
    rows = list.map((u) => ({ id: u.id, cells: [u.id, u.username, u.nickname, u.phone || '-', String(u.createdAt || '').slice(0, 16).replace('T', ' '), u.banned ? '已封禁' : '正常', ''], raw: { id: u.id, username: u.username, nickname: u.nickname, banned: !!u.banned } }));
    return { cols, rows, total: list.length, page, pageSize };
  }
  if (name === 'calls' || name === 'callmonitor') {
    cols = ['ID', '通话类型', '状态', '会话', '时长', '时间'];
    let list = (dashboardStats().allCalls || []);
    if (q('type')) list = list.filter((r) => (q('type') === 'video' ? r.type === '视频通话' : r.type === '语音通话'));
    if (q('status') && q('status') !== 'all') list = list.filter((r) => q('status') === 'end' ? !/未接听|已取消|已拒绝/.test(r.content) : /未接听|已取消|已拒绝/.test(r.content));
    rows = list.map((r, idx) => ({ id: idx + 1, cells: [idx + 1, r.type, /未接听|已取消|已拒绝|不在线|忙线/.test(r.content) ? '未接通' : '通话结束', r.chatId, r.mins + ' 分钟', String(r.at).slice(0, 19).replace('T', ' ')], raw: r }));
    return { cols, rows, total: list.length, page, pageSize };
  }
  if (name && name.indexOf('dynamic') === 0) {
    cols = ['ID', '用户', '内容', '图片数', '点赞', '评论', '发布时间', '状态', '操作'];
    const all = (db.moments || []);
    const want = name === 'dynamic' ? 'pending' : (name === 'dynamicpass' ? 'passed' : (name === 'dynamicnopass' ? 'rejected' : (name === 'dynamiclower' ? 'lower' : null)));
    let list = want ? all.filter((m) => (m.status || 'passed') === want) : all;
    if (name === 'dynamic') list = all.filter((m) => m.status === 'pending');
    rows = list.map((m) => { const u = findUser(m.authorId) || {}; return { id: m.id, cells: [m.id, (u.nickname || '未知') + ' (' + m.authorId + ')', String(m.content || '').slice(0, 40) || '(图片)', (m.images || []).length, (m.likes || []).length, (m.comments || []).length, String(m.createdAt || '').slice(0, 16).replace('T', ' '), m.status === 'pending' ? '待审核' : (m.status === 'rejected' ? '未通过' : (m.status === 'lower' ? '已下架' : '已通过')), ''], raw: m }; });
    return { cols, rows, total: list.length, page, pageSize };
  }
  if (name === 'site' || name === 'configpri' || name === 'guide' || name === 'ice' || name === 'ui') {
    return { cols: [], rows: [], total: 0, settings: name };
  }
  const t = tableStore(name);
  const list = (t.rows || []);
  rows = list.map((r, idx) => ({ id: r.id || idx + 1, cells: (t.cols || []).map((c, ci) => (ci === 0 ? (r.id || idx + 1) : (r.cells ? r.cells[ci] : ''))), raw: r }));
  return { cols: t.cols, rows, total: list.length, page, pageSize };
}

function adminAct(body) {
  const name = str(body.dataset, 40);
  const action = str(body.action, 20);
  const id = str(body.id, 60);
  if (name === 'users') {
    const u = findUser(id);
    if (!u) return { error: '用户不存在', status: 404 };
        if (action === 'ban') { setUserBanned(u, true, '旧版后台封禁', '旧版后台'); }
        else if (action === 'unban') { setUserBanned(u, false, '', '旧版后台'); }
    else if (action === 'delete') { db.users = db.users.filter((x) => x.id !== id); saveUsers(); }
    else if (action === 'edit') { if (body.nickname !== undefined) u.nickname = str(body.nickname, 24); if (body.phone !== undefined) u.phone = str(body.phone, 20); saveUsers(); }
    else return { error: '不支持的操作', status: 400 };
    return { ok: true, user: publicUser(u) };
  }
  if (name === 'dynamic' || name === 'dynamicpass' || name === 'dynamicnopass' || name === 'dynamiclower') {
    const m = (db.moments || []).find((x) => x.id === id);
    if (!m) return { error: '动态不存在', status: 404 };
    if (action === 'pass') m.status = 'passed';
    else if (action === 'reject') m.status = 'rejected';
    else if (action === 'lower') m.status = 'lower';
    else if (action === 'delete') db.moments = (db.moments || []).filter((x) => x.id !== id);
    else return { error: '不支持的操作', status: 400 };
    saveMoments();
    return { ok: true };
  }
  const t = tableStore(name);
  if (action === 'delete') { t.rows = (t.rows || []).filter((r) => String(r.id) !== String(id)); saveTables(); return { ok: true }; }
  if (action === 'save') {
    const cells = Array.isArray(body.cells) ? body.cells.map((x) => str(x, 200)) : [];
    if (id) { const r = (t.rows || []).find((x) => String(x.id) === String(id)); if (r) r.cells = cells; }
    else { t.rows = t.rows || []; t.rows.push({ id: (t.rows.length ? Math.max(...t.rows.map((r) => Number(r.id) || 0)) : 0) + 1, cells }); }
    saveTables();
    return { ok: true };
  }
  return { error: '不支持的模块或操作', status: 400 };
}

/** 保存 dataURL 上传的文件，返回 { url, name, bytes, image } 或 { error, status } */
/* ============================================================ 图片体检
   图片木马的几种常见玩法，全在这里拦：
     ① 照片里塞 GPS/设备信息（EXIF）→ 存之前把元数据剔掉
     ② 图片炸弹（几百字节声明成几万×几万，客户端一解码就爆内存）→ 看分辨率，太大直接拒
     ③ 畸形图（截断 / 全零 / 魔数不对）→ 会让 App 里的解码器崩，直接拒
   ------------------------------------------------------------------ */
/* 图片炸弹防线：超过下面这两个数直接拒；介于之间的大图会自动缩小到 2560 长边再存。
   参考：1200 万像素解码约 48MB 内存，4000 万像素要 160MB —— 手机上就是直接被杀进程。 */
const IMG_MAX_PIXELS = 40 * 1000 * 1000;   // 硬上限 4000 万像素（再大直接拒）
const IMG_MAX_SIDE = 12000;                // 硬上限单边 12000
const IMG_SHRINK_PIXELS = 3 * 1000 * 1000; // 超过 300 万像素就自动缩小
const IMG_SHRINK_SIDE = 2560;              // 缩到长边 2560
const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** 读出图片的分辨率（读不出来就返回 null） */
function imageSizeOf(buf, mime) {
  try {
    if (mime === 'image/png') {
      if (buf.length < 24 || !buf.slice(0, 8).equals(PNG_SIG)) return null;
      return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
    }
    if (mime === 'image/gif') {
      if (buf.length < 10) return null;
      return { w: buf.readUInt16LE(6), h: buf.readUInt16LE(8) };
    }
    if (mime === 'image/jpeg') {
      let i = 2;
      while (i < buf.length - 8) {
        if (buf[i] !== 0xff) { i += 1; continue; }
        const mk = buf[i + 1];
        if (mk === 0xd8 || (mk >= 0xd0 && mk <= 0xd9) || mk === 0x01) { i += 2; continue; }
        const len = buf.readUInt16BE(i + 2);
        const isSOF = (mk >= 0xc0 && mk <= 0xc3) || (mk >= 0xc5 && mk <= 0xc7) ||
          (mk >= 0xc9 && mk <= 0xcb) || (mk >= 0xcd && mk <= 0xcf);
        if (isSOF) return { h: buf.readUInt16BE(i + 5), w: buf.readUInt16BE(i + 7) };
        if (mk === 0xda || len < 2) break;
        i += 2 + len;
      }
      return null;
    }
    if (mime === 'image/webp') {
      if (buf.length < 30 || buf.slice(0, 4).toString('latin1') !== 'RIFF') return null;
      const fourcc = buf.slice(12, 16).toString('latin1');
      if (fourcc === 'VP8X') {
        const w = 1 + (buf[24] | (buf[25] << 8) | (buf[26] << 16));
        const h = 1 + (buf[27] | (buf[28] << 8) | (buf[29] << 16));
        return { w, h };
      }
      if (fourcc === 'VP8 ') {
        return { w: buf.readUInt16LE(26) & 0x3fff, h: buf.readUInt16LE(28) & 0x3fff };
      }
      if (fourcc === 'VP8L') {
        const b = buf.readUInt32LE(21);
        return { w: (b & 0x3fff) + 1, h: ((b >> 14) & 0x3fff) + 1 };
      }
      return null;
    }
    if (mime === 'image/bmp') {
      if (buf.length < 30 || buf[0] !== 0x42 || buf[1] !== 0x4d) return null;
      return { w: Math.abs(buf.readInt32LE(18)), h: Math.abs(buf.readInt32LE(22)) };
    }
  } catch (err) { return null; }
  return null;
}

/* 这几种图我们现在不解析结构（iPhone 的 HEIC、TIFF），
   允许上传但一样要走「大小上限 + 去元数据」，不能因为读不出尺寸就把正常照片拒了。 */
const IMG_UNPARSED_OK = { 'image/heic': 1, 'image/heif': 1, 'image/tiff': 1 };

/** 去掉图片里的元数据（GPS / 设备 / 时间 / 注释）——隐私就藏在这里 */
function stripImageMeta(buf, mime) {
  try {
    if (mime === 'image/jpeg') {
      const out = [Buffer.from([0xff, 0xd8])];
      let i = 2;
      while (i < buf.length - 1) {
        if (buf[i] !== 0xff) { out.push(buf.slice(i)); break; }
        const mk = buf[i + 1];
        if (mk === 0xda) { out.push(buf.slice(i)); break; }                 // SOS 之后是图像数据，原样带走
        if (mk === 0x01 || (mk >= 0xd0 && mk <= 0xd9)) { i += 2; continue; }
        const len = buf.readUInt16BE(i + 2);
        if (len < 2 || i + 2 + len > buf.length) break;
        const drop = (mk >= 0xe1 && mk <= 0xef) || mk === 0xfe;             // APP1~APP15（EXIF/XMP/缩略图）、注释
        if (!drop) out.push(buf.slice(i, i + 2 + len));
        i += 2 + len;
      }
      return Buffer.concat(out);
    }
    if (mime === 'image/png') {
      if (!buf.slice(0, 8).equals(PNG_SIG)) return buf;
      const DROP = { tEXt: 1, zTXt: 1, iTXt: 1, eXIf: 1, tIME: 1, iCCP: 1 };
      const out = [PNG_SIG];
      let i = 8;
      while (i + 8 <= buf.length) {
        const len = buf.readUInt32BE(i);
        const type = buf.slice(i + 4, i + 8).toString('latin1');
        const total = 12 + len;
        if (i + total > buf.length) break;
        if (!DROP[type]) out.push(buf.slice(i, i + total));
        i += total;
        if (type === 'IEND') break;
      }
      return Buffer.concat(out);
    }
    if (mime === 'image/webp') {
      if (buf.length < 12 || buf.slice(0, 4).toString('latin1') !== 'RIFF') return buf;
      const out = [buf.slice(0, 12)];
      let i = 12;
      while (i + 8 <= buf.length) {
        const type = buf.slice(i, i + 4).toString('latin1');
        const len = buf.readUInt32LE(i + 4);
        const total = 8 + len + (len % 2);
        if (i + total > buf.length) break;
        if (type !== 'EXIF' && type !== 'XMP ') out.push(buf.slice(i, i + total));
        i += total;
      }
      return Buffer.concat(out);
    }
  } catch (err) { return buf; }
  return buf;
}

/** 体检：能不能解、会不会爆、元数据清干净。返回 { ok, buffer, error } */
function checkImage(buf, mime) {
  const size = imageSizeOf(buf, mime);
  if (!size || !(size.w > 0) || !(size.h > 0)) {
    if (IMG_UNPARSED_OK[mime]) return { ok: true, buffer: stripImageMeta(buf, mime) };
    return { ok: false, error: '这张图片读不出尺寸，可能不是正常图片（或者被改坏了）' };
  }
  if (size.w * size.h > IMG_MAX_PIXELS || size.w > IMG_MAX_SIDE || size.h > IMG_MAX_SIDE) {
    return { ok: false, error: '图片分辨率太大了（' + size.w + '×' + size.h + '），最多 4000 万像素、单边 12000' };
  }
  /* 大图自动缩小：这类图本身不是"炸弹"，但解码要吃几十上百 MB，手机容易卡/被杀进程 */
  const needShrink = size.w * size.h > IMG_SHRINK_PIXELS || size.w > IMG_SHRINK_SIDE || size.h > IMG_SHRINK_SIDE;
  /* 具体格式再验一遍：截断/全零/魔数不对的图，会让 App 里的解码器崩掉 */
  if (mime === 'image/png') {
    const idat = [];
    let i = 8, interlace = 0, bitDepth = 8, colorType = 6, seenIHDR = false;
    while (i + 8 <= buf.length) {
      const len = buf.readUInt32BE(i);
      const type = buf.slice(i + 4, i + 8).toString('latin1');
      if (i + 12 + len > buf.length) return { ok: false, error: '图片不完整（PNG 数据被截断了）' };
      if (type === 'IHDR') { seenIHDR = true; bitDepth = buf[i + 16]; colorType = buf[i + 17]; interlace = buf[i + 18]; }
      if (type === 'IDAT') idat.push(buf.slice(i + 8, i + 8 + len));
      i += 12 + len;
      if (type === 'IEND') break;
    }
    if (!seenIHDR || !idat.length) return { ok: false, error: '图片不完整（缺少 PNG 必要数据）' };
    const CH = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
    const ch = CH[colorType] || 4;
    const bytesPerRow = Math.ceil(size.w * ch * bitDepth / 8);
    const expect = size.h * (bytesPerRow + 1);
    try {
      const raw = zlib.inflateSync(Buffer.concat(idat), { maxOutputLength: expect + 16 });
      if (interlace === 0 && raw.length !== expect) return { ok: false, error: '图片数据对不上（损坏或被裁剪过）' };
    } catch (err) {
      return { ok: false, error: '图片解不开（数据损坏）' };
    }
  } else if (mime === 'image/jpeg') {
    if (buf.length < 100 || buf[0] !== 0xff || buf[1] !== 0xd8) return { ok: false, error: '不是正常的 JPEG' };
    if (buf.indexOf(Buffer.from([0xff, 0xd9])) < 0) return { ok: false, error: 'JPEG 被截断了（没有结尾标记）' };
  } else if (mime === 'image/gif') {
    if (buf.slice(0, 4).toString('latin1') !== 'GIF8') return { ok: false, error: '不是正常的 GIF' };
    if (buf[buf.length - 1] !== 0x3b) return { ok: false, error: 'GIF 被截断了' };
  } else if (mime === 'image/webp') {
    if (buf.slice(0, 4).toString('latin1') !== 'RIFF' || buf.slice(8, 12).toString('latin1') !== 'WEBP') {
      return { ok: false, error: '不是正常的 WebP' };
    }
  }
  const cleaned = stripImageMeta(buf, mime);
  return { ok: true, buffer: cleaned, needShrink: needShrink, w: size.w, h: size.h };
}

/* 把超大图片缩到安全尺寸（写临时文件跑一次 ffmpeg，再读回来）。
   失败就返回 null，调用方原样保存 —— 不因为"缩图失败"把用户的上传搞砸。 */
function shrinkImageBuffer(buf, ext) {
  const FF = process.env.FFMPEG_PATH || 'C:/Users/Administrator/ffmpeg/bin/ffmpeg.exe';
  const rand = Date.now() + '_' + Math.random().toString(36).slice(2);
  const tmpIn = path.join(DATA_DIR, 'shrink_' + rand + ext);
  const tmpOut = path.join(DATA_DIR, 'shrink_' + rand + '_s' + ext);
  try {
    fs.writeFileSync(tmpIn, buf);
    const r = spawnSync(FF, ['-v', 'quiet', '-y', '-i', tmpIn,
      '-vf', "scale='min(" + IMG_SHRINK_SIDE + ",iw)':-2", '-q:v', '4', tmpOut], { encoding: 'utf8' });
    if (r.status !== 0 || !fs.existsSync(tmpOut)) return null;
    return fs.readFileSync(tmpOut);
  } catch (e) { return null; }
  finally {
    try { fs.unlinkSync(tmpIn); } catch (e) { }
    try { fs.unlinkSync(tmpOut); } catch (e) { }
  }
}

function saveUploadedFile(body) {
  /* base64 是二进制的 4/3：给到 2800 万字符，才容得下「20MB 视频」这个上限。
     以前写 1400 万，等于实际只能传 ~10MB，和下面那句 20MB 的限制对不上。 */
  const dataUrl = str(body.dataUrl, 56000000);
  // mime 里可能带参数，比如 audio/webm;codecs=opus
  const m = /^data:([a-z0-9.+/-]+(?:;[a-z0-9-]+=[^;,]+)*);base64,([A-Za-z0-9+/=]+)$/i.exec(dataUrl);
  if (!m) return { error: 'dataUrl 格式不正确', status: 400 };
  const mime = m[1].split(';')[0].trim().toLowerCase();
  /* 安全：只收图片 / 音频 / 视频 / 文档 / 字体这些"数据"类型。
     text/html、image/svg+xml 这类能执行脚本的一律拒掉（不然就是存储型 XSS）。 */
  const SAFE_MIME = /^(image\/(png|jpeg|jpg|webp|gif|heic|heif|avif|bmp|tiff)|audio\/|video\/|application\/(pdf|zip|json|octet-stream|vnd\.ms-fontobject|x-font-ttf|font-woff)|text\/plain|font\/)/;
  if (!SAFE_MIME.test(mime)) {
    return { error: '不支持这种文件类型（只收图片、音视频、文档、字体）', status: 422 };
  }
  const isImage = mime.indexOf('image/') === 0;
  const extMap = {
    'image/png': '.png', 'image/jpeg': '.jpg', 'image/webp': '.webp', 'image/gif': '.gif', 'image/avif': '.avif',
    'image/heic': '.heic', 'image/heif': '.heif', 'image/bmp': '.bmp', 'image/tiff': '.tiff',
    'application/pdf': '.pdf', 'text/plain': '.txt', 'application/zip': '.zip',
    'application/json': '.json', 'video/mp4': '.mp4', 'audio/mpeg': '.mp3',
    'audio/webm': '.webm', 'audio/ogg': '.ogg', 'audio/mp4': '.m4a', 'audio/x-m4a': '.m4a',
    'audio/mpeg': '.mp3', 'audio/wav': '.wav', 'audio/x-wav': '.wav',
    'font/ttf': '.ttf', 'font/otf': '.otf', 'font/woff': '.woff', 'font/woff2': '.woff2',
    'application/font-woff': '.woff', 'application/x-font-ttf': '.ttf',
    'application/octet-stream': '.bin', 'application/vnd.ms-fontobject': '.eot'
  };
  const rawName = str(body.filename, 120);
  const nameExt = rawName && rawName.indexOf('.') !== -1 ? rawName.slice(rawName.lastIndexOf('.')) : '';
  /* 扩展名只认「类型 → 后缀」这一张白名单，文件名里的后缀一律不采信。
     否则拿不常见的类型（比如 image/heic）+ 文件名 xxx.php，就能在服务器上落地一个可执行后缀。 */
  const buffer0 = Buffer.from(m[2], 'base64');
  /* 有些客户端会把 JPEG 报成 image/png（名字叫 .png、内容却是 JPEG，iPhone 上很常见），
     以前按报来的类型去读文件头，就会报「这张图片读不出尺寸」。
     所以图片一律以**文件头**为准，不信客户端说的类型。 */
  const realMime = isImage ? (sniffImageMime(buffer0) || mime) : mime;
  let ext = extMap[realMime] || (isImage ? '.png' : '.bin');
  /* 唯一例外：浏览器读字体有时给 octet-stream，这时按文件名的字体后缀走（字体后缀本身在白名单里） */
  if (ext === '.bin' && /^\.(ttf|otf|woff2?|eot)$/i.test(nameExt)) ext = nameExt.toLowerCase();
  ext = ext.toLowerCase();
  if (!/^\.(png|jpe?g|webp|gif|heic|heif|avif|bmp|tiff|pdf|txt|zip|json|mp4|mp3|m4a|webm|ogg|wav|ttf|otf|woff2?|eot|bin)$/.test(ext)) ext = isImage ? '.png' : '.bin';
  const buffer = buffer0;
  /* 非图片文件也看一眼「内容对不对得上类型」：exe/网页伪装成 pdf、zip 是常见手法 */
  if (!isImage) {
    const head = buffer.slice(0, 12);
    const str4 = head.toString('latin1');
    const CHECK = {
      'application/pdf': () => str4.indexOf('%PDF') === 0,
      'application/zip': () => head[0] === 0x50 && head[1] === 0x4b,
      'font/ttf': () => str4.indexOf('true') === 0 || str4.indexOf('OTTO') === 0 || head[0] === 0x00,
      'application/x-font-ttf': () => str4.indexOf('true') === 0 || str4.indexOf('OTTO') === 0 || head[0] === 0x00,
      'font/otf': () => str4.indexOf('OTTO') === 0,
      'font/woff': () => str4.indexOf('wOFF') === 0,
      'application/font-woff': () => str4.indexOf('wOFF') === 0,
      'font/woff2': () => str4.indexOf('wOF2') === 0,
      'audio/mpeg': () => str4.indexOf('ID3') === 0 || head[0] === 0xff,
      'audio/ogg': () => str4.indexOf('OggS') === 0,
      'audio/wav': () => str4.indexOf('RIFF') === 0,
      'audio/x-wav': () => str4.indexOf('RIFF') === 0,
      'video/mp4': () => str4.slice(4, 8) === 'ftyp',
      'audio/mp4': () => str4.slice(4, 8) === 'ftyp',
      'audio/x-m4a': () => str4.slice(4, 8) === 'ftyp',
      'video/webm': () => head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3,
      'audio/webm': () => head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3
    };
    const check = CHECK[realMime];
    if (check && !check()) return { error: '文件内容跟类型不符，拒绝保存', status: 422 };
  }
  const isFont = /\.(ttf|otf|woff2?|eot)$/i.test(ext);
  const isAudio = /^(audio|video)\//.test(mime);
  /* 视频放宽到 40MB（原样上传的画质最好），音频还是 20MB，其它 12MB */
  const isVideo = /^video\//.test(mime);
  const limit = isImage ? 8 * 1024 * 1024
    : (isFont ? 18 * 1024 * 1024 : (isAudio ? 20 * 1024 * 1024 : (isVideo ? 40 * 1024 * 1024 : 12 * 1024 * 1024)));
  if (buffer.length > limit) {
    return { error: (isImage ? '图片' : '文件') + '超过大小限制', status: 413 };
  }
  /* 图片统一体检 + 去元数据（GPS 之类的东西不能跟着图片走） */
  let payload = buffer;
  if (isImage) {
    const img = checkImage(buffer, realMime);
    if (!img.ok) return { error: img.error, status: 422 };
    payload = img.buffer;
    /* 300 万像素以上自动缩小：图片炸弹拦不掉的那类"大图"，也不会让手机解码爆内存 */
    if (img.needShrink) {
      const small = shrinkImageBuffer(img.buffer, ext);
      if (small && small.length) payload = small;
    }
  }
  ensureDirs();
  const name = uid(isImage ? 'img' : 'file') + ext;
  /* 落盘就是密文（见 sealUploadBuffer）：磁盘/备份被拿走也看不到图片内容 */
  fs.writeFileSync(path.join(UPLOAD_DIR, name), sealUploadBuffer(name, payload));
  return { url: '/uploads/' + name, name: rawName || name, bytes: payload.length, image: isImage };
}

/** 按文件头判断图片到底是什么格式（不信客户端报的 MIME —— iPhone 上
    「名字 .png、内容其实是 JPEG」非常常见，照报来的类型读头就会误判成坏图）。 */
function sniffImageMime(buf) {
  try {
    if (buf.length > 8 && buf.slice(0, 8).equals(PNG_SIG)) return 'image/png';
    if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
    if (buf.length > 12 && buf.slice(0, 4).toString('latin1') === 'RIFF' && buf.slice(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
    if (buf.length > 6 && buf.slice(0, 4).toString('latin1') === 'GIF8') return 'image/gif';
    if (buf.length > 2 && buf[0] === 0x42 && buf[1] === 0x4d) return 'image/bmp';
    if (buf.length > 12 && buf.slice(4, 8).toString('latin1') === 'ftyp') {
      const brand = buf.slice(8, 12).toString('latin1');
      if (/^hei|^he[vx]|mif1|msf1/.test(brand)) return 'image/heic';
      if (/^avif|avis/.test(brand)) return 'image/avif';
    }
  } catch (err) { /* 忽略 */ }
  return '';
}

async function handleAdmin(req, res, parts, query) {
  const method = req.method.toUpperCase();
  const sub = parts[1] || '';

  if (sub === 'login' && method === 'POST') {
    const body = await readBody(req);
    /* 安全：后台密码绝不允许走明文 http —— 同网段抓包就能拿到密码，拿到密码等于整个后台被拖走。
       本机（127.0.0.1）除外，方便本地脚本；其它来源一律要求 https。 */
    if (!req.socket.encrypted && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      return fail(res, 403, httpsHint(req));
    }
    /* 账号：后台自己设的（data/admin.json 的 username）和默认的 admin 都收，
       免得浏览器自动填了 admin 就被判错、连着错五次锁 30 分钟 */
    const wantUser = String(adminAuth.username || 'admin').trim();
    const gotUser = String(body.username || '').trim();
    if (gotUser && gotUser !== wantUser && gotUser.toLowerCase() !== 'admin') {
      return fail(res, 401, '管理员账号或密码不正确');
    }
    if (!verifySecretRecord(adminAuth, String(body.password || '').trim())) {
      return fail(res, 401, '管理员密码不正确');
    }
    /* 把「我是谁」一起给页面，页面拿到就能直接进，不用再查一次会话 */
    /* 新后台（/manage.html）走的是 ops 会话，所以这里把两个 Cookie 都发：
       老 Cookie 给老页面，ops Cookie 给新后台，这样点开就直接能用全部页面。 */
    const superAdmin = (opsStore.admins || []).find((a) => a.role === 'super' && !a.disabled) || null;
    const cookies = [adminCookie(signAdminToken(), Math.floor(SESSION_TTL_MS / 1000))];
    let adminInfo = {
      id: 'root',
      username: String(adminAuth.username || 'admin'),
      name: '超级管理员',
      role: 'super',
      roleName: OPS_ROLE_NAMES.super,
      perms: OPS_ROLES.super || []
    };
    if (superAdmin) {
      cookies.push(OPS_COOKIE + '=' + encodeURIComponent(signOpsToken(superAdmin, clientInfo(req).ip))
        + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + Math.floor(OPS_SESSION_TTL_MS / 1000));
      adminInfo = opsMe(superAdmin);
    }
    ok(res, { admin: adminInfo }, { 'Set-Cookie': cookies });
    return;
  }

  /* 免密登录（给后台登录页用）：/api/admin/quicklogin?pw=<管理员密码>
     密码对了就把登录 Cookie 发下去 —— 浏览器自动填错密码进不去时，用带 ?pw= 的链接点一下就能进。 */
  if (sub === 'quicklogin' && method === 'GET') {
    const pw = String(query.get('pw') || '').trim();
    if (!pw || !verifySecretRecord(adminAuth, pw)) {
      strikeIp(clientInfo(req).ip, '后台免密链接密码错');
      return fail(res, 401, '密码不对');
    }
    ok(res, { admin: true }, { 'Set-Cookie': adminCookie(signAdminToken(), Math.floor(SESSION_TTL_MS / 1000)) });
    return;
  }

  if (sub === 'logout' && method === 'POST') {
    ok(res, { loggedOut: true }, { 'Set-Cookie': adminCookie('', 0) });
    return;
  }

  if (sub === 'session' && method === 'GET') {
    const authed = isAdmin(req);
    ok(res, {
      authenticated: authed,
      /* 老式超管 Cookie 也要把「我是谁」带上：不带的话后台页面 start() 读不到名字会报错，
         表现就是「已经登录了却还停在登录页」。 */
      admin: authed ? {
        id: 'root',
        username: String(adminAuth.username || 'admin'),
        name: '超级管理员',
        role: 'super',
        roleName: OPS_ROLE_NAMES.super,
        perms: OPS_ROLES.super || []
      } : null,
      defaultPasswordInUse: verifySecretRecord(adminAuth, DEFAULT_ADMIN_PASSWORD)
    });
    return;
  }

  if (!isAdmin(req)) return fail(res, 401, '请先登录管理后台');

  /* AI 助手 / 管家的配置：密钥、模型、人设、自动回复开关 */
  if (sub === 'ai' && method === 'GET') {
    const cfg = readAiCfg();
    ok(res, {
      ai: {
        enabled: !!cfg.enabled,
        autoReply: !!cfg.autoReply,
        baseUrl: cfg.baseUrl || AI_DEFAULT.baseUrl,
        model: cfg.model || AI_DEFAULT.model,
        systemPrompt: cfg.systemPrompt || '',
        housekeeperPrompt: cfg.housekeeperPrompt || AI_DEFAULT.housekeeperPrompt || '',
        hasKey: !!cfg.apiKey,
        keyTail: cfg.apiKey ? ('****' + String(cfg.apiKey).slice(-4)) : '',
        bots: db.users.filter((u) => u.bot).map((u) => ({ id: u.id, username: u.username, nickname: u.nickname }))
      }
    });
    return;
  }
  if (sub === 'ai' && method === 'POST') {
    const body = await readBody(req);
    const patch = {};
    if (body.enabled !== undefined) patch.enabled = !!body.enabled;
    if (body.autoReply !== undefined) patch.autoReply = !!body.autoReply;
    if (body.baseUrl !== undefined) patch.baseUrl = str(body.baseUrl, 200) || AI_DEFAULT.baseUrl;
    if (body.model !== undefined) patch.model = str(body.model, 60) || AI_DEFAULT.model;
    if (body.systemPrompt !== undefined) patch.systemPrompt = str(body.systemPrompt, 2000);
    if (body.housekeeperPrompt !== undefined) patch.housekeeperPrompt = str(body.housekeeperPrompt, 2000);
    if (body.apiKey !== undefined && String(body.apiKey).trim()) patch.apiKey = String(body.apiKey).trim().slice(0, 200);
    const next = saveAiCfg(patch);
    ensureBots();
    ok(res, { saved: true, hasKey: !!next.apiKey });
    return;
  }

  if (sub === 'stats' && method === 'GET') { ok(res, adminStats()); return; }

  /* ---------- 新版后台：菜单 / 总览 / 通用列表 / 通用操作 ---------- */
  if (sub === 'nav' && method === 'GET') { ok(res, { nav: ADMIN_NAV }); return; }
  if (sub === 'dash' && method === 'GET') { ok(res, dashboardStats()); return; }
  if (sub === 'rows' && method === 'GET') {
    const name = str(query.get('name'), 40);
    if (!name) return fail(res, 400, '缺少 name');
    ok(res, datasetRows(name, query));
    return;
  }
  if (sub === 'act' && method === 'POST') {
    const body = await readBody(req);
    const r = adminAct(body);
    if (r && r.error) return fail(res, r.status || 400, r.error);
    ok(res, r || {});
    return;
  }

  if (sub === 'branding' && method === 'GET') {
    ok(res, { branding: db.branding });
    return;
  }

  /* ---------- ＋ 面板（控制台可改名称 / 图标 / 动作 / 开关 / 顺序） ---------- */
  if (sub === 'plus-panel' && method === 'GET') {
    ok(res, { items: db.plusPanel, icons: PLUS_ICONS, actions: PLUS_ACTIONS, defaults: DEFAULT_PLUS_ITEMS });
    return;
  }

  if (sub === 'plus-panel' && method === 'PUT') {
    const body = await readBody(req);
    if (!Array.isArray(body.items)) return fail(res, 400, 'items 必须是数组');
    db.plusPanel = normalizePlusItems(body.items);
    savePlusPanel();
    // 在线用户实时更新，不用刷新
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'pluspanel', items: db.plusPanel });
    });
    ok(res, { items: db.plusPanel });
    return;
  }

  /* ---------- 礼物管理：加礼物 / 改名 / 换图标 / 定价 / 分类 / 上下架 ---------- */
  if (sub === 'gifts' && method === 'GET') {
    const cats = [];
    db.gifts.concat(DEFAULT_GIFTS).forEach(function (g) {
      if (g.category && cats.indexOf(g.category) < 0) cats.push(g.category);
    });
    ok(res, { gifts: db.gifts, icons: GIFT_ICON_PRESETS, categories: cats, defaults: DEFAULT_GIFTS });
    return;
  }

  if (sub === 'gifts' && method === 'PUT') {
    const body = await readBody(req);
    if (!Array.isArray(body.gifts)) return fail(res, 400, 'gifts 必须是数组');
    db.gifts = normalizeGifts(body.gifts);
    saveGifts();
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'gifts', gifts: db.gifts });
    });
    ok(res, { gifts: db.gifts });
    return;
  }

  /* ---------- 状态管理：分类 + 每个分类里的状态 ---------- */
  if (sub === 'statuses' && parts.length === 2 && method === 'GET') {
    ok(res, { categories: db.statuses, defaults: STATUS_DEFAULT });
    return;
  }

  if (sub === 'statuses' && method === 'PUT') {
    const body = await readBody(req);
    if (!Array.isArray(body.categories)) return fail(res, 400, 'categories 必须是数组');
    db.statuses = normalizeStatus(body.categories);
    saveStatuses();
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'statuses', categories: db.statuses.filter((c) => c.enabled) });
    });
    ok(res, { categories: db.statuses });
    return;
  }

  /* ---------- 表情包管理：本地表情包 + 第三方图源 ---------- */
  // 后台「测试」按钮：拿当前配置去第三方搜一下，把结果和错误原样返回
  if (sub === 'stickers' && parts[2] === 'test' && method === 'GET') {
    const url = thirdPartyUrl(db.stickers.thirdParty, str(query.get('q'), 30) || '开心');
    if (!url) return ok(res, { items: [], error: '还没选第三方服务或没填 key / 接口地址' });
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 8000);
      const r = await fetch(url, { signal: ctl.signal, headers: { Accept: 'application/json' } });
      clearTimeout(timer);
      const data = await r.json().catch(() => null);
      ok(res, { url: url.replace(/key=[^&]+/i, 'key=****'), status: r.status, items: parseThirdParty(db.stickers.thirdParty.provider, data).slice(0, 8) });
    } catch (err) {
      ok(res, { error: '请求失败：' + (err && err.message ? err.message : '未知错误') });
    }
    return;
  }

  if (sub === 'stickers' && parts.length === 2 && method === 'GET') {
    ok(res, {
      packs: db.stickers.packs,
      thirdParty: db.stickers.thirdParty,
      providers: STICKER_PROVIDERS,
      defaults: STICKER_PACKS_DEFAULT
    });
    return;
  }

  if (sub === 'stickers' && method === 'PUT') {
    const body = await readBody(req);
    const next = normalizeStickers({
      packs: Array.isArray(body.packs) ? body.packs : db.stickers.packs,
      thirdParty: body.thirdParty && typeof body.thirdParty === 'object'
        ? Object.assign({}, db.stickers.thirdParty, body.thirdParty)
        : db.stickers.thirdParty
    });
    db.stickers = next;
    saveStickers();
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'stickers', packs: db.stickers.packs.filter((p) => p.enabled) });
    });
    ok(res, { packs: db.stickers.packs, thirdParty: db.stickers.thirdParty });
    return;
  }

  if (sub === 'upload' && method === 'POST') {
    const body = await readBody(req);
    const saved = saveUploadedFile(body);
    if (saved.error) return fail(res, saved.status, saved.error);
    ok(res, saved);
    return;
  }

  if (sub === 'branding' && method === 'PUT') {
    const body = await readBody(req);
    const next = Object.assign({}, db.branding);
    if (body.appName !== undefined) next.appName = str(body.appName, 30) || DEFAULT_BRANDING.appName;
    if (body.logo !== undefined) next.logo = str(body.logo, 300000);
    if (body.chatBackground !== undefined) next.chatBackground = str(body.chatBackground, 300000);
    if (body.fontFamily !== undefined) next.fontFamily = str(body.fontFamily, 400);
    if (body.fontName !== undefined) next.fontName = str(body.fontName, 120);
    if (body.fontUrl !== undefined) next.fontUrl = str(body.fontUrl, 500000);
    if (body.fontScale !== undefined) {
      const fs2 = Number(body.fontScale);
      next.fontScale = (isFinite(fs2) && fs2 >= 0.8 && fs2 <= 1.4) ? Math.round(fs2 * 100) / 100 : 1;
    }
    if (body.accentColor !== undefined) next.accentColor = hexColor(body.accentColor);
    if (body.textColor !== undefined) next.textColor = hexColor(body.textColor);
    if (body.iceServers !== undefined) next.iceServers = str(body.iceServers, 4000);
    if (body.icons && typeof body.icons === 'object') {
      next.icons = Object.assign({}, db.branding.icons);
      Object.keys(DEFAULT_BRANDING.icons).forEach(function (key) {
        if (body.icons[key] !== undefined) next.icons[key] = str(body.icons[key], 300000);
      });
    }
    next.updatedAt = now();
    db.branding = next;
    saveBranding();
    // 所有在线用户实时换图标，不用刷新
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'branding', branding: db.branding });
    });
    ok(res, { branding: db.branding });
    return;
  }

  if (sub === 'system' && method === 'GET') {
    ok(res, {
      node: process.version,
      platform: process.platform,
      port: PORT,
      host: HOST,
      dataDir: DATA_DIR,
      uptimeSeconds: Math.round(process.uptime()),
      memoryMB: Math.round(process.memoryUsage().rss / 1024 / 1024),
      startedAt: new Date(Date.now() - process.uptime() * 1000).toISOString()
    });
    return;
  }

  if (sub === 'users' && method === 'GET') {
    const q = str(query.get('q'), 30).toLowerCase();
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(100, Number(query.get('pageSize')) || 30);
    let list = db.users.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    if (q) list = list.filter((u) => u.username.toLowerCase().includes(q) || u.nickname.toLowerCase().includes(q));
    const online = onlineUserIds();
    const total = list.length;
    ok(res, {
      users: list.slice((page - 1) * pageSize, page * pageSize).map((u) => ({
        id: u.id,
        username: u.username,
        nickname: u.nickname,
        realName: u.realName || '',                  // 真名（只有后台能看到）
        realNameMask: realNameOf(u),                 // 手机端转账页显示的这个
        realNameHidden: u.realNameHidden !== false,
        balance: Number(u.balance) || 0,             // 零钱余额
        transferLimit: u.transferLimit === undefined ? 20000 : Number(u.transferLimit) || 0,   // 单笔转账限额（0=不限）
        avatar: u.avatar || '',
        bio: u.bio || '',
        gender: u.gender || '',
        banned: !!u.banned,
        createdAt: u.createdAt,
        friendCount: friendIds(u.id).length,
        momentCount: db.moments.filter((m) => m.authorId === u.id).length,
        chatCount: chatsOf(u.id).length,
        online: online.includes(u.id)
      })),
      total, page, pageSize
    });
    return;
  }

  if (sub === 'users' && method === 'PATCH') {
    const target = findUser(parts[2]);
    if (!target) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    if (body.banned !== undefined) {
      target.banned = !!body.banned;
      if (target.banned) closeUserConnections(target.id);
    }
    if (body.nickname !== undefined) target.nickname = str(body.nickname, 24) || target.nickname;
    if (body.gender !== undefined) target.gender = normalizeGender(body.gender);
    if (body.realName !== undefined) target.realName = str(body.realName, 24);          // 允许清空
    if (body.realNameHidden !== undefined) target.realNameHidden = !!body.realNameHidden;
    if (body.balance !== undefined) {
      const b = Number(body.balance);
      target.balance = isFinite(b) && b > 0 ? Math.round(b * 100) / 100 : 0;
      sendTo(target.id, { type: 'balance', balance: target.balance });      // 在线的话余额立刻刷新
    }
    if (body.transferLimit !== undefined) {
      const l = Number(body.transferLimit);
      target.transferLimit = isFinite(l) && l > 0 ? Math.round(l * 100) / 100 : 0;   // 0 = 不限
    }
    if (body.password) {
      if (String(body.password).length < 6) return fail(res, 422, '新密码至少 6 位');
      const salt = crypto.randomBytes(16).toString('hex');
      target.salt = salt;
      target.passwordHash = hashPassword(String(body.password), salt);
    }
    saveUsers();
    // 实名变了：让这个人的好友和本人马上能看到新的显示名
    friendIds(target.id).forEach((fid) => sendTo(fid, { type: 'profile', user: publicUser(target) }));
    sendTo(target.id, { type: 'profile', user: publicUser(target) });
    ok(res, { user: { id: target.id, username: target.username, nickname: target.nickname, gender: target.gender || '', banned: !!target.banned } });
    return;
  }

  /* 余额充值：后台给某个用户充值（amount 是加多少，不是设多少） */
  if (sub === 'users' && parts[2] && parts[3] === 'recharge' && method === 'POST') {
    const target = findUser(parts[2]);
    if (!target) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '充值金额要大于 0');
    if (amount > 1000000) return fail(res, 422, '单次充值不能超过 1000000');
    const before = Number(target.balance) || 0;
    target.balance = Math.round((before + amount) * 100) / 100;
    saveUsers();
    sendTo(target.id, { type: 'balance', balance: target.balance });      // 在线的话余额立刻刷新
    ok(res, { id: target.id, username: target.username, nickname: target.nickname, recharged: amount, balanceBefore: before, balance: target.balance });
    return;
  }

  if (sub === 'users' && method === 'DELETE') {
    const target = findUser(parts[2]);
    if (!target) return fail(res, 404, '用户不存在');
    closeUserConnections(target.id);
    db.users = db.users.filter((u) => u.id !== target.id);
    db.friendships = db.friendships.filter((f) => f.fromId !== target.id && f.toId !== target.id);
    db.moments = db.moments.filter((m) => m.authorId !== target.id);
    db.chats = db.chats
      .filter((c) => !(c.type === 'direct' && c.memberIds.includes(target.id)))
      .map((c) => Object.assign(c, { memberIds: c.memberIds.filter((id) => id !== target.id) }))
      .filter((c) => c.memberIds.length >= 2);
    delete db.reads[target.id];
    delete db.momentViews[target.id];
    saveUsers(); saveFriendships(); saveMoments(); saveChats(); saveReads(); saveMomentViews();
    ok(res, { deleted: true, username: target.username });
    return;
  }

  if (sub === 'moments' && method === 'GET') {
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(50, Number(query.get('pageSize')) || 20);
    const list = db.moments.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    ok(res, {
      moments: list.slice((page - 1) * pageSize, page * pageSize).map((m) => ({
        id: m.id,
        author: publicUser(findUser(m.authorId)),
        content: m.content,
        images: m.images || [],
        likes: (m.likes || []).length,
        comments: (m.comments || []).length,
        createdAt: m.createdAt
      })),
      total: list.length, page, pageSize
    });
    return;
  }

  if (sub === 'moments' && method === 'DELETE') {
    const idx = db.moments.findIndex((m) => m.id === parts[2]);
    if (idx === -1) return fail(res, 404, '动态不存在');
    const [removed] = db.moments.splice(idx, 1);
    saveMoments();
    broadcastMoment(removed.authorId, {
      type: 'moment', action: 'delete', momentId: removed.id, authorId: removed.authorId
    });
    ok(res, { deleted: true });
    return;
  }

  if (sub === 'chats' && method === 'GET') {
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(50, Number(query.get('pageSize')) || 20);
    const list = db.chats.slice().sort((a, b) => {
      const la = loadMessages(a.id);
      const lb = loadMessages(b.id);
      const ta = la.length ? la[la.length - 1].createdAt : a.createdAt;
      const tb = lb.length ? lb[lb.length - 1].createdAt : b.createdAt;
      return String(tb).localeCompare(String(ta));
    });
    ok(res, {
      chats: list.slice((page - 1) * pageSize, page * pageSize).map((c) => {
        const messages = loadMessages(c.id);
        const last = messages.length ? messages[messages.length - 1] : null;
        const pv = lastPreviewMessage(messages);
        return {
          id: c.id,
          type: c.type,
          name: c.type === 'group' ? c.name : '',
          members: c.memberIds.map((id) => publicUser(findUser(id))).filter(Boolean),
          messageCount: messages.length,
          lastMessage: last ? {
            senderId: (pv || last).senderId,
            preview: pv ? previewTextOf(pv) : '',
            createdAt: last.createdAt
          } : null,
          createdAt: c.createdAt
        };
      }),
      total: list.length, page, pageSize
    });
    return;
  }

  if (sub === 'messages' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === str(query.get('chatId'), 40));
    if (!chat) return fail(res, 404, '会话不存在');
    const limit = Math.min(200, Number(query.get('limit')) || 50);
    ok(res, {
      chat: {
        id: chat.id, type: chat.type, name: chat.name,
        members: chat.memberIds.map((id) => publicUser(findUser(id))).filter(Boolean)
      },
      messages: loadMessages(chat.id).slice(-limit).map((m) => ({
        id: m.id,
        seq: m.seq,
        senderId: m.senderId,
        senderName: (findUser(m.senderId) || {}).nickname || (m.senderId === 'system' ? '系统公告' : '已注销用户'),
        kind: m.kind,
        content: m.content,
        /* 通话记录带上通话本身的信息（音频/视频、接通没接通、时长），
           客户端拿它画电话/摄像机小图标 */
        call: m.call || null,
        recalled: !!m.recalled,
        createdAt: m.createdAt
      }))
    });
    return;
  }

  if (sub === 'broadcast' && method === 'POST') {
    const body = await readBody(req);
    const content = str(body.content, 300);
    if (!content) return fail(res, 422, '公告内容不能为空');
    let chats = 0;
    db.chats.forEach((chat) => {
      chat.seq = (chat.seq || 0) + 1;
      const message = {
        id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
        kind: 'system', content, createdAt: now(), recalled: false
      };
      appendMessage(chat.id, message);
      chat.memberIds.forEach((id) => {
        sendTo(id, { type: 'message', message, chat: chatSummary(chat, id), clientId: null });
      });
      chats += 1;
    });
    saveChats();
    const record = { id: uid('an'), content, createdAt: now(), chats };
    db.announcements.unshift(record);
    db.announcements = db.announcements.slice(0, 50);
    saveAnnouncements();
    ok(res, { announcement: record });
    return;
  }

  if (sub === 'announcements' && method === 'GET') {
    ok(res, { announcements: db.announcements.slice(0, 50) });
    return;
  }

  fail(res, 404, '管理接口不存在');
}

/* ============================================================ 附近的人
   微信的「发现 → 附近」：进过这个页的人会把位置报到服务器（data/nearby.json），
   半小时内的算「附近」；别人进来就能看到按距离排的名单，可以打招呼。
   隐私：只存最近一次的位置和时间，超时就自动清掉；本人可以隐身（visible=false）。 */
const NEARBY_TTL_MS = 30 * 60 * 1000;      // 半小时内报过位置才算「附近」
const NEARBY_MAX_KM = 5;                   // 只显示 5 公里以内的（用户要求；微信也是这个量级）
let nearbyCache = null;
function nearbyFile() { return path.join(DATA_DIR, 'nearby.json'); }
function loadNearby() {
  if (nearbyCache) return nearbyCache;
  const d = readJson(nearbyFile(), { users: {} });
  nearbyCache = (d && typeof d.users === 'object' && d.users) ? d.users : {};
  return nearbyCache;
}
function saveNearby() {
  if (!nearbyCache) return;
  writeJson(nearbyFile(), { users: nearbyCache, savedAt: now() });
}
/** 顺手把过期的位置删掉，别让文件越堆越大 */
function pruneNearby() {
  const map = loadNearby();
  const cut = Date.now() - NEARBY_TTL_MS;
  let changed = false;
  Object.keys(map).forEach((id) => {
    if (!map[id] || !(map[id].at > cut) || !findUser(id)) { delete map[id]; changed = true; }
  });
  return changed;
}
/** 两点之间的距离（公里）：球面公式，够用 */
function nearbyKm(a, b) {
  const R = 6371;
  const rad = (x) => (x * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/* ============================================================ 摇一摇
   微信的逻辑：你摇的那几秒里，另一个也在摇的人会被摇到。
   所以服务器只记「最近 30 秒内谁摇了」，两边一撞就配对；
   5 分钟内不再摇到同一个人（不然一直摇到同一个太假）。 */
const SHAKE_TTL_MS = 30 * 1000;
const SHAKE_AGAIN_MS = 5 * 60 * 1000;
let shakeCache = null;
function shakeFile() { return path.join(DATA_DIR, 'shake.json'); }
function loadShakes() {
  if (shakeCache) return shakeCache;
  const d = readJson(shakeFile(), { users: {} });
  shakeCache = (d && typeof d.users === 'object' && d.users) ? d.users : {};
  return shakeCache;
}
function saveShakes() {
  if (!shakeCache) return;
  writeJson(shakeFile(), { users: shakeCache, savedAt: now() });
}

/* ============================================================ 直播专场（轻量）
   房间名单在 data/live.json（后台直接改文件就行）；
   这里只在内存里记「谁在看这个房间」和「多少赞」，弹幕/点赞走长连接实时广播。 */
const liveViewers = new Map();     // roomId -> Set(userId)
const liveLikes = new Map();       // roomId -> 点赞数
const liveHosts = new Map();       // roomId -> 正在推流的那个人
/* 视频号的后台可调项：样式（数字/颜色）+ 开关。前台发布不受这些影响，除非开关关掉。 */
const FEED_STYLE_DEFAULT = {
  avatar: 46,          // 右侧头像大小
  nameSize: 16,        // 作者名字号
  descSize: 14,        // 文案字号
  musicSize: 12.5,     // 音乐字号
  railIcon: 27,        // 右侧动作图标大小
  railGap: 20,         // 动作栏间距
  padBottom: 28,       // 底部留白
  corner: 0            // 0 = 全屏；>0 = 卡片圆角（留个口子）
};
const FEED_FLAGS_DEFAULT = {
  allowPublish: true,  // 前台能不能自己发视频
  allowTrim: true,     // 发布时能不能剪水印
  showRail: true,      // 显示右侧动作栏（赞/评论/分享）
  autoPlay: true       // 进入就自动播当前这条
};
function normalizeFeedStyle(s) {
  const out = Object.assign({}, FEED_STYLE_DEFAULT);
  Object.keys(FEED_STYLE_DEFAULT).forEach((k) => {
    const v = Number(s[k]);
    if (isFinite(v) && v >= 0 && v <= 400) out[k] = v;
  });
  return out;
}
function normalizeFeedFlags(s) {
  const out = Object.assign({}, FEED_FLAGS_DEFAULT);
  Object.keys(FEED_FLAGS_DEFAULT).forEach((k) => {
    if (s[k] !== undefined) out[k] = !!s[k];
  });
  return out;
}
function liveBroadcast(roomId, payload) {
  const set = liveViewers.get(roomId);
  if (!set || !set.size) return;
  set.forEach((uid) => sendTo(uid, payload));
}
function pruneShakes() {
  const map = loadShakes();
  const cut = Date.now() - SHAKE_TTL_MS;
  Object.keys(map).forEach((id) => {
    const r = map[id];
    if (!r || !(r.at > cut) || !findUser(id)) delete map[id];
  });
  return map;
}

async function handleApi(req, res, pathname, query) {
  const method = req.method.toUpperCase();
  const parts = pathname.split('/').filter(Boolean).slice(1);

  if (parts[0] === 'admin') {
    await handleAdmin(req, res, parts, query);
    return;
  }

  /* 独立的管理员后台（/manage.html）：多账号 + 角色 + 审计日志 + 风控 */
  if (parts[0] === 'ops') {
    await handleOps(req, res, parts, query);
    return;
  }

  /* ------------------------------------------------ 设备确认登录（仿扫码登录） */
  // 思路和 QQ 的扫码登录一样：这台设备出一个码，另一台已登录的设备确认，这台就登上了
  /* ------------------------------------------------ TRTC（腾讯云实时音视频）签名
     客户端进房要三样东西：sdkAppId、userId、userSig；房间号双方要一致。
     房间号按「会话 id」算：两个人拿同一个会话 id 算出来一定一样。
     密钥只在服务端，绝不下发。 */
  if (parts[0] === 'trtc' && parts[1] === 'sig' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const cfg = readTrtcCfg();
    if (!cfg.sdkAppId || !cfg.secretKey) return fail(res, 500, 'TRTC 还没配置（data/trtc.json 里填 sdkAppId 和 secretKey）');
    /* 语音这条的总开关：data/trtc.json 里写 "voiceEnabled": false，
       语音的签名请求直接失败，客户端自动退回自建转发通道（视频不受影响）。 */
    const wantMedia = String(query.get('media') || '').toLowerCase();
    if (wantMedia === 'audio' && cfg.voiceEnabled === false) {
      return fail(res, 503, '语音暂不走 TRTC（服务端 data/trtc.json 的 voiceEnabled 关掉了）');
    }
    const expire = Number(query.get('expire')) > 0 ? Number(query.get('expire')) : cfg.expireSeconds;
    const seed = String(query.get('room') || query.get('chat') || '').trim().slice(0, 80)
      || ('u' + me.id);
    const userSig = trtcUserSig(me.id, expire);
    if (!userSig) return fail(res, 500, 'TRTC 签名失败');
    return ok(res, {
      sdkAppId: cfg.sdkAppId,
      userId: me.id,
      userSig,
      roomId: trtcRoomId(seed),      // 数字房间号（TRTCParams.roomId 要的是 UInt32）
      roomStr: seed,                 // 原始那串（两边都用它算，方便排查）
      expire,
      expiresAt: Math.floor(Date.now() / 1000) + expire
    });
  }

  if (parts[0] === 'pair' && parts[1] === 'start' && method === 'POST') {
    prunePairCodes();
    let code = '';
    do { code = String(Math.floor(100000 + Math.random() * 900000)); } while (pairCodes.has(code));
    pairCodes.set(code, { secret: uid('pair'), createdAt: Date.now(), expiresAt: Date.now() + PAIR_TTL_MS, userId: null, approvedName: '' });
    ok(res, { code, expiresIn: Math.round(PAIR_TTL_MS / 1000) });
    return;
  }

  if (parts[0] === 'pair' && parts[1] === 'status' && method === 'GET') {
    prunePairCodes();
    const rec = pairCodes.get(str(query.get('code'), 10));
    if (!rec) return ok(res, { status: 'expired' });
    if (!rec.userId) return ok(res, { status: 'pending' });
    const u = findUser(rec.userId);
    if (!u) { pairCodes.delete(str(query.get('code'), 10)); return ok(res, { status: 'expired' }); }
    pairCodes.delete(str(query.get('code'), 10));   // 一次性
    ok(res, { status: 'approved', user: publicUser(u) },
      { 'Set-Cookie': sessionCookie(signToken(u.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  if (parts[0] === 'captcha' && method === 'GET') {
    const cap = makeCaptcha();
    ok(res, { id: cap.id, svg: cap.svg, expiresIn: Math.round(CAPTCHA_TTL_MS / 1000) });
    return;
  }

  /* 登录滑动验证：① 领题 */
  if (parts[0] === 'slider' && parts.length === 1 && method === 'GET') {
    const ip = clientInfo(req).ip;
    if (!sliderRateAllow(ip)) return fail(res, 429, '换题太频繁了，歇一会儿再试');
    ok(res, makeSliderChallenge());
    return;
  }

  /* 登录滑动验证：② 交卷（位置对上了给一次性通行证） */
  if (parts[0] === 'slider' && parts[1] === 'verify' && method === 'POST') {
    const body = await readBody(req);
    const r = checkSlider(str(body.id, 60), body.x, body.y);
    if (r.error) return fail(res, 400, r.error);
    ok(res, { ticket: r.ticket, expiresIn: r.expiresIn });
    return;
  }

  if (parts[0] === 'version' && method === 'GET') {
    ok(res, { version: assetVersion(), startedAt: new Date(Date.now() - process.uptime() * 1000).toISOString() });
    return;
  }

  if (method === 'OPTIONS') {
    res.writeHead(204, { Allow: 'GET,POST,PATCH,DELETE,OPTIONS' });
    res.end();
    return;
  }

  /* 登录前只开放这几个接口（登录页要用的），其它一律要求先登录。
     这样没账号的黑客连「发现页配了什么、我页配了什么、礼物有哪些」都看不到。 */
  const PUBLIC_API = ['captcha', 'version', 'health', 'lan', 'branding', 'ui', 'badges', 'register', 'login', 'logout', 'session', 'pair', 'unban', 'which', 'qr', 'clientlog'];
  if (PUBLIC_API.indexOf(parts[0]) < 0) {
    if (!currentUser(req)) {
      strikeIp(clientInfo(req).ip, '未登录取数据 ' + parts[0]);
      return fail(res, 401, '请先登录');
    }
  }
  /* 青少年模式：开了以后按后台（家长）勾选的项，把这些接口直接挡住 */
  {
    const cu = currentUser(req);
    if (cu) {
      const blocked = teenBlocked(cu, parts);
      if (blocked) return fail(res, 403, blocked);
    }
  }

  if (parts[0] === 'health') { ok(res, { service: 'chris-chat', time: now() }); return; }

  /* App 崩溃上报：写进 data/client-errors.jsonl（手机上崩了，电脑这边能看到调用栈） */
  if (parts[0] === 'clientlog' && method === 'POST') {
    const body = await readBody(req);
    const row = {
      id: uid('err'),
      kind: str(body.kind, 30), text: str(body.text, 4000), stack: str(body.stack, 6000),
      lang: str(body.lang, 8), app: str(body.app, 20),
      ip: clientInfo(req).ip,
      user: (currentUser(req) || {}).username || '',
      at: str(body.at, 30) || now()
    };
    try {
      fs.appendFileSync(path.join(DATA_DIR, 'client-errors.jsonl'), JSON.stringify(row) + '\n', 'utf8');
    } catch (err) { /* 写不了就算了，别把崩溃变成第二个崩溃 */ }
    console.log('[崩溃上报] ' + row.kind + ' ' + row.text.slice(0, 200));
    ok(res, { logged: true });
    return;
  }

  /* ------------------------------------------------ 客服中心（用户侧）
     App「设置 → 帮助与反馈 → 客服中心」用：常见问题（后台可改）+ 在线客服（转人工）+ 我的工单 */
  if (parts[0] === 'support' && method === 'GET') {
    const me = currentUser(req);
    const cfg = readSupport();
    const agent = supportAgent();
    ok(res, {
      title: cfg.title || '客服中心',
      searchHint: cfg.searchHint || '',
      human: cfg.human !== 0,
      ticketOn: cfg.ticketOn !== 0,
      phone: cfg.phone || '',
      email: cfg.email || '',
      workTime: cfg.workTime || '',
      greet: cfg.greet || '',
      ticketHint: cfg.ticketHint || '',
      categories: (cfg.categories || []).map((c) => ({
        id: c.id || '',
        title: c.title || '',
        icon: c.icon || '',
        items: (c.items || []).filter((it) => it && it.q).map((it) => ({ q: it.q, a: it.a || '' }))
      })).filter((c) => c.items.length),
      agent: { id: agent.id, nickname: agent.nickname || '在线客服', avatar: agent.avatar || '' },
      tickets: readSupportTickets(50, me.id)
    });
    return;
  }

  /* 提交问题 → 生成一张工单（后台「客服中心 → 工单」里能看能回） */
  if (parts[0] === 'support' && parts[1] === 'ticket' && method === 'POST') {
    const me = currentUser(req);
    const cfg = readSupport();
    if (cfg.ticketOn === 0) return fail(res, 403, '暂时不能提交问题，先用在线客服');
    const body = await readBody(req);
    const content = str(body.content, 1000).trim();
    if (!content) return fail(res, 422, '把遇到的问题写一句再提交');
    const ticket = {
      id: uid('tk'),
      userId: me.id,
      username: me.username || '',
      nickname: me.nickname || '',
      category: str(body.category, 30) || '其它问题',
      title: str(body.title, 60) || content.slice(0, 24),
      content: content,
      contact: str(body.contact, 60) || '',
      status: 'pending',            // pending 待处理 / done 已处理
      reply: '',
      createdAt: now(),
      repliedAt: '',
      doneAt: ''
    };
    appendSupportTicket(ticket);
    ok(res, { ticket, tickets: readSupportTickets(50, me.id) });
    return;
  }

  /* 转人工：和「在线客服」开一个会话（已有就直接用），第一条自动发欢迎语 */
  if (parts[0] === 'support' && parts[1] === 'human' && method === 'POST') {
    const me = currentUser(req);
    const cfg = readSupport();
    if (cfg.human === 0) return fail(res, 403, '在线客服暂时没开，先看看常见问题');
    const agent = supportAgent();
    const chat = supportChatFor(me.id);
    let msgs = [];
    try { msgs = loadMessages(chat.id); } catch (e) { msgs = []; }
    if (!msgs.length && cfg.greet) {
      try { deliverMessage(agent, chat.id, 'text', cfg.greet, null); } catch (e) { }
    }
    ok(res, {
      chatId: chat.id,
      agent: { id: agent.id, nickname: agent.nickname || '在线客服', avatar: agent.avatar || '' }
    });
    return;
  }

  /* 二维码：/api/qr?text=xxx 直接回一段 SVG（群二维码、授权登录都用它） */
  if (parts[0] === 'qr' && method === 'GET') {
    const text = str(query.get('text'), 300);
    if (!text) return fail(res, 422, '缺少 text');
    const svg = QR.svg(text, Number(query.get('scale')) || 6);
    if (!svg) return fail(res, 422, '内容太长，二维码放不下');
    const enc = QR.encode(text);
    ok(res, {
      svg: svg, text: text,
      rows: enc ? enc.modules.map((r) => r.join('')) : [], size: enc ? enc.size : 0
    });
    return;
  }
  // 前端资源版本号（手机端定时比对，发现变了就自动刷新，省得手动清缓存）
  if (parts[0] === 'version' && method === 'GET') { ok(res, { version: assetVersion() }); return; }

  // 手机访问用的局域网地址（登录页也要用，所以不校验登录）
  if (parts[0] === 'lan' && method === 'GET') {
    const urls = [];
    try {
      const nets = os.networkInterfaces();
      Object.keys(nets).forEach((name) => {
        (nets[name] || []).forEach((n) => {
          if (n.family === 'IPv4' && !n.internal) urls.push({ name, ip: n.address, url: 'http://' + n.address + ':' + PORT + '/' });
        });
      });
    } catch (err) { /* 忽略 */ }
    ok(res, { port: PORT, urls });
    return;
  }

  // 界面配置公开：登录页也要用它来显示自定义图标和应用名
  if (parts[0] === 'branding' && method === 'GET') {
    /* ICE 配置里可以写 __HOST__ 占位符：出站时换成服务器自己的局域网地址，
       这样内置 TURN 的地址永远对（换网络/换机器都不用改配置）。 */
    const b = Object.assign({}, db.branding);
    if (b.iceServers && String(b.iceServers).indexOf('__HOST__') >= 0) {
      b.iceServers = String(b.iceServers).replace(/__HOST__/g, primaryLanIp());
    }
    /* 登录滑动验证开着没：客户端按它决定要不要先让用户拖滑块
       （关掉的开关在 data/security.json 的 sliderLogin） */
    b.sliderLogin = !!secCfg().sliderLogin;
    /* 通话通道模式：trtc（腾讯云，默认）／self（我们自己的 WebRTC + 自建转发兜底） */
    b.callMode = callMode();
    ok(res, { branding: b });
    return;
  }

  /* App 的「界面配置」：改 data/ui.json 里的数字/颜色，App 重开一次就生效，不用重装。
     每次请求都重新读文件，所以改完不用重启服务。 */
  /* 红点提醒配置（App 底栏和列表行按它显示） */
  if (parts[0] === 'badges' && method === 'GET') {
    ok(res, { badges: db.badges || BADGE_DEFAULT });
    return;
  }

  if (parts[0] === 'ui' && method === 'GET') {
    let ui = {};
    try {
      ui = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'ui.json'), 'utf8')) || {};
    } catch (err) { ui = {}; }
    /* UI 图标的自定义（后台「UI 图标」页换过的）：App 一打开就拉一份，直接用新的 */
    let icons = {};
    try {
      icons = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'icons.json'), 'utf8')) || {};
    } catch (err) { icons = {}; }
    ok(res, { ui, icons });
    return;
  }

  /* 手机端把「真实量到的尺寸」报回来，方便对着参考图校准（只写 data/measure.json） */
  /* ---------------- 附近的人：报位置 ---------------- */
  if (parts[0] === 'nearby' && parts.length === 1 && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    if (!isFinite(lat) || !isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      return fail(res, 422, '定位不合法');
    }
    const map = loadNearby();
    map[user.id] = { lat: lat, lng: lng, at: Date.now(), visible: body.visible !== false };
    pruneNearby();
    saveNearby();
    ok(res, { located: true });
    return;
  }

  /* ---------------- 附近的人：名单 ---------------- */
  /* 清除自己的位置（微信那个「清除位置信息并退出」）：直接从名单里消失 */
  if (parts[0] === 'nearby' && parts.length === 1 && method === 'DELETE') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const map = loadNearby();
    if (map[user.id]) { delete map[user.id]; saveNearby(); }
    ok(res, { cleared: true });
    return;
  }

  if (parts[0] === 'nearby' && parts.length === 1 && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const lat = Number(query.get('lat'));
    const lng = Number(query.get('lng'));
    const gender = String(query.get('gender') || 'all');
    const limit = Math.min(80, Number(query.get('limit')) || 60);
    /* 默认只看 5 公里；客户端想放宽（比如 5 公里没人）可以传 maxKm=20 */
    const maxRaw = Number(query.get('maxKm'));
    const maxKm = (isFinite(maxRaw) && maxRaw >= 0.5) ? Math.min(100, maxRaw) : NEARBY_MAX_KM;
    const map = loadNearby();
    pruneNearby();
    /* 自己的位置：优先用请求里带的（刚定位完更准），没有就用上次上报的 */
    const mine = (isFinite(lat) && isFinite(lng))
      ? { lat: lat, lng: lng }
      : (map[user.id] ? { lat: map[user.id].lat, lng: map[user.id].lng } : null);
    const friends = new Set(friendIds(user.id));
    const rows = [];
    Object.keys(map).forEach((id) => {
      if (id === user.id) return;
      const rec = map[id];
      const u = findUser(id);
      if (!u || u.banned || u.bot || rec.visible === false) return;
      if ((gender === 'male' || gender === 'female') && (u.gender || 'male') !== gender) return;
      const km = mine ? nearbyKm(mine, rec) : null;
      rows.push({ u: u, km: km, at: rec.at });
    });
    rows.sort((a, b) => (a.km == null ? 1e9 : a.km) - (b.km == null ? 1e9 : b.km));
    const near = rows.filter((x) => x.km == null || x.km <= maxKm);
    /* 5 公里内没人时，顺手算一下 20 公里内有几个，好让客户端提示「扩大范围」 */
    const wider20 = rows.filter((x) => x.km != null && x.km <= 20).length;
    ok(res, {
      me: mine ? { lat: mine.lat, lng: mine.lng } : null,
      maxKm: maxKm,
      wider: wider20,
      people: near.slice(0, limit).map((x) => ({
        id: x.u.id,
        nickname: x.u.nickname || x.u.username || '附近的人',
        avatar: x.u.avatar || '',
        gender: x.u.gender || '',
        region: x.u.region || '',
        bio: x.u.bio || '',
        moodText: x.u.moodText || '',
        moments: (db.moments || []).filter((m) => m.authorId === x.u.id && m.status !== 'pending').length,
        online: connections.has(x.u.id),
        friend: friends.has(x.u.id),
        km: x.km == null ? null : Math.round(x.km * 10) / 10,
        minutes: Math.max(0, Math.round((Date.now() - x.at) / 60000))
      }))
    });
    return;
  }

  /* ---------------- 附近的人：打招呼（发一条消息，会话就出来了） ---------------- */
  /* ---------------- 摇一摇：摇一下，找同时在摇的人 ---------------- */
  /* 通话诊断：App 连不上时把 ICE 状态报回来，写进 call-trace.log，方便查「一直正在接通」 */
  if (parts[0] === 'call-diag' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    callTrace('diag ' + (user.nickname || user.username) + '：' + str(body.text, 400));
    ok(res, { saved: true });
    return;
  }

  /* ---------------- 直播专场：房间列表 / 进房间 / 弹幕 / 点赞 ----------------
     没有真视频（内网演示服跑不动推流），但「谁在看、谁在说话、多少赞」都是真的：
     进房间会记人数，弹幕和点赞通过长连接实时广播给同房间的人。 */
  if (parts[0] === 'live' && parts.length === 1 && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const cfg = readJson(path.join(DATA_DIR, 'live.json'), { rooms: [] });
    const rooms = (cfg.rooms || []).map((r) => {
      const host = findUser(r.host) || db.users.find((u) => (u.nickname || '') === r.host);
      const watching = liveViewers.get(r.id);
      return {
        id: r.id, title: r.title, tag: r.tag || '', cover: r.cover || '',
        status: r.status === 'live' ? 'live' : 'soon',
        hot: Number(r.hot) || 0,
        watching: watching ? watching.size : 0,
        likes: liveLikes.get(r.id) || 0,
        /* 有没有人在真推流（有就能看实时画面） */
        hostId: liveHosts.get(r.id) || '',
        streaming: !!liveHosts.get(r.id),
        host: {
          id: host ? host.id : '',
          name: (host && host.nickname) || r.host || '主播',
          avatar: (host && host.avatar) || ''
        }
      };
    });
    ok(res, { rooms: rooms });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'join' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    if (!liveViewers.has(id)) liveViewers.set(id, new Set());
    const set = liveViewers.get(id);
    set.add(user.id);
    liveBroadcast(id, { type: 'live', action: 'count', roomId: id, watching: set.size });
    ok(res, { roomId: id, watching: set.size });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'leave' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    const set = liveViewers.get(id);
    if (set) {
      set.delete(user.id);
      liveBroadcast(id, { type: 'live', action: 'count', roomId: id, watching: set.size });
    }
    ok(res, { left: true });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'danmaku' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    const body = await readBody(req);
    const text = str(body.text, 80);
    if (!text) return fail(res, 422, '说点什么吧');
    const word = sensitiveHit(text);
    if (word) {
      recordViolation(user, null, text, word);
      return fail(res, 422, '这条弹幕里有敏感词，换个说法吧');
    }
    liveBroadcast(id, {
      type: 'live', action: 'danmaku', roomId: id,
      from: user.nickname || user.username, fromId: user.id, text: text, at: now()
    });
    ok(res, { sent: true });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'like' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    liveLikes.set(id, (liveLikes.get(id) || 0) + 1);
    liveBroadcast(id, { type: 'live', action: 'like', roomId: id, likes: liveLikes.get(id), from: user.nickname || '' });
    ok(res, { likes: liveLikes.get(id) });
    return;
  }

  /* ---------------- 游戏页：只发列表，玩法在客户端 ---------------- */
  /* 读某条视频的评论列表（客户端点开评论面板时用）。
     注意：必须放在下面的 feed GET 之前 —— 那个路由不校验子路径，
     放后面的话 /api/feed/comments 会被当成"拉推荐流"。 */
  if (parts[0] === 'feed' && parts[1] === 'comments' && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(query.get('id'), 40);
    if (!id) return fail(res, 422, '缺少 id');
    const f0 = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
    const it0 = (f0.posts || []).concat(f0.items || []).find((x) => x.id === id);
    if (!it0) return fail(res, 404, '这条视频不在了');
    const list0 = (Array.isArray(it0.comments) ? it0.comments : []).map((c) => {
      const u = c.userId ? findUser(c.userId) : null;
      return {
        id: c.id,
        userId: c.userId || '',
        name: (u && u.nickname) || c.name || '用户',
        avatar: (u && u.avatar) || '',
        text: c.text || '',
        at: c.at || ''
      };
    }).reverse();                      // 新的在上面
    ok(res, { comments: list0, count: list0.length + (Number(it0.baseComments) || 0) });
    return;
  }

  /* 取一整套短剧的全部集数（客户端「选集」面板用）。
     剧集可能被拆在不同的推荐批次里，所以这里直接按剧集 id 捞全。 */
  if (parts[0] === 'feed' && parts[1] === 'series' && method === 'GET') {
    const userS = currentUser(req);
    if (!userS) return fail(res, 401, '请先登录');
    const sid = str(query.get('id'), 60);
    if (!sid) return fail(res, 422, '缺少 id');
    const fs0 = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
    const epsAll = (fs0.items || []).concat(fs0.posts || []).filter((x) => String(x.series || '') === sid);
    const epNum = (x) => { const m = String(x.ep || '').match(/([0-9]+)/); return m ? Number(m[1]) : 999; };
    epsAll.sort((a, b) => epNum(a) - epNum(b));
    ok(res, {
      series: sid,
      name: (epsAll[0] && epsAll[0].seriesName) || '',
      items: epsAll.map((it) => feedItemOut(it, userS))
    });
    return;
  }

  /* ---------------- 视频号（抖音式竖屏 feed） ----------------
     items = 后台内置的（data/feed.json），posts = 用户自己发的；
     点赞/评论都落在同一个文件里，重启不丢。 */
  if (parts[0] === 'feed' && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const f = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
    /* mine=1：只要自己发布的作品（「我 → 作品」那一页用），后台内置的那些不算作品 */
    const onlyMine = query.get('mine') === '1';
    /* 三个 tab（和微信视频号一致）：
         recommend 推荐 —— 抖音那套：全部作品按「热度 + 新鲜度」打分，每次刷新顺序会变
         follow    关注 —— 我关注的人（这里=我的好友）发的作品，按时间倒序
         friends   朋友 —— 我的好友点过赞的作品（微信「朋友」就是这个逻辑） */
    const tab = str(query.get('tab'), 12) || (onlyMine ? '' : 'recommend');
    const myFriends = new Set(friendIds(user.id));
    const mineOnly = onlyMine
      ? (f.posts || []).filter((it) => it.authorId === user.id)
      : null;
    let all;
    if (mineOnly) {
      all = mineOnly;
    } else if (tab === 'follow') {
      /* 关注：真的关注表（feed-follows.json）里那些人发的作品。
         一条都没关注过的时候，退回「好友发的」——不然这个 tab 是空的，看着像坏了。 */
      const followed = myFeedFollows(user.id);
      if (followed.length) {
        const set = new Set(followed);
        all = (f.posts || []).filter((it) => it.authorId && set.has(it.authorId));
      } else {
        all = (f.posts || []).filter((it) => it.authorId && myFriends.has(it.authorId));
      }
      all.sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
    } else if (tab === 'friends') {
      all = (f.posts || []).filter((it) => (it.likedBy || []).some((id) => myFriends.has(id)));
      all.sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
    } else {
      /* 推荐：抖音那套「千人千面」——兴趣 / 社交 / 负反馈 / 多样性 / 探索 */
      all = rankFeedFor(user, (f.posts || []).concat(f.items || []), myFriends);
    }
    const out = all.map((it) => feedItemOut(it, user));
    const cfg0 = readJson(path.join(DATA_DIR, 'feed.json'), {});
    ok(res, {
      items: out,
      style: Object.assign({}, FEED_STYLE_DEFAULT, cfg0.style || {}),
      flags: Object.assign({}, FEED_FLAGS_DEFAULT, cfg0.flags || {})
    });
    return;
  }

  /* 视频号：关注 / 取消关注（真的关注表，和好友关系分开） */
  if (parts[0] === 'feed' && parts[1] === 'follow' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    if (target.id === user.id) return fail(res, 422, '不能关注自己');
    const dbm = readFeedFollows();
    const on = body.follow !== false;
    const idx = dbm.follows.findIndex((f) => f.fromId === user.id && f.toId === target.id);
    if (on && idx < 0) dbm.follows.push({ fromId: user.id, toId: target.id, at: now() });
    if (!on && idx >= 0) dbm.follows.splice(idx, 1);
    feedFollowCache = dbm;
    saveFeedFollows();
    ok(res, { following: on, count: myFeedFollows(user.id).length });
    return;
  }

  if (parts[0] === 'feed' && parts[1] === 'like' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const list = (f.posts || []).concat(f.items || []);
    const it = list.find((x) => x.id === id);
    if (!it) return fail(res, 404, '这条视频不在了');
    const likedBy = Array.isArray(it.likedBy) ? it.likedBy : [];
    const i = likedBy.indexOf(user.id);
    if (i >= 0) likedBy.splice(i, 1); else likedBy.push(user.id);
    it.likedBy = likedBy;
    writeJson(file, f);
    ok(res, { liked: i < 0, likes: likedBy.length + (Number(it.baseLikes) || 0) });
    return;
  }

  /* 收藏：和点赞一样，谁收藏了记在条目里（savedBy），可以取消 */
  if (parts[0] === 'feed' && parts[1] === 'favorite' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const list = (f.posts || []).concat(f.items || []);
    const it = list.find((x) => x.id === id);
    if (!it) return fail(res, 404, '这条视频不在了');
    const savedBy = Array.isArray(it.savedBy) ? it.savedBy : [];
    const i = savedBy.indexOf(user.id);
    if (i >= 0) savedBy.splice(i, 1); else savedBy.push(user.id);
    it.savedBy = savedBy;
    writeJson(file, f);
    ok(res, { favorited: i < 0, favorites: savedBy.length });
    return;
  }

  if (parts[0] === 'feed' && parts[1] === 'comment' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const text = str(body.text, 120);
    if (!text) return fail(res, 422, '说点什么吧');
    const word = sensitiveHit(text);
    if (word) { recordViolation(user, null, text, word); return fail(res, 422, '这条评论里有敏感词'); }
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const list = (f.posts || []).concat(f.items || []);
    const it = list.find((x) => x.id === id);
    if (!it) return fail(res, 404, '这条视频不在了');
    it.comments = Array.isArray(it.comments) ? it.comments : [];
    it.comments.push({ id: uid('fc'), userId: user.id, name: user.nickname || user.username, text: text, at: now() });
    if (it.comments.length > 200) it.comments = it.comments.slice(-200);
    writeJson(file, f);
    ok(res, { comments: it.comments.length + (Number(it.baseComments) || 0), text: text });
    return;
  }

  /* 用户自己发视频：先把视频/封面传到 /api/upload，再把地址发到这里 */
  if (parts[0] === 'feed' && parts[1] === 'publish' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    let video = str(body.video, 300);
    let cover = str(body.cover, 300);
    const desc = str(body.desc, 120) || '分享一条视频';
    const music = str(body.music, 60);
    if (!video || video.indexOf('/uploads/') !== 0) return fail(res, 422, '视频还没传上来');
    /* 压成「手机上刷得动」的规格：最长边 720、约 1.2Mbps、30fps、GOP 2 秒、
       H.264 High、AAC 96k、faststart（moov 放最前面，播放器不用整包下完才能出画面）。
       以前这段是 spawnSync + 直接读上传目录 —— 上传目录是密文，ffmpeg 根本读不了，
       等于从来没生效；而且 spawnSync 会把整个服务卡住几十秒（所有人一起转圈）。
       现在：先解到临时明文文件再转，异步跑（不占事件循环），顺手补一张封面。 */
    const srcName = path.basename(video);
    const srcPath = path.join(UPLOAD_DIR, srcName);
    let finalVideo = video;
    if (fs.existsSync(srcPath)) {
      const ff2 = process.env.FFMPEG_PATH || 'C:/Users/Administrator/ffmpeg/bin/ffmpeg.exe';
      const probeFf = ff2.replace(/ffmpeg(\.exe)?$/i, 'ffprobe$1');
      const tmpSrc = uploadTempPlain(srcName);
      const rawSizeMB = fs.statSync(tmpSrc).size / 1024 / 1024;
      const outTmp = tmpSrc + '.small.mp4';
      const args2 = ['-y', '-loglevel', 'error', '-i', tmpSrc,
        '-vf', "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'",
        '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'veryfast',
        '-b:v', '1200k', '-maxrate', '1500k', '-bufsize', '3000k',
        '-r', '30', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
        '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k', '-ac', '1',
        '-movflags', '+faststart', outTmp];
      /* 上传来的时候已经被压过一遍（≤2.2MB）就别再压一次：白费 CPU 还掉画质 */
      if (fs.statSync(tmpSrc).size > 2.2 * 1024 * 1024) {
        const rr = await runFfAsync(ff2, args2, 180000);
        if (rr.ok && fs.existsSync(outTmp)) {
          finalVideo = '/uploads/' + saveUploadPlain(fs.readFileSync(outTmp), '.mp4');
          callTrace('视频号转码 ' + srcName + ' (' + rawSizeMB.toFixed(1) + 'MB) → '
            + String(finalVideo) + ' (' + Math.round(fs.statSync(outTmp).size / 1024) + 'KB, 1.2Mbps, 长边≤1280)');
        } else {
          callTrace('视频号转码失败，用原文件：' + String(rr.err || '').slice(0, 120));
        }
      }
      /* 没带封面就抽第一帧当封面：手机上先看到图，不用等视频 */
      if (!cover) {
        const cTmp = tmpSrc + '.cover.jpg';
        const cr = await runFfAsync(ff2, ['-y', '-loglevel', 'error', '-ss', '0.3', '-i', tmpSrc,
          '-frames:v', '1', '-vf', 'scale=576:-2', '-q:v', '6', cTmp], 30000);
        if (cr.ok && fs.existsSync(cTmp)) {
          cover = '/uploads/' + saveUploadPlain(fs.readFileSync(cTmp), '.jpg');
        }
        try { fs.unlinkSync(cTmp); } catch (err) { }
      }
      try { fs.unlinkSync(outTmp); } catch (err) { }
      try { fs.unlinkSync(tmpSrc); } catch (err) { }
    }
    video = finalVideo;
    const word = sensitiveHit(desc);
    if (word) { recordViolation(user, null, desc, word); return fail(res, 422, '文案里有敏感词'); }
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    f.posts = Array.isArray(f.posts) ? f.posts : [];
    const post = {
      id: uid('v'), authorId: user.id, video: video, cover: cover,
      desc: desc, music: music, createdAt: now(),
      likedBy: [], comments: [], baseLikes: 0, baseComments: 0, baseShares: 0
    };
    f.posts.unshift(post);
    if (f.posts.length > 200) f.posts = f.posts.slice(0, 200);
    writeJson(file, f);
    /* 新视频进 feed 了：几秒后自动补一遍 HLS 分片（异步，不挡这次请求）。
       少了这一步，视频号就会退化成「整包下 mp4」——线上真出过：
       两条视频没有 hls 字段，客户端只能下 5.2MB / 3.6Mbps 的原片，看视频一直卡。 */
    scheduleHlsBuild();
    ok(res, { id: post.id, video: video });
    return;
  }

  /* 删自己发的那条 */
  /* 剪水印：把带水印的那一条边裁掉（ffmpeg 重编码），返回新地址。
     参数是比例：top/bottom/left/right = 0~0.4，比如底部水印就传 bottom:0.12。
     fill = 1 时裁完再放大回原尺寸（画面不缩小，只是看的内容变了）。 */
  if (parts[0] === 'feed' && parts[1] === 'trim' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const rel = str(body.url, 200);
    if (rel.indexOf('/uploads/') !== 0) return fail(res, 422, '视频地址不对');
    const name = path.basename(rel);
    const src = path.join(UPLOAD_DIR, name);
    if (!fs.existsSync(src)) return fail(res, 404, '视频不在了');
    const clamp = (v) => Math.max(0, Math.min(0.4, Number(v) || 0));
    const top = clamp(body.top), bottom = clamp(body.bottom);
    const left = clamp(body.left), right = clamp(body.right);
    if (top + bottom >= 0.8 || left + right >= 0.8) return fail(res, 422, '裁得太多了');
    if (!top && !bottom && !left && !right) return fail(res, 422, '没说要裁哪一边');
    const ff = process.env.FFMPEG_PATH || 'C:/Users/Administrator/ffmpeg/bin/ffmpeg.exe';
    const probeFf2 = ff.replace(/ffmpeg(\.exe)?$/i, 'ffprobe$1');
    /* 上传目录里是密文，ffmpeg 读不了 —— 先解到临时明文文件再剪（异步，不卡服务） */
    const tmpSrc = uploadTempPlain(name);
    const outTmp = tmpSrc + '.trim.mp4';
    const crop = 'crop=iw*(1-' + (left + right).toFixed(4) + '):ih*(1-' + (top + bottom).toFixed(4)
      + '):iw*' + left.toFixed(4) + ':ih*' + top.toFixed(4);
    /* 用 crop 的表达式算出裁剪后的真实尺寸，再决定要不要缩回原尺寸 */
    const probe = spawnSync(probeFf2,
      ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height',
        '-of', 'csv=p=0', tmpSrc], { encoding: 'utf8' });
    const dim = (probe.stdout || '').trim().split(',');
    const W = Number(dim[0]) || 720, H = Number(dim[1]) || 1280;
    const cw = Math.round(W * (1 - left - right));
    const ch = Math.round(H * (1 - top - bottom));
    const vf = (body.fill === false)
      ? crop
      : crop + ',scale=' + W + ':' + H;
    const args = ['-y', '-loglevel', 'error', '-i', tmpSrc, '-vf', vf,
                  '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '26', '-preset', 'veryfast'];
    /* 有音轨就保留 */
    const hasAudio = spawnSync(probeFf2,
      ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=codec_type',
        '-of', 'csv=p=0', tmpSrc], { encoding: 'utf8' }).stdout.indexOf('audio') >= 0;
    if (hasAudio) args.push('-c:a', 'aac', '-b:a', '96k');
    args.push('-movflags', '+faststart', outTmp);
    const r = await runFfAsync(ff, args, 180000);
    if (!r.ok || !fs.existsSync(outTmp)) {
      callTrace('剪水印失败：' + String(r.err || '').slice(0, 200));
      try { fs.unlinkSync(tmpSrc); } catch (err) { }
      return fail(res, 500, '剪的时候出错了，换个视频试试');
    }
    const outName = saveUploadPlain(fs.readFileSync(outTmp), '.mp4');
    try { fs.unlinkSync(outTmp); } catch (err) { }
    try { fs.unlinkSync(tmpSrc); } catch (err) { }
    callTrace('剪水印 ' + name + ' → ' + outName + ' 裁掉 ' + JSON.stringify({ top, bottom, left, right }) + ' 新尺寸 ' + cw + 'x' + ch);
    ok(res, { url: '/uploads/' + outName, width: cw, height: ch });
    return;
  }

  if (parts[0] === 'feed' && parts.length === 2 && method === 'DELETE') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const before = (f.posts || []).length;
    f.posts = (f.posts || []).filter((x) => !(x.id === str(parts[1], 40) && x.authorId === user.id));
    writeJson(file, f);
    ok(res, { removed: before - f.posts.length });
    return;
  }

  if (parts[0] === 'games' && method === 'GET') {
    const cfg = readJson(path.join(DATA_DIR, 'games.json'), { items: [] });
    ok(res, { items: (cfg.items || []).filter((x) => x.enabled !== false) });
    return;
  }

  if (parts[0] === 'shake' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    const me = (isFinite(lat) && isFinite(lng)) ? { lat: lat, lng: lng } : null;
    const map = pruneShakes();
    const mine = map[user.id] || { at: 0 };
    const seen = Array.isArray(mine.seen) ? mine.seen : [];
    const nowTs = Date.now();
    /* 同时在摇的人：30 秒内摇过、不是我、没被我摇到过 */
    const pool = Object.keys(map).filter((id) => id !== user.id)
      .filter((id) => map[id].at > nowTs - SHAKE_TTL_MS)
      .filter((id) => !seen.some((s) => s.id === id && nowTs - s.at < SHAKE_AGAIN_MS))
      .map((id) => {
        const u = findUser(id);
        const rec = map[id];
        let km = null;
        if (me && isFinite(rec.lat) && isFinite(rec.lng)) {
          km = nearbyKm(me, { lat: rec.lat, lng: rec.lng });
        } else if (map[user.id] && isFinite(map[user.id].lat)) {
          km = nearbyKm({ lat: map[user.id].lat, lng: map[user.id].lng }, { lat: rec.lat, lng: rec.lng });
        }
        return { u: u, km: km, at: rec.at };
      })
      .filter((x) => x.u && !x.u.banned && !x.u.bot);
    /* 近的先摇到；都没定位就随机 */
    pool.sort((a, b) => {
      const ka = a.km == null ? 1e9 : a.km;
      const kb = b.km == null ? 1e9 : b.km;
      if (ka === kb) return Math.random() - 0.5;
      return ka - kb;
    });
    const hit = pool[0] || null;
    const mySeen = seen.filter((s) => nowTs - s.at < SHAKE_AGAIN_MS);
    if (hit) mySeen.push({ id: hit.u.id, at: nowTs });
    map[user.id] = {
      at: nowTs,
      lat: isFinite(lat) ? lat : (mine.lat || null),
      lng: isFinite(lng) ? lng : (mine.lng || null),
      seen: mySeen.slice(-40)
    };
    saveShakes();
    if (!hit) {
      return ok(res, { matched: null, shaking: Object.keys(map).length });
    }
    const u = hit.u;
    ok(res, {
      matched: {
        id: u.id,
        nickname: u.nickname || u.username || '某人',
        avatar: u.avatar || '',
        gender: u.gender || '',
        region: u.region || '',
        bio: u.bio || '',
        moodText: u.moodText || '',
        online: connections.has(u.id),
        friend: friendIds(user.id).includes(u.id),
        km: hit.km == null ? null : Math.round(hit.km * 10) / 10
      },
      shaking: Object.keys(map).length
    });
    return;
  }

  if (parts[0] === 'nearby' && parts[1] === 'hello' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '这个人已经不在附近了');
    if (target.id === user.id) return fail(res, 422, '不能给自己打招呼');
    const text = str(body.text, 60) || '你好呀，我是在附近的人里看到你的';
    let chat = directChatBetween(user.id, target.id);
    if (!chat) {
      chat = createDirectChat(user.id, target.id);
      sendTo(target.id, { type: 'chat', action: 'created', chat: chatSummary(chat, target.id) });
    }
    const result = deliverMessage(user, chat.id, 'text', text, null);
    if (result && result.error) return fail(res, 422, result.error);
    ok(res, { chatId: chat.id, text: text });
    return;
  }

  if (parts[0] === 'measure' && method === 'POST') {
    const body = await readBody(req);
    const file = path.join(DATA_DIR, 'measure.json');
    let list = [];
    try { list = JSON.parse(fs.readFileSync(file, 'utf8')) || []; } catch (err) { list = []; }
    list.push(Object.assign({ at: now() }, body));
    if (list.length > 400) list = list.slice(-400);
    writeJson(file, list);
    ok(res, { saved: true });
    return;
  }

  // 聊天输入栏「＋」面板（手机版启动时就拉这份配置）
  if (parts[0] === 'plus-panel' && method === 'GET') {
    ok(res, { items: db.plusPanel });
    return;
  }

  /* 发现页的行：后台加/删/改，前端（网页版和 App）每次打开都拉一次。
     图标分两种：icon 写 UI 图标页里的 key（后台换过图标就用换过的），
     或者直接给一段 svg。两者都没有就留空，前端只显示文字。 */
  if (parts[0] === 'discover' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    const items = (db.discover || [])
      .filter((it) => it.enabled !== false)
      .map((it) => Object.assign({}, it, {
        svg: it.svg || overrides[it.icon] || builtin[it.icon] || ''
      }));
    ok(res, { items, version: assetVersion() });
    return;
  }

  /* 我页的行：和发现页一套机制（后台加/删/改，前端每次进来拉一次） */
  if (parts[0] === 'me-page' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    const items = (db.mePage || [])
      .filter((it) => it.enabled !== false)
      .map((it) => Object.assign({}, it, {
        svg: it.svg || overrides[it.icon] || builtin[it.icon] || ''
      }));
    ok(res, { items, version: assetVersion() });
    return;
  }

  /* 服务页（我 → 服务）：整页都由后台配（绿卡 + 分类 + 格子），
     前端每次进来拉一次，后台改完切回前台就生效。 */
  if (parts[0] === 'service' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    const svgOf = (icon, own) => own || overrides[icon] || builtin[icon] || '';
    const cfg = db.service || normalizeService(null);
    const card = cfg.card || {};
    const half = (h) => Object.assign({}, h, { svg: svgOf(h && h.icon, h && h.svg) });
    const groups = (cfg.groups || [])
      .filter((g) => g.enabled !== false)
      .map((g) => Object.assign({}, g, {
        items: (g.items || [])
          .filter((it) => it.enabled !== false)
          .map((it) => Object.assign({}, it, { svg: svgOf(it.icon, it.svg) }))
      }))
      .filter((g) => g.items.length);
    ok(res, {
      title: cfg.title || '服务',
      card: { enabled: card.enabled !== false, bg: card.bg || '#2AAE67', left: half(card.left), right: half(card.right) },
      bottom: cfg.bottom || normalizeService(null).bottom,
      style: cfg.style || normalizeService(null).style,
      groups: groups,
      version: assetVersion()
    });
    return;
  }

  /* 钱包页（我 → 服务 → 钱包）：整页也由后台配。
     零钱那一行的数值支持「跟余额」：valueKind = balance 就现算这个人的零钱余额。 */
  /* 只匹配 /api/wallet 本身；子路径（banks / withdraws…）由后面各自的接口处理 */
  if (parts[0] === 'wallet' && parts.length === 1 && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    const svgOf = (icon, own) => own || overrides[icon] || builtin[icon] || '';
    const me = currentUser(req);
    const cfg = db.wallet || normalizeWallet(null);
    /* 后台把「点一下能看」也关了的话，连数值都不下发（只给 ¥****），前端想看也没有 */
    const hardMask = !!(cfg.style && cfg.style.maskAmount !== false && cfg.style.maskReveal === false);
    const maskMoney = (s) => {
      const t = String(s == null ? '' : s);
      if (!t) return t;
      return t.indexOf('¥') >= 0 ? '¥****' : t.replace(/[0-9]/g, '*');
    };
    const pick = (it) => {
      let value = it.valueKind === 'balance'
        ? ('¥' + (Number(me && me.balance) || 0).toFixed(2))
        : (it.value || '');
      if (hardMask && value && it.mask !== false) value = maskMoney(value);
      return Object.assign({}, it, { value: value, svg: svgOf(it.icon, it.svg) });
    };
    const groups = (cfg.groups || [])
      .filter((g) => g.enabled !== false)
      .map((g) => Object.assign({}, g, {
        items: (g.items || []).filter((it) => it.enabled !== false).map(pick)
      }))
      .filter((g) => g.items.length);
    ok(res, {
      title: cfg.title || '钱包',
      right: cfg.right,
      groups: groups,
      footer: (cfg.footer || []).filter((f) => f.enabled !== false),
      style: cfg.style || normalizeWallet(null).style,
      balance: Number(me && me.balance) || 0,
      version: assetVersion()
    });
    return;
  }

  /* 账单：这个人所有的转账（钱包页右上角「账单」用）。
     带上对方是谁（名字/头像）、进出方向、状态、时间，再给一份汇总和月份列表。 */
  if (parts[0] === 'bills' && method === 'GET') {
    const me = currentUser(req);
    const limit = Math.min(200, Math.max(1, Number(query.get('limit')) || 100));
    const month = str(query.get('month'), 7);          // 形如 2026-09，不传就是全部
    let all = (db.transfers || [])
      .filter((t) => t && (t.fromId === me.id || t.toId === me.id))
      .map((t) => {
        const mine = t.fromId === me.id;
        const other = findUser(mine ? t.toId : t.fromId) || {};
        return {
          id: t.id,
          chatId: t.chatId || '',
          amount: Number(t.amount) || 0,
          note: t.note || '',
          method: t.method || 'balance',
          status: t.status || 'pending',
          createdAt: t.createdAt || '',
          expiresAt: t.expiresAt || 0,
          receivedAt: t.receivedAt || '',
          refundedAt: t.refundedAt || '',
          direction: mine ? 'out' : 'in',
          peerId: other.id || '',
          peerName: other.nickname || '好友',
          peerAvatar: other.avatar || ''
        };
      })
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
    /* 零钱的充值 / 提现也一起进账单（微信的账单里这些都有） */
    const walletBills = readWalletOps().ops
      .filter((o) => o.userId === me.id)
      .map((o) => ({
        id: o.id,
        chatId: '',
        amount: Number(o.amount) || 0,
        note: o.kind === 'recharge' ? '充值' : '提现',
        method: 'balance',
        status: o.status === 'done' ? 'received' : (o.status === 'failed' ? 'refunded' : 'pending'),
        createdAt: o.createdAt || '',
        expiresAt: 0,
        receivedAt: o.doneAt || '',
        refundedAt: '',
        direction: o.kind === 'recharge' ? 'in' : 'out',
        peerId: '',
        peerName: o.bankText || '银行卡',
        peerAvatar: '',
        walletKind: o.kind,
        fee: Number(o.fee) || 0
      }));
    /* 红包也进账单：发出去的算支出、抢到的算收入、24 小时退回的算收入 */
    const rpBills = [];
    (db.redpackets || []).forEach((r) => {
      const mine = rpClaims(r).find((c) => c.userId === me.id) || null;
      const note = r.note || (r.type === 'lucky' ? '拼手气红包' : '红包');
      if (r.fromId === me.id) {
        /* 我发的红包：头像用我自己的（微信账单里这一条也是对方头像的位置放自己的） */
        rpBills.push({
          id: r.id + '-out', chatId: r.chatId, amount: Number(r.total) || 0,
          note: '发红包 · ' + note, method: 'balance', status: 'received',
          createdAt: r.createdAt, expiresAt: 0, receivedAt: r.createdAt, refundedAt: '',
          direction: 'out', peerId: '', peerName: note,
          peerAvatar: (me && me.avatar) || '',
          walletKind: 'redpacket'
        });
        if (Number(r.refundAmount) > 0 && r.refundedAt) {
          rpBills.push({
            id: r.id + '-back', chatId: r.chatId, amount: Number(r.refundAmount) || 0,
            note: '红包退回 · ' + note, method: 'balance', status: 'received',
            createdAt: r.refundedAt, expiresAt: 0, receivedAt: r.refundedAt, refundedAt: '',
            direction: 'in', peerId: '', peerName: note, peerAvatar: '',
            walletKind: 'redpacket'
          });
        }
      }
      if (mine) {
        const sender = findUser(r.fromId) || {};
        rpBills.push({
          id: r.id + '-in', chatId: r.chatId, amount: Number(mine.amount) || 0,
          note: '抢到红包 · ' + note, method: 'balance', status: 'received',
          createdAt: mine.at, expiresAt: 0, receivedAt: mine.at, refundedAt: '',
          direction: 'in', peerId: r.fromId, peerName: r.fromName || sender.nickname || '好友',
          peerAvatar: sender.avatar || '',      // 账单里要看到对方的头像
          walletKind: 'redpacket'
        });
      }
    });
    if (walletBills.length || rpBills.length) {
      all = all.concat(walletBills, rpBills)
        .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
    }
    const list = (month ? all.filter((x) => String(x.createdAt).slice(0, 7) === month) : all).slice(0, limit);
    const total = (dir, statuses) => Math.round(all
      .filter((x) => x.direction === dir && (!statuses || statuses.indexOf(x.status) >= 0))
      .reduce((a, x) => a + x.amount, 0) * 100) / 100;
    const months = [];
    all.forEach((x) => {
      const m = String(x.createdAt).slice(0, 7);
      if (/^\d{4}-\d{2}$/.test(m) && months.indexOf(m) < 0) months.push(m);
    });
    ok(res, {
      bills: list,
      months: months.slice(0, 36),
      summary: {
        out: total('out', ['pending', 'received']),
        in: total('in', ['received']),
        pendingOut: all.filter((x) => x.direction === 'out' && x.status === 'pending').length,
        pendingIn: all.filter((x) => x.direction === 'in' && x.status === 'pending').length,
        count: all.length
      },
      month: month || '',
      style: (db.billsPage || normalizeBillsPage(null)).style,
      faq: (db.billsPage || normalizeBillsPage(null)).faq,
      version: assetVersion()
    });
    return;
  }

  /* 零钱页（我 → 服务 → 钱包 → 零钱）：文案/按钮/链接都是后台配的，
     余额是这个人的真实零钱（冻结金额目前恒为 0，等有冻结逻辑再接）。 */
  if (parts[0] === 'balance-page' && method === 'GET') {
    const me = currentUser(req);
    const cfg = db.balancePage || normalizeBalancePage(null);
    ok(res, Object.assign({}, cfg, {
      balance: Number(me && me.balance) || 0,
      frozen: 0,
      version: assetVersion()
    }));
    return;
  }

  // 礼物列表（前台「礼物」面板用，只给启用的）
  if (parts[0] === 'gifts' && method === 'GET') {
    ok(res, { gifts: db.gifts.filter((g) => g.enabled) });
    return;
  }

  // 状态列表（手机端「我 → ＋ 状态」用，分类和状态都是后台配的）
  if (parts[0] === 'statuses' && parts.length === 1 && method === 'GET') {
    ok(res, { categories: db.statuses.filter((c) => c.enabled) });
    return;
  }

  // 表情包：本地表情包 + 第三方图源开关（手机端「我 → 表情」用）
  if (parts[0] === 'stickers' && parts.length === 1 && method === 'GET') {
    /* 这一段路由在「取当前用户」之前，所以自己取一次（没登录就是空的） */
    const me = currentUser(req);
    const mine = me ? myStickers(me.id) : { packs: [], singles: [], recent: [] };
    ok(res, {
      packs: db.stickers.packs.filter((p) => p.enabled),
      /* 「我的表情」：已添加的表情包（完整数据）+ 自己添加的单个表情 */
      mine: {
        packs: db.stickers.packs.filter((p) => p.enabled && mine.packs.includes(p.id)),
        singles: mine.singles,
        recent: mine.recent
      },
      thirdParty: {
        provider: db.stickers.thirdParty.provider,
        enabled: db.stickers.thirdParty.provider !== 'off'
          && (!!db.stickers.thirdParty.apiKey || !!db.stickers.thirdParty.urlTemplate),
        limit: db.stickers.thirdParty.limit
      }
    });
    return;
  }

  /* 表情：添加 / 移除（表情包或单个表情）—— 微信「我 → 表情」里那套 */
  if (parts[0] === 'stickers' && parts[1] === 'add' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const mine = myStickers(me.id);
    const packId = str(body.packId, 24);
    const single = str(body.sticker, 400);
    if (packId) {
      if (!db.stickers.packs.some((p) => p.id === packId && p.enabled)) return fail(res, 404, '没有这个表情包');
      if (!mine.packs.includes(packId)) mine.packs.push(packId);
    } else if (single) {
      if (!mine.singles.includes(single)) mine.singles.push(single);
    } else {
      return fail(res, 422, '要添加哪个表情？');
    }
    setMyStickers(me.id, mine);
    ok(res, { mine });
    return;
  }

  if (parts[0] === 'stickers' && parts[1] === 'remove' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const mine = myStickers(me.id);
    const packId = str(body.packId, 24);
    const single = str(body.sticker, 400);
    if (packId) mine.packs = mine.packs.filter((x) => x !== packId);
    if (single) {
      mine.singles = mine.singles.filter((x) => x !== single);
      mine.recent = mine.recent.filter((x) => x !== single);
    }
    setMyStickers(me.id, mine);
    ok(res, { mine });
    return;
  }

  /* 用过某个表情：记进「最近使用」（微信表情面板第一格就是最近使用） */
  if (parts[0] === 'stickers' && parts[1] === 'recent' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const single = str(body.sticker, 400);
    if (single) {
      const mine = myStickers(me.id);
      mine.recent = [single].concat(mine.recent.filter((x) => x !== single)).slice(0, 30);
      setMyStickers(me.id, mine);
    }
    ok(res, { ok: true });
    return;
  }

  /* ============================================================
     存储空间（微信「设置 → 通用 → 存储空间」）
     按会话统计聊天记录条数与占用，按类型统计图片/视频/文件/语音，
     还能清缓存（把没人引用的上传文件删掉，不会动别人还能看到的东西）。
     ============================================================ */
  if (parts[0] === 'storage' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const mine = chatsOf(me.id);
    let total = 0;
    const byKind = { image: 0, video: 0, file: 0, audio: 0 };
    const chats = mine.map((c) => {
      const msgs = loadMessages(c.id);
      let bytes = 0;
      msgs.forEach((m) => {
        const size = Buffer.byteLength(JSON.stringify(m), 'utf8');
        bytes += size;
        if (m.kind === 'image') byKind.image += size;
        else if (m.kind === 'file') {
          const isVideo = /\.(mp4|mov|m4v|avi|mkv|webm|3gp|flv|wmv)(\?|$)/i.test(String(m.content || ''));
          byKind[isVideo ? 'video' : 'file'] += size;
        } else if (m.kind === 'audio') byKind.audio += size;
      });
      total += bytes;
      return {
        chatId: c.id, title: chatSummary(c, me.id).title, avatar: c.avatar || '',
        messages: msgs.length, bytes
      };
    }).sort((a, b) => b.bytes - a.bytes);
    ok(res, {
      total, chats,
      kinds: byKind,
      /* 服务器上传目录的实际占用（全站的，给用户一个「缓存」参考值） */
      uploads: uploadDirSize()
    });
    return;
  }

  /* 清缓存：**只算不删**。
     2026-09-22 出过事故：服务器上的清理把还在用的图片/语音当成"没人引用"删掉了 91 个文件（207MB），
     所以普通用户这边只返回「能清多少」，真删只能管理员在后台点（而且只删 24 小时前、确认没人引用的）。 */
  if (parts[0] === 'storage' && parts[1] === 'clean' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    ok(res, { freed: 0, wouldFree: orphanUploadsSize(), note: '服务器上的文件不能由用户端删除' });
    return;
  }

  /* ============================================================
     共享实时位置（微信「＋ → 位置 → 共享实时位置」）
     一个会话里同时只有一个共享会话：谁进来都看得到彼此的位置，
     位置更新走长连接实时转发，「停止共享」大家一起结束。
     会话只放内存，2 小时自动过期（不做落盘，重启也没了 —— 微信也是临时会话）。
     ============================================================ */
  if (parts[0] === 'live' && parts[1] === 'start' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const chat = db.chats.find((c) => c.id === str(body.chatId, 40));
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(me.id)) return fail(res, 403, '你不在这个会话里');
    const exist = Array.from(liveLocations.values())
      .find((s) => s.chatId === chat.id && Date.now() - s.at < LIVE_LOCATION_TTL);
    const ses = exist || { id: uid('ll'), chatId: chat.id, fromId: me.id, at: Date.now(), positions: {} };
    ses.at = Date.now();
    const lat = Number(body.lat), lng = Number(body.lng);
    if (isFinite(lat) && isFinite(lng)) ses.positions[me.id] = { lat, lng, at: Date.now() };
    liveLocations.set(ses.id, ses);
    sendToChat(chat, {
      type: 'live-location', action: 'start', sessionId: ses.id, chatId: chat.id,
      fromId: me.id, fromName: me.nickname || me.username
    }, me.id);
    ok(res, { sessionId: ses.id, joined: !!exist });
    return;
  }

  /* 上报我的位置：每几秒一次，服务器转给同一会话里的其他人 */
  if (parts[0] === 'live' && parts[1] === 'pos' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const ses = liveLocations.get(str(body.sessionId, 40));
    if (!ses) return fail(res, 404, '共享已结束');
    const chat = db.chats.find((c) => c.id === ses.chatId);
    if (!chat || !chat.memberIds.includes(me.id)) return fail(res, 403, '你不在这个共享里');
    const lat = Number(body.lat), lng = Number(body.lng);
    if (!isFinite(lat) || !isFinite(lng)) return fail(res, 422, '坐标不对');
    ses.positions[me.id] = { lat, lng, at: Date.now() };
    ses.at = Date.now();
    sendToChat(chat, {
      type: 'live-location', action: 'pos', sessionId: ses.id, chatId: chat.id,
      userId: me.id, name: me.nickname || me.username, avatar: me.avatar || '',
      lat, lng
    }, me.id);
    ok(res, { ok: true });
    return;
  }

  /* 进页面先拉一次：现在这个共享里都有谁、都在哪 */
  if (parts[0] === 'live' && parts[2] === 'state' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const ses = liveLocations.get(str(parts[1], 40));
    if (!ses) return fail(res, 404, '共享已结束');
    const chat = db.chats.find((c) => c.id === ses.chatId);
    if (!chat || !chat.memberIds.includes(me.id)) return fail(res, 403, '你不在这个共享里');
    const list = Object.keys(ses.positions).map((id) => {
      const x = findUser(id);
      return {
        userId: id, name: (x && (x.nickname || x.username)) || '',
        avatar: (x && x.avatar) || '',
        lat: ses.positions[id].lat, lng: ses.positions[id].lng, at: ses.positions[id].at
      };
    });
    ok(res, { sessionId: ses.id, chatId: ses.chatId, fromId: ses.fromId, members: list });
    return;
  }

  /* 停止共享：整条会话一起结束 */
  if (parts[0] === 'live' && parts[1] === 'stop' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const ses = liveLocations.get(str(body.sessionId, 40));
    if (ses) {
      const chat = db.chats.find((c) => c.id === ses.chatId);
      liveLocations.delete(ses.id);
      if (chat) sendToChat(chat, { type: 'live-location', action: 'stop', sessionId: ses.id, chatId: chat.id });
    }
    ok(res, { stopped: true });
    return;
  }

  /* 服务器身份（看门狗用）：说明这个端口上跑的是哪一份数据目录。
     备用目录里如果也有一份 CHRIS 服务器抢着 5180，看门狗靠这个认得出是不是我们这份。 */
  if (parts[0] === 'which' && method === 'GET') {
    ok(res, { dir: DATA_DIR, pid: process.pid, up: Math.floor(process.uptime()) });
    return;
  }

  // 第三方表情搜索：服务端代跑请求（手机在内网，也能用官方 key 直连外部平台）
  if (parts[0] === 'stickers' && parts[1] === 'search' && method === 'GET') {
    const tp = db.stickers.thirdParty;
    const url = thirdPartyUrl(tp, str(query.get('q'), 30));
    if (!url) return ok(res, { items: [], provider: tp.provider, note: '第三方图源没开或没配 key' });
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 8000);
      const r = await fetch(url, { signal: ctl.signal, headers: { 'Accept': 'application/json' } });
      clearTimeout(timer);
      const data = await r.json().catch(() => null);
      ok(res, { items: parseThirdParty(tp.provider, data), provider: tp.provider, status: r.status });
    } catch (err) {
      ok(res, { items: [], provider: tp.provider, error: '第三方请求失败：' + (err && err.message ? err.message : '未知错误') });
    }
    return;
  }

  if (parts[0] === 'register' && method === 'POST') {
    const body = await readBody(req);
    const username = str(body.username, 24);
    const nickname = str(body.nickname, 24) || username;
    const password = String(body.password || '');
    if (!/^[A-Za-z0-9_]{3,24}$/.test(username)) return fail(res, 422, '用户名需为 3-24 位字母、数字或下划线');
    if (password.length < 6) return fail(res, 422, '密码至少 6 位');
    const phone = str(body.phone, 20);
    if (phone && !/^[0-9+\-\s]{5,20}$/.test(phone)) return fail(res, 422, '手机号格式不正确（也可以留空）');
    if (!checkCaptcha(body.captchaId, body.captcha)) return fail(res, 422, '验证码不正确，请重新输入');
    if (findUserByName(username)) return fail(res, 409, '该用户名已被占用');
    const salt = crypto.randomBytes(16).toString('hex');
    const user = {
      id: uid('u'),
      username,
      nickname: nickname.slice(0, 24),
      avatar: str(body.avatar, 300000),
      bio: str(body.bio, 60),
      phone,
      gender: normalizeGender(body.gender),
      balance: 0,                                    // 零钱余额（付款方式里可以选「余额」）
      transferLimit: 20000,                          // 单笔转账限额（0 = 不限）
      salt,
      passwordHash: hashPassword(password, salt),
      createdAt: now()
    };
    db.users.push(user);
    saveUsers();
    attachBotsFor(user);      // 新用户也要有机器人（朋友 + 欢迎会话），否则会话列表是空的
    noteSignupRisk(user, req);   // 风控：同 IP 批量注册（要在记安全事件之前算，才算得准）
    recordSecurity(user.id, req, 'register');
    ok(res, { user: publicUser(user) },
      { 'Set-Cookie': sessionCookie(signToken(user.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* ------------------------------------------------ 手机号登录（外壳那套） */
  // 发验证码：本地没接短信通道，所以直接把码返回给前台显示，方便自己用
  if (parts[0] === 'login' && parts[1] === 'phone-code' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    if (!/^1[3-9]\d{9}$/.test(phone)) return fail(res, 422, '手机号格式不对，要 11 位手机号');
    /* 这个接口能试出「某个手机号有没有绑定账号」，所以单独限流，防止有人拿号码库来撞 */
    if (!phoneCodeRateAllow(clientInfo(req).ip)) {
      strikeIp(clientInfo(req).ip, '狂刷手机号验证码');
      return fail(res, 429, '试得太频繁了，10 分钟后再试');
    }
    const user = db.users.find((u) => normalizePhone(u.phone) === phone);
    if (!user) return fail(res, 404, '这个手机号还没有绑定账号，先用账号密码登录，在「手机号」里绑定');
    if (user.banned) return fail(res, 403, banMsg(user));
    const code = String(Math.floor(100000 + Math.random() * 900000));
    phoneCodes.set(phone, { code, userId: user.id, expiresAt: Date.now() + 5 * 60 * 1000 });
    recordSecurity(user.id, req, 'phone-code', { phone });
    /* 配了短信通道就真发短信；没配就是「开发模式」：只写日志 + 局域网内直接显示 */
    const smsCfg = readSmsCfg();
    let smsResult = { ok: false, error: '短信没配置' };
    if (smsReady(smsCfg)) smsResult = await sendSmsCode(phone, code, smsCfg);
    if (smsReady(smsCfg) && !smsResult.ok) {
      phoneCodes.delete(phone);
      return fail(res, 502, '短信没发出去：' + smsResult.error);
    }
    /* 安全：验证码以前直接写在响应里，知道手机号就能登进别人账号。
       现在只有本机/局域网（你自己的手机、你自己的电脑）才拿得到，外网请求只提示「已发送」。 */
    const fromLan = isLanAddress(peerIp(req));
    console.log('[手机号登录] ' + phone + ' 验证码 ' + code + ' ← ' + clientInfo(req).ip);
    if (smsResult.ok) {
      ok(res, { sent: true, sms: true, nickname: fromLan ? user.nickname : '', note: '验证码已发到手机，5 分钟内有效' });
      return;
    }
    ok(res, fromLan
      ? { sent: true, devCode: code, nickname: user.nickname, note: '没接短信通道，局域网内直接显示，5 分钟内有效' }
      : { sent: true, nickname: '', note: '验证码已发送，请在手机上看（外网不返回验证码）' });
    return;
  }

  /* 密码找回：手机号 + 验证码 + 新密码（对应功能清单里的「密码找回」）
     验证码复用「手机号登录」那套，5 分钟有效；改完直接把当前设备登进去 */
  if (parts[0] === 'login' && parts[1] === 'reset' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    const code = str(body.code, 8);
    const nextPwd = String(body.newPassword || '');
    const rec = phoneCodes.get(phone);
    if (!rec || rec.expiresAt < Date.now()) return fail(res, 422, '验证码过期了，请重新获取');
    if (rec.code !== code) return fail(res, 401, '验证码不对');
    if (nextPwd.length < 6) return fail(res, 422, '新密码至少 6 位');
    const target = findUser(rec.userId);
    if (!target) return fail(res, 404, '账号不存在');
    if (target.banned) return fail(res, 403, banMsg(target));
    const salt = crypto.randomBytes(16).toString('hex');
    target.salt = salt;
    target.passwordHash = hashPassword(nextPwd, salt);
    target.passwordUpdatedAt = now();
    target.tokenVersion = (target.tokenVersion || 0) + 1;
    saveUsers();
    phoneCodes.delete(phone);
    recordSecurity(target.id, req, 'reset-password', { phone: phone });
    ok(res, { user: publicUser(target), reset: true },
      { 'Set-Cookie': sessionCookie(signToken(target.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  // 用手机号 + 验证码登录
  if (parts[0] === 'login' && parts[1] === 'phone' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    const code = str(body.code, 8);
    const rec = phoneCodes.get(phone);
    if (!rec || rec.expiresAt < Date.now()) return fail(res, 422, '验证码过期了，请重新获取');
    if (rec.code !== code) return fail(res, 401, '验证码不对');
    const user = findUser(rec.userId);
    if (!user) return fail(res, 404, '账号不存在');
    if (user.banned) return fail(res, 403, banMsg(user));
    phoneCodes.delete(phone);
    rememberDevice(user, req);      // 短信登录也记设备（换设备登录才会被要求验证）
    saveUsers();
    noteLoginRisk(user, req);   // 风控：新设备 / 同 IP 多账号（要在记安全事件之前算）
    recordSecurity(user.id, req, 'login');
    ok(res, { user: publicUser(user) },
      { 'Set-Cookie': sessionCookie(signToken(user.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  if (parts[0] === 'login' && method === 'POST') {
    const body = await readBody(req);
    const rawName = str(body.username, 24);
    /* 滑动验证：**默认不弹**（正常登录一路过，跟微信一样）。
       票是一次性的（/api/slider/verify 滑对才发、用过即废）；
       只有 loginNeedsSlider() 判定有风险才回 428，
       客户端看到 details.needSlider 再把滑块「弹出来」。
       想整层关掉：data/security.json 里写 "sliderLogin": 0。 */
    if (!consumeSliderTicket(body.sliderTicket) && secCfg().sliderLogin) {
      const guess = findUserByName(rawName);
      if (guess && !guess.banned && loginNeedsSlider(req, guess)) {
        return fail(res, 428, '请完成安全验证', { needSlider: true });
      }
    }
    const ip = clientInfo(req).ip;
    const kUser = 'u:' + rawName.toLowerCase();
    const kIp = 'ip:' + ip;
    const wait = Math.max(loginBlocked(kUser), loginBlocked(kIp));
    if (wait) return fail(res, 429, '密码错误次数太多，请 ' + Math.ceil(wait / 60) + ' 分钟后再试');
    const user = findUserByName(rawName);
    if (!user || !verifyPassword(user, String(body.password || ''))) {
      noteLoginFail(kUser);
      noteLoginFail(kIp);
      return fail(res, 401, '用户名或密码不正确');
    }
    if (user.banned) return fail(res, 403, banMsg(user));
    clearLoginFails([kUser, kIp]);
    rememberDevice(user, req);      // 这台设备登过这个账号了：下次同一台设备直接过
    saveUsers();
    noteLoginRisk(user, req);   // 风控：新设备 / 同 IP 多账号（要在记安全事件之前算）
    recordSecurity(user.id, req, 'login');
    ok(res, { user: publicUser(user) },
      { 'Set-Cookie': sessionCookie(signToken(user.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* 身份证自助解封：被封的账号在登录页填「账号 + 密码 + 身份证号」就能自己解开 */
  if (parts[0] === 'unban' && method === 'POST') {
    const body = await readBody(req);
    const ip = clientInfo(req).ip;
    if (!unbanRateAllow(ip)) return fail(res, 429, '申请太频繁了，10 分钟后再试');
    const idc = normalizeIdCard(body.idCard);
    if (!isValidIdCard(idc)) {
      return fail(res, 422, '身份证号不合法：要 18 位，前 6 位是地区、中间 8 位是生日、最后一位是校验位（可能是 X）');
    }
    const rawName = str(body.username, 24);
    const user = findUserByName(rawName)
      || db.users.find((u) => normalizePhone(u.phone) && normalizePhone(u.phone) === normalizePhone(rawName))
      || null;
    if (!user) return fail(res, 404, '这个账号不存在');
    if (!verifyPassword(user, String(body.password || ''))) {
      noteLoginFail('u:' + user.username);
      noteLoginFail('ip:' + ip);
      return fail(res, 401, '账号或密码不对');
    }
    if (!user.banned) return fail(res, 409, '这个账号没有被禁用，直接登录就行');
    const h = idCardHash(idc);
    /* 同一个账号第二次解封必须用同一张证；一张证只能绑一个账号 */
    if (user.idCardHash && user.idCardHash !== h) {
      return fail(res, 403, '这张身份证和这个账号之前实名登记的不一致');
    }
    const taken = db.users.find((u) => u.id !== user.id && u.idCardHash === h);
    if (taken) return fail(res, 403, '这张身份证已经绑定过其它账号了，请联系管理员');

    const reason = user.banReason || '';
    user.idCardHash = h;
    user.idCardMask = maskIdCard(idc);
    user.idCardVerifiedAt = now();
    user.realNameVerified = true;
    setUserBanned(user, false, '', '身份证自助解封');
    recordSecurity(user.id, req, 'unban-idcard');
    audit(req, { username: user.username, name: user.nickname, role: '用户自助' },
      '身份证自助解封', user.username, maskIdCard(idc) + '（原封禁原因：' + (reason || '未填写') + '）');
    ok(res, {
      unbanned: true, user: publicUser(user), idMask: maskIdCard(idc),
      note: '已解封，正在登录…'
    }, { 'Set-Cookie': sessionCookie(signToken(user.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  if (parts[0] === 'logout' && method === 'POST') {
    ok(res, { loggedOut: true }, { 'Set-Cookie': sessionCookie('', 0) });
    return;
  }

  const user = currentUser(req);
  if (parts[0] === 'session') {
    /* 被封禁的账号：登录态即使还在，也要明确告诉 App「你被禁用了」，
       这样手机端会退到登录页并显示原因，而不是继续用缓存的资料硬撑。 */
    if (user && user.banned) {
      ok(res, {
        authenticated: false, banned: true,
        reason: user.banReason || '', bannedAt: user.bannedAt || 0
      });
      return;
    }
    ok(res, { authenticated: !!user, user: publicUser(user) });
    return;
  }
  /* 一封到底：被封禁的账号，除了上面的登录/会话接口，其它接口一律 403。
     （封禁时 tokenVersion 已经 +1，旧 token 本来就失效了；
       这里再兜一道，防止有设备拿着旧版本号或换新 token 绕进来。） */
  if (user && user.banned) {
    return fail(res, 403, banMsg(user));
  }
  if (!user) { strikeIp(clientInfo(req).ip, '未登录取数据 ' + parts[0]); fail(res, 401, '请先登录'); return; }

  /* 红点数字（很轻的一个接口）：手机端回到前台、或者长连接重连时拉一次，
     就算推送丢了也能把「新的朋友」的红点点亮 */
  if (parts[0] === 'badge-counts' && method === 'GET') {
    ok(res, {
      friendRequests: pendingFriendRequests(user.id),
      momentUnread: momentUnread(user.id)
    });
    return;
  }

  // 安全中心：登录记录 / 安全评分（必须放在通用的 /me 前面，否则会被它截走）
  if (parts[0] === 'me' && parts[1] === 'security' && method === 'GET') {
    const mine = db.security.logins.filter((x) => x.userId === user.id);
    const logins = mine.slice(0, 12).map((x) => ({
      id: x.id, kind: x.kind || 'login', time: x.time, ip: x.ip || '', device: x.device || '未知设备'
    }));
    const cur = clientInfo(req);
    ok(res, {
      score: securityScore(user, mine),
      credit: creditScore(user),                     // 安全分（550~850，三个维度）
      hasPhone: !!user.phone,
      changedPassword: !!user.passwordUpdatedAt,
      passwordUpdatedAt: user.passwordUpdatedAt || '',
      createdAt: user.createdAt || '',
      deviceCount: Object.keys(mine.reduce((a, x) => { a[x.device] = 1; return a; }, {})).length,
      hasPayPassword: hasPayPassword(user),
      payPasswordAt: user.payPasswordAt || '',
      current: cur,
      logins
    });
    return;
  }

  /* 转账付款：走服务端真扣余额（不够就付不了），并往会话里发一条转账消息 */
  /* 安全分：微信「支付分」那套（550~850 · 身份特质 / 支付行为 / 守约历史） */
  if (parts[0] === 'me' && parts[1] === 'score' && method === 'GET') {
    ok(res, { score: creditScore(user) });
    return;
  }

  /* ---------------- 经营账户（钱包 → 经营账户） ---------------- */
  if (parts[0] === 'biz' && method === 'GET') {
    const acc = bizOf(user.id, true);
    const day0 = localDayStart();
    const monthPrefix = new Date().toISOString().slice(0, 7);
    const collects = acc.records.filter((r) => r.kind === 'collect');
    const sum = (list) => Math.round(list.reduce((a, r) => a + (Number(r.amount) || 0), 0) * 100) / 100;
    ok(res, {
      enabled: acc.enabled,
      balance: acc.balance,
      settings: acc.settings,
      invoice: acc.invoice,
      records: acc.records.slice(0, 100),
      invoices: acc.invoices.slice(0, 50),
      totals: {
        today: sum(collects.filter((r) => new Date(r.createdAt).getTime() >= day0)),
        month: sum(collects.filter((r) => String(r.createdAt).slice(0, 7) === monthPrefix)),
        all: sum(collects),
        count: collects.length,
        withdrawn: sum(acc.records.filter((r) => r.kind === 'withdraw'))
      },
      invoiceReady: !!(acc.invoice.title && acc.invoice.taxNo)
    });
    return;
  }

  /* 经营设置（店主自己改） */
  if (parts[0] === 'biz' && parts[1] === 'settings' && method === 'POST') {
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    const s = acc.settings;
    if (body.enabled !== undefined) acc.enabled = !!body.enabled;
    if (body.arrival !== undefined) s.arrival = body.arrival === 'biz' ? 'biz' : 'balance';
    if (body.notify !== undefined) s.notify = !!body.notify;
    if (body.autoWithdraw !== undefined) s.autoWithdraw = !!body.autoWithdraw;
    if (body.shopName !== undefined) s.shopName = str(body.shopName, 30);
    if (body.remark !== undefined) s.remark = str(body.remark, 60);
    if (body.settle !== undefined) s.settle = str(body.settle, 10) || 'T+1';
    saveBizAll();
    ok(res, { enabled: acc.enabled, settings: s });
    return;
  }

  /* 开票信息（抬头 / 税号 / 地址电话 / 开户行账号） */
  if (parts[0] === 'biz' && parts[1] === 'invoice' && parts[2] !== 'apply' && method === 'POST') {
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    ['title', 'taxNo', 'address', 'phone', 'bankName', 'bankAccount'].forEach((k) => {
      if (body[k] !== undefined) acc.invoice[k] = str(body[k], 60);
    });
    saveBizAll();
    ok(res, { invoice: acc.invoice });
    return;
  }

  /* 申请开票：按金额开一张票，后台「经营账户查账」里处理 */
  if (parts[0] === 'biz' && parts[1] === 'invoice' && parts[2] === 'apply' && method === 'POST') {
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    if (!acc.invoice.title || !acc.invoice.taxNo) return fail(res, 422, '先把开票信息填上（抬头 + 税号）');
    const amount = rpRound2(body.amount);
    if (!(amount > 0)) return fail(res, 422, '开票金额要大于 0');
    const collects = Math.round(acc.records.filter((r) => r.kind === 'collect')
      .reduce((a, r) => a + (Number(r.amount) || 0), 0) * 100) / 100;
    const already = Math.round(acc.invoices.reduce((a, i) => a + (Number(i.amount) || 0), 0) * 100) / 100;
    if (amount > collects - already + 0.001) {
      return fail(res, 422, '可开票金额只有 ¥' + (collects - already).toFixed(2));
    }
    const inv = {
      id: uid('inv'), amount, status: 'pending', note: str(body.note, 60),
      title: acc.invoice.title, taxNo: acc.invoice.taxNo,
      kind: body.kind === 'company' ? 'company' : 'personal',
      createdAt: now(), handledAt: ''
    };
    acc.invoices.unshift(inv);
    if (acc.invoices.length > 300) acc.invoices.length = 300;
    bizPush(user.id, { kind: 'invoice', amount, note: '申请开票', status: 'pending' });
    saveBizAll();
    ok(res, { invoice: inv, invoices: acc.invoices.slice(0, 50) });
    return;
  }

  /* 提现到零钱（也可以用「全部提现」） */
  if (parts[0] === 'biz' && parts[1] === 'withdraw' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    const all = body.all === true;
    let amount = all ? acc.balance : rpRound2(body.amount);
    if (!(amount > 0)) return fail(res, 422, '经营账户里还没有可提现的钱');
    if (amount > acc.balance + 0.001) return fail(res, 422, '最多只能提 ¥' + acc.balance.toFixed(2));
    if (hasPayPassword(user) && !body.face) {
      const pwd = String(body.password || '').trim();
      if (!pwd) return fail(res, 422, '请输入支付密码');
      if (!verifyPayPassword(user, pwd)) {
        recordSecurity(user.id, req, 'pay-password-fail', { note: '经营账户提现时支付密码错' });
        return fail(res, 422, '支付密码不正确');
      }
    }
    acc.balance = Math.round((acc.balance - amount) * 100) / 100;
    user.balance = Math.round(((Number(user.balance) || 0) + amount) * 100) / 100;
    saveUsers();
    bizPush(user.id, { kind: 'withdraw', amount, note: '提现到零钱', method: 'balance' });
    saveBizAll();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    ok(res, { balance: user.balance, bizBalance: acc.balance, amount });
    return;
  }

  /* ---------------- 支付分（钱包 → 支付分） ---------------- */
  /* ---------------- 青少年模式（设置 → 青少年模式） ---------------- */
  if (parts[0] === 'me' && parts[1] === 'teen' && method === 'GET') {
    ok(res, { teen: teenCfg(user) });
    return;
  }
  /* 第一次：设密码（4 位数字） */
  if (parts[0] === 'me' && parts[1] === 'teen' && parts[2] === 'setup' && method === 'POST') {
    const body = await readBody(req);
    const pin = String(body.pin || '').trim();
    if (!/^\d{4}$/.test(pin)) return fail(res, 422, '密码要 4 位数字');
    if (user.teen && user.teen.salt && user.teen.hash) return fail(res, 409, '已经设过密码了，忘了密码只能找管理员重置');
    const salt = crypto.randomBytes(16).toString('hex');
    user.teen = Object.assign({}, user.teen || {}, {
      salt: salt, hash: hashPassword(pin, salt), enabled: true,
      scopes: Object.assign({}, DEFAULT_TEEN_SCOPES, (user.teen && user.teen.scopes) || {}),
      setAt: now()
    });
    saveUsers();
    ok(res, { teen: teenCfg(user) });
    return;
  }
  /* 开关 / 改受限项 / 监护人手机号：都要密码 */
  if (parts[0] === 'me' && parts[1] === 'teen' && parts[2] === 'set' && method === 'POST') {
    const body = await readBody(req);
    const t = user.teen || {};
    if (!(t.salt && t.hash)) return fail(res, 409, '先设一个密码');
    const pin = String(body.pin || '').trim();
    if (!verifySecretRecord({ salt: t.salt, hash: t.hash }, pin)) return fail(res, 422, '密码不正确');
    if (body.enabled !== undefined) t.enabled = !!body.enabled;
    if (body.scopes && typeof body.scopes === 'object') {
      t.scopes = Object.assign({}, DEFAULT_TEEN_SCOPES, t.scopes || {});
      Object.keys(DEFAULT_TEEN_SCOPES).forEach((k) => { if (body.scopes[k] !== undefined) t.scopes[k] = body.scopes[k] ? 1 : 0; });
    }
    if (body.guardianPhone !== undefined) {
      const ph = String(body.guardianPhone || '').replace(/\D/g, '');
      t.guardianPhoneMask = ph.length === 11 ? (ph.slice(0, 3) + '****' + ph.slice(7)) : '';
    }
    user.teen = t;
    saveUsers();
    ok(res, { teen: teenCfg(user) });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'payscore' && method === 'GET') {
    ok(res, payScoreOf(user));
    return;
  }

  /* ---------------- 身份信息（钱包 → 身份信息）：实名 + 证件有效期/职业/常住地址 ---------------- */
  if (parts[0] === 'me' && parts[1] === 'identity' && method === 'GET') {
    const verified = !!(user.realName && user.idCardHash);
    ok(res, {
      verified,
      realName: verified ? (String(user.realName).slice(0, 1) + '*'.repeat(Math.max(1, String(user.realName).length - 1))) : '',
      idMask: user.idCardMask || '',
      verifiedAt: user.idCardVerifiedAt || '',
      idValid: user.idValid || '',                 // 证件有效期，比如 2035-08-01
      occupation: user.occupation || '',
      address: user.address || '',
      level: walletLevelInfo(user).level,
      levelName: walletLevelInfo(user).name,
      bankCount: Array.isArray(user.bankCards) ? user.bankCards.length : 0
    });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'identity' && method === 'POST') {
    const body = await readBody(req);
    if (body.idValid !== undefined) user.idValid = str(body.idValid, 20);
    if (body.occupation !== undefined) user.occupation = str(body.occupation, 20);
    if (body.address !== undefined) user.address = str(body.address, 60);
    saveUsers();
    ok(res, { saved: true, idValid: user.idValid || '', occupation: user.occupation || '', address: user.address || '' });
    return;
  }

  /* ---------------- 支付设置（钱包 → 支付设置）：免密支付 / 自动续费 / 支付方式 ---------------- */
  if (parts[0] === 'me' && parts[1] === 'paysettings' && method === 'GET') {
    ok(res, {
      hasPayPassword: hasPayPassword(user),
      noPin: !!user.noPin,                       // 小额免密支付（默认关）
      noPinLimit: Number(user.noPinLimit) || 1000,
      payMethod: user.payMethod === 'card' ? 'card' : 'balance',   // 首选付款方式
      autoDebits: Array.isArray(user.autoDebits) ? user.autoDebits : [],  // 自动续费/免密签约
      payPasswordUpdatedAt: user.payPasswordUpdatedAt || ''
    });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'paysettings' && method === 'POST') {
    const body = await readBody(req);
    if (body.noPin !== undefined) user.noPin = !!body.noPin;
    if (body.noPinLimit !== undefined) {
      const v = Number(body.noPinLimit);
      if ([0, 200, 500, 1000].indexOf(v) >= 0) user.noPinLimit = v || 1000;
    }
    if (body.payMethod !== undefined) user.payMethod = body.payMethod === 'card' ? 'card' : 'balance';
    /* 解约某个自动续费：传 id */
    if (body.cancelAutoDebit !== undefined) {
      const id = str(body.cancelAutoDebit, 40);
      user.autoDebits = (Array.isArray(user.autoDebits) ? user.autoDebits : []).filter((a) => a.id !== id);
    }
    saveUsers();
    ok(res, { saved: true });
    return;
  }

  /* 我的状态：24 小时还剩多久 + 谁看过（微信里点自己的状态能看到「X 人看过」） */
  if (parts[0] === 'me' && parts[1] === 'status' && method === 'GET') {
    const alive = moodAlive(user);
    const views = (Array.isArray(user.moodViews) ? user.moodViews : []).slice(-50).reverse();
    ok(res, {
      alive,
      moodText: alive ? (user.moodText || '') : '',
      moodIcon: alive ? (user.moodIcon || '') : '',
      moodColor: alive ? (user.moodColor || '') : '',
      moodColor2: alive ? (user.moodColor2 || '') : '',
      moodLabel: alive ? (user.moodLabel || user.moodText || '') : '',
      moodCaption: alive ? (user.moodCaption || '') : '',
      createdAt: user.moodAt || '',
      expiresAt: Number(user.moodExpiresAt) || 0,
      hoursLeft: alive && user.moodExpiresAt
        ? Math.max(0, Math.round((user.moodExpiresAt - Date.now()) / 3600000)) : 0,
      viewerCount: alive ? views.length : 0,
      views: views.map((v) => {
        const u = findUser(v.userId) || {};
        return { userId: v.userId, name: displayNameFor(user.id, u), avatar: u.avatar || '', at: v.at };
      })
    });
    return;
  }

  /* 结束我的状态（微信里可以手动结束） */
  if (parts[0] === 'me' && parts[1] === 'status' && method === 'POST') {
    /* 这条路径要跟下面「改在线状态」共用：带 status 的请求是改在线状态，交给下面的分支 */
    const moodBody = await readBody(req);
    const presenceWant = str(moodBody.status, 12);
    if (['online', 'busy', 'away', 'invisible'].includes(presenceWant)) {
      /* 不 return：往后走到「在线状态」那个分支去处理 */
    } else {
    user.moodText = '';
    user.moodLabel = '';
    user.moodCaption = '';
    user.moodKey = '';
    user.moodIcon = '';
    user.moodColor = '';
    user.moodColor2 = '';
    user.moodAt = '';
    user.moodExpiresAt = 0;
    user.moodViews = [];
    saveUsers();
    ok(res, { ended: true });
    return;
    }
  }

  /* ---------------- 账户升级服务（我 → 服务 → 钱包 → 账户升级服务） ---------------- */
  if (parts[0] === 'me' && parts[1] === 'wallet' && method === 'GET') {
    const info = walletLevelInfo(user);
    const real = !!(user.realName && user.idCardHash);
    const bankCount = Array.isArray(user.bankCards) ? user.bankCards.length : 0;
    const used = todayOutAmount(user.id);
    ok(res, {
      level: info.level,
      levelName: info.name,
      tip: info.tip,
      single: info.single,
      day: info.day,
      receive: info.receive,
      usedToday: used,
      leftToday: Math.round(Math.max(0, info.day - used) * 100) / 100,
      realName: real,
      realNameText: user.realName ? (String(user.realName).slice(0, 1) + '**') : '',
      idMask: user.idCardMask || '',
      bankCount,
      upgradedAt: user.walletUpgradedAt || '',
      levels: WALLET_LEVELS.map((l) => ({
        level: l.level, name: l.name, single: l.single, day: l.day,
        current: l.level === info.level, done: l.level <= info.level
      })),
      steps: [
        { key: 'realname', name: '实名认证', done: real, hint: '填姓名 + 身份证号，1 分钟搞定' },
        { key: 'bank', name: '绑定银行卡', done: bankCount > 0, hint: '只记银行名和末四位，卡号不留服务器' }
      ]
    });
    return;
  }

  /* 升级账户：该做的做完才算数（和微信一样，不是点一下就能升） */
  if (parts[0] === 'me' && parts[1] === 'wallet-upgrade' && method === 'POST') {
    const real = !!(user.realName && user.idCardHash);
    const bankCount = Array.isArray(user.bankCards) ? user.bankCards.length : 0;
    if (!real) return fail(res, 422, '先去「实名认证」把姓名和身份证号填上');
    if (!bankCount) return fail(res, 422, '先绑一张银行卡（只记末四位）');
    user.walletUpgradedAt = now();
    saveUsers();
    recordSecurity(user.id, req, 'wallet-upgrade');
    const info = walletLevelInfo(user);
    ok(res, { level: info.level, levelName: info.name, single: info.single, day: info.day });
    return;
  }

  /* 常见问题（独立一页：帮助与反馈 / 钱包底部进去；内容就是客服中心里配的那些问答） */
  if (parts[0] === 'faq' && method === 'GET') {
    const cfg = readSupport();
    const cats = (cfg.categories || []).map((c) => ({
      id: c.id || '',
      title: c.title || '',
      icon: c.icon || '',
      items: (c.items || []).filter((it) => it && it.q).map((it) => ({ q: it.q, a: it.a || '' }))
    })).filter((c) => c.items.length);
    ok(res, {
      title: '常见问题',
      searchHint: cfg.searchHint || '搜索你的问题',
      categories: cats,
      /* 热门：每个分类先拎一条出来（微信那页上面也有一栏热门问题） */
      hot: cats.map((c) => c.items[0]).filter(Boolean).slice(0, 6),
      contact: { phone: cfg.phone || '', email: cfg.email || '', workTime: cfg.workTime || '' }
    });
    return;
  }

  /* ---------------- 实名认证（填姓名 + 身份证号；一人一证） ---------------- */
  if (parts[0] === 'me' && parts[1] === 'realname' && method === 'GET') {
    ok(res, {
      verified: !!(user.realName && user.idCardHash),
      realName: user.realName ? String(user.realName).slice(0, 24) : '',   // 自己的实名，本人看全名
      idMask: user.idCardMask || '',
      at: user.idCardVerifiedAt || ''
    });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'realname' && method === 'POST') {
    const body = await readBody(req);
    const limitKey = user.id + ':' + clientInfo(req).ip;
    if (!realNameRateAllow(limitKey)) return fail(res, 429, '试得太频繁了，10 分钟后再试');

    const name = str(body.realName, 24).replace(/\s+/g, '');
    if (!(/^[\u4e00-\u9fa5·]{2,20}$/.test(name) || /^[A-Za-z][A-Za-z .]{1,38}$/.test(name))) {
      return fail(res, 422, '姓名要填真实的：中文 2~20 个字，或者英文名');
    }
    const idc = normalizeIdCard(body.idCard);
    if (!isValidIdCard(idc)) {
      return fail(res, 422, '身份证号不合法：要 18 位，前 6 位地区、中间 8 位生日、最后一位校验位（可能是 X）');
    }
    const h = idCardHash(idc);
    if (user.idCardHash && user.idCardHash === h && user.realName === name) {
      ok(res, { verified: true, realName: realNameOf(user), idMask: user.idCardMask || maskIdCard(idc), again: true });
      return;
    }
    if (user.idCardHash && user.idCardHash !== h) {
      return fail(res, 403, '这个账号已经实名过了，实名信息不能自己改，要改请联系管理员');
    }
    const taken = db.users.find((u) => u.id !== user.id && u.idCardHash === h);
    if (taken) return fail(res, 403, '这张身份证已经绑定过其它账号了，请联系管理员');

    user.realName = name;
    user.idCardHash = h;
    user.idCardMask = maskIdCard(idc);
    user.idCardVerifiedAt = now();
    user.realNameVerified = true;
    saveUsers();
    recordSecurity(user.id, req, 'realname');
    audit(req, { username: user.username, name: user.nickname, role: '用户本人' },
      '实名认证', user.username, name + ' · ' + maskIdCard(idc));
    ok(res, { verified: true, realName: name, idMask: maskIdCard(idc), at: user.idCardVerifiedAt });
    return;
  }

  /* ================= 收付款（微信那套：付款码 + 收款码） =================
     付款码：18 位数字（和微信一样），60 秒一换，给商家/对方扫；
     收款码：一张固定的二维码，扫了给对方付款；「设置金额」出来的带金额码 24 小时有效。
     付款方要过支付密码 / 额度 / 余额三道检查，钱当时就到对方账上（商家收款即时到账），
     同时往两个人的会话里落一条转账记录（账单、经营账户查账都看得到）。 */

  if (parts[0] === 'pay' && parts[1] === 'code' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const code = newPayCode(user.id);
    const rec = payCodes.get(code) || { exp: Date.now() + PAY_CODE_TTL_MS };
    const url = payBaseUrl(req) + '/pay.html?c=' + code;
    const enc = QR.encode(url);
    ok(res, {
      code: code,
      grouped: code.replace(/(\d{4})(?=\d)/g, '$1 '),
      url: url,
      expiresAt: rec.exp,
      seconds: Math.max(1, Math.round((rec.exp - Date.now()) / 1000)),
      rows: enc ? enc.modules.map((r) => r.join('')) : [],
      size: enc ? enc.size : 0,
      user: publicUser(user)
    });
    return;
  }

  /* 收款码：不带金额 = 「我的收款码」；带 amount = 微信那种「设置金额」 */
  if (parts[0] === 'pay' && parts[1] === 'receive-code' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    const amt = rpRound2(Number(body.amount) || 0);
    if (amt < 0 || amt > 200000) return fail(res, 422, '金额填得不对');
    const u = userCode(user.username);
    let url = payBaseUrl(req) + '/pay.html?u=' + encodeURIComponent(u);
    let exp = 0;
    if (amt > 0) {
      exp = Date.now() + 24 * 3600 * 1000;
      const a = amt.toFixed(2);
      url += '&a=' + a + '&e=' + exp + '&s=' + payAmountSig(u, a, exp);
    }
    const enc = QR.encode(url);
    ok(res, {
      url: url, amount: amt, expiresAt: exp,
      rows: enc ? enc.modules.map((r) => r.join('')) : [],
      size: enc ? enc.size : 0,
      user: publicUser(user)
    });
    return;
  }

  /* 扫到的字符串 → 这是谁的收付款码（客户端扫之前先问一下，免得把人都弄错） */
  if (parts[0] === 'pay' && parts[1] === 'resolve' && method === 'POST') {
    const body = await readBody(req);
    const found = resolvePayText(str(body.text || body.code, 400));
    if (found.error) return fail(res, 404, found.error);
    ok(res, { kind: found.kind, amount: found.amount || 0, user: publicUser(found.target) });
    return;
  }

  /* 扫码付款：付款码（对方扫我）/ 收款码（我扫对方）都走这里 */
  if (parts[0] === 'pay' && parts[1] === 'collect' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    if (!payRateAllow(user.id)) return fail(res, 429, '付得太快了，歇一会儿再试');
    const found = resolvePayText(str(body.text || body.code, 400));
    if (found.error) return fail(res, 404, found.error);
    const target = found.target;
    if (target.id === user.id) return fail(res, 422, '不能给自己付钱');
    const face = !!body.face;
    const pwd = String(body.password || '').trim();
    let amount = rpRound2(Number(body.amount) || 0);
    if (found.kind === 'receive' && found.amount > 0) amount = found.amount;
    if (!(amount > 0)) return fail(res, 422, '请输入付款金额');
    if (amount > 200000) return fail(res, 422, '单笔最多 200000 元');
    if (hasPayPassword(user) && !face) {
      if (!pwd) return fail(res, 422, '请输入支付密码');
      if (!verifyPayPassword(user, pwd)) {
        recordSecurity(user.id, req, 'pay-password-fail', { note: '扫码付款时支付密码错' });
        return fail(res, 422, '支付密码不正确');
      }
    }
    const lim = walletLimitCheck(user, amount);
    if (lim.error) return fail(res, 403, lim.error);
    let balance = Number(user.balance) || 0;
    if (balance < amount) return fail(res, 402, '余额不足，先充值再来');
    /* 会话：没有就现开一个 —— 转账记录要落在会话里（微信也是这么记的） */
    let chat = directChatBetween(user.id, target.id);
    if (!chat) {
      chat = {
        id: uid('c'), type: 'direct', name: '', avatar: '',
        memberIds: [user.id, target.id], ownerId: user.id, seq: 0, createdAt: now()
      };
      db.chats.push(chat);
      sendTo(target.id, { type: 'chat', action: 'created', chat: chatSummary(chat, target.id) });
    }
    balance = rpRound2(balance - amount);
    user.balance = balance;
    const note = str(body.note, 40) || (found.kind === 'pay' ? '扫码付款' : '收款码付款');
    const transfer = {
      id: uid('tr'), chatId: chat.id, fromId: user.id, toId: target.id,
      amount: amount, note: note, method: 'balance', status: 'received',
      createdAt: now(), expiresAt: 0, receivedAt: now(), refundedAt: '', messageId: ''
    };
    db.transfers.unshift(transfer);
    if (db.transfers.length > 800) db.transfers.length = 800;
    const sent = deliverMessage(user, chat.id, 'transfer', transferSnapshot(transfer), null);
    if (sent.error) {
      db.transfers = db.transfers.filter((x) => x.id !== transfer.id);
      user.balance = rpRound2(balance + amount);       // 发不出去就把钱还回去
      saveUsers();
      return fail(res, 400, sent.error);
    }
    transfer.messageId = sent.message.id;
    syncTransferMessage(transfer);
    /* 钱当时到对方账上（微信商家收款就是即时到账）：开了经营账户就走经营账户 */
    bizCollect(target, amount, user.nickname || user.username || '好友', user.id, 'paycode', note);
    saveUsers();
    saveTransfers();
    broadcastTransfer(transfer, 'received');
    sendTo(user.id, { type: 'balance', balance: balance });
    /* 付款码是一次性的：用过就作废（微信也是刷一次就换） */
    if (found.kind === 'pay' && found.code) {
      const rec = payCodes.get(found.code);
      if (rec) rec.used = true;
    }
    audit(req, { username: user.username, name: user.nickname, role: '用户本人' },
      '扫码付款', target.username, amount.toFixed(2) + ' 元');
    ok(res, {
      balance: balance, amount: amount,
      payee: publicUser(target),
      transfer: JSON.parse(transferSnapshot(transfer))
    });
    return;
  }

  if (parts[0] === 'pay' && parts[1] === 'transfer' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    const useBalance = body.method !== 'card';
    const face = !!body.face;                                   // 「使用面容」= 已通过人脸
    const pwd = String(body.password || '').trim();
    const note = str(body.note, 60);
    if (!(amount > 0)) return fail(res, 422, '转账金额要大于 0');
    if (amount > 200000) return fail(res, 422, '单笔最多 200000');
    const limit = user.transferLimit === undefined ? 20000 : Number(user.transferLimit) || 0;
    if (limit > 0 && amount > limit) return fail(res, 422, '超过单笔转账限额 ¥' + limit.toFixed(2) + '，可在设置里调');
    if (hasPayPassword(user) && !face) {
      if (!pwd) return fail(res, 422, '请输入支付密码');
      if (!verifyPayPassword(user, pwd)) {
        recordSecurity(user.id, req, 'pay-password-fail', { note: '转账时支付密码错' });
        return fail(res, 422, '支付密码不正确');
      }
    }
    const chat = db.chats.find((c) => c.id === str(body.chatId, 60));
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');

    /* 账户等级额度：超了就提示去「账户升级服务」（微信也是这个提示） */
    const lim = walletLimitCheck(user, amount);
    if (lim.error) return fail(res, 403, lim.error);

    // 不管选的是余额还是银行卡，钱都从余额里扣：用多少扣多少，没余额就付不了
    let balance = Number(user.balance) || 0;
    if (balance < amount) return fail(res, 402, '余额不足，先充值再来');
    balance = Math.round((balance - amount) * 100) / 100;
    user.balance = balance;
    const peerId = chat.type === 'direct' ? chat.memberIds.filter((id) => id !== user.id)[0] : '';
    // 转账单：钱先挂着，对方点了「收钱」才进他余额；24 小时没人收自动退回
    const transfer = {
      id: uid('tr'),
      chatId: chat.id,
      fromId: user.id,
      toId: peerId || '',
      amount,
      note: note || '',
      method: useBalance ? 'balance' : 'card',
      status: 'pending',
      createdAt: now(),
      expiresAt: Date.now() + TRANSFER_TTL_MS,
      receivedAt: '',
      refundedAt: '',
      messageId: ''
    };
    db.transfers.unshift(transfer);
    if (db.transfers.length > 800) db.transfers.length = 800;
    const sent = deliverMessage(user, chat.id, 'transfer', transferSnapshot(transfer), null);
    if (sent.error) {
      db.transfers = db.transfers.filter((x) => x.id !== transfer.id);
      user.balance = Math.round((balance + amount) * 100) / 100;    // 发不出去就把钱还回去
      saveUsers();
      return fail(res, 400, sent.error);
    }
    transfer.messageId = sent.message.id;
    syncTransferMessage(transfer);
    saveUsers();
    saveTransfers();
    sendTo(user.id, { type: 'balance', balance: balance });         // 自己余额实时减
    ok(res, {
      balance, amount,
      method: useBalance ? 'balance' : 'card',
      deducted: amount,
      transfer: JSON.parse(transferSnapshot(transfer))
    });
    return;
  }

  /* 收款：对方点「收钱」，钱才真正进他余额 */
  if (parts[0] === 'transfers' && parts[2] === 'claim' && method === 'POST') {
    const tr = db.transfers.find((x) => x.id === str(parts[1], 60));
    if (!tr) return fail(res, 404, '转账单不存在');
    if (tr.toId !== user.id) return fail(res, 403, '这笔转账不是给你的');
    if (tr.status === 'received') return fail(res, 409, '这笔钱已经收过了');
    if (tr.status === 'refunded') return fail(res, 409, '超过 24 小时没收，钱已退回对方');
    if (tr.expiresAt <= Date.now()) { expireTransfers(); return fail(res, 409, '超过 24 小时没收，钱已退回对方'); }
    tr.status = 'received';
    tr.receivedAt = now();
    /* 收到的钱：开了经营账户且选了「到账经营账户」就进经营账户，否则照旧进零钱；
       两种情况都会记一条收款流水（后台「经营账户查账」看的就是它） */
    const payer = findUser(tr.fromId) || {};
    bizCollect(user, tr.amount, payer.nickname || payer.username || '好友', tr.fromId, 'transfer', tr.note || '');
    saveTransfers();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    broadcastTransfer(tr, 'received');
    ok(res, { balance: user.balance, transfer: JSON.parse(transferSnapshot(tr)) });
    return;
  }

  /* 发红包（微信那一套）：单聊 1 个；群聊可以设个数，拼手气 / 普通。
     发的时候先把总额从余额里扣掉，抢一个扣一个，24 小时没抢完的把剩下的退回。 */
  if (parts[0] === 'pay' && parts[1] === 'redpacket' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    const face = !!body.face;
    const pwd = String(body.password || '').trim();
    const note = str(body.note, 50) || '恭喜发财，大吉大利';
    const chat = db.chats.find((c) => c.id === str(body.chatId, 60));
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');

    const isGroup = chat.type === 'group';
    const total = rpRound2(body.amount);
    /* 账户等级额度：发红包也算转出（和微信一样要过额度） */
    const rpLim = walletLimitCheck(user, total);
    if (rpLim.error) return fail(res, 403, rpLim.error);
    /* 单聊只能发 1 个；群聊 1~100 个（微信上限就是 100） */
    let count = isGroup ? Math.round(Number(body.count) || 1) : 1;
    count = Math.max(1, Math.min(100, count));
    const type = (isGroup && String(body.type || '') === 'lucky') ? 'lucky' : 'normal';
    if (!(total > 0)) return fail(res, 422, '红包金额要大于 0');
    if (total > 200000) return fail(res, 422, '单个红包最多 200000 元');
    if (total < count * 0.01) return fail(res, 422, '每个红包最少 0.01 元，金额再大一点');
    if (type === 'normal' && count > 1) {
      /* 普通红包：微信要求能平均分，分不尽就提示（避免出现 0.01 的零头） */
      const each = rpRound2(total / count);
      if (Math.abs(each * count - total) > 0.005) {
        return fail(res, 422, '普通红包要能平分：' + count + ' 个 × ' + each.toFixed(2) + ' 元，金额改成 ' + (each * count).toFixed(2) + ' 元');
      }
    }
    if (hasPayPassword(user) && !face) {
      if (!pwd) return fail(res, 422, '请输入支付密码');
      if (!verifyPayPassword(user, pwd)) {
        recordSecurity(user.id, req, 'pay-password-fail', { note: '发红包时支付密码错' });
        return fail(res, 422, '支付密码不正确');
      }
    }

    let balance = Number(user.balance) || 0;
    if (balance < total) return fail(res, 402, '余额不足，先充值再来');
    balance = rpRound2(balance - total);
    user.balance = balance;

    const peerId = chat.type === 'direct' ? (chat.memberIds.filter((id) => id !== user.id)[0] || '') : '';
    const rp = {
      id: uid('rp'),
      chatId: chat.id,
      fromId: user.id,
      fromName: user.nickname || user.username || '',
      toId: peerId,
      total,
      count,
      type,
      coverId: (rpCoverOf(body.coverId || user.rpCover) || {}).id || '',
      note: note || '',
      status: 'pending',
      claims: [],
      createdAt: now(),
      expiresAt: Date.now() + TRANSFER_TTL_MS,
      refundedAt: '',
      refundAmount: 0,
      expired: false,
      messageId: ''
    };
    if (!Array.isArray(db.redpackets)) db.redpackets = [];
    db.redpackets.unshift(rp);
    if (db.redpackets.length > 800) db.redpackets.length = 800;

    const sent = deliverMessage(user, chat.id, 'redpacket', redpacketSnapshot(rp), null);
    if (sent.error) {
      db.redpackets = db.redpackets.filter((x) => x.id !== rp.id);
      user.balance = rpRound2(balance + total);      // 发不出去就把钱还回去
      saveUsers();
      return fail(res, 400, sent.error);
    }
    rp.messageId = sent.message.id;
    syncRedPacketMessage(rp);
    saveUsers();
    saveRedPackets();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    ok(res, {
      balance: user.balance, amount: total, count, type,
      coverId: rp.coverId,
      redpacket: JSON.parse(redpacketSnapshot(rp))
    });
    return;
  }

  /* 红包封面：能选的封面列表 + 我自己选的那张 */
  if (parts[0] === 'redpacket' && parts[1] === 'covers' && method === 'GET') {
    const cfg = readRpCovers();
    ok(res, {
      covers: cfg.covers.filter((c) => c.enabled).map((c) => ({
        id: c.id, name: c.name, image: c.image, thumb: c.thumb, color: c.color
      })),
      defaultId: cfg.defaultId,
      mine: rpCoverOf(user.rpCover).id
    });
    return;
  }

  /* 选一张我自己的红包封面（下次发红包默认用它） */
  if (parts[0] === 'redpacket' && parts[1] === 'cover' && method === 'POST') {
    const body = await readBody(req);
    const id = str(body.id, 30);
    const cover = readRpCovers().covers.find((c) => c.id === id && c.enabled);
    if (!cover) return fail(res, 404, '没有这张封面，刷新一下再试');
    user.rpCover = cover.id;
    saveUsers();
    ok(res, { coverId: cover.id, name: cover.name });
    return;
  }

  /* 红包详情：谁抢了多少、手气最佳是谁（微信点开红包卡片看的那一页） */
  if (parts[0] === 'redpackets' && parts.length === 2 && parts[1] !== 'mine' && method === 'GET') {
    const rp = (db.redpackets || []).find((x) => x.id === str(parts[1], 60));
    if (!rp) return fail(res, 404, '红包不存在');
    const chat = db.chats.find((c) => c.id === rp.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (rp.status === 'pending' && rp.expiresAt <= Date.now()) expireRedPackets();
    const best = rpBest(rp);
    const myClaim = rpClaims(rp).find((c) => c.userId === user.id) || null;
    ok(res, {
      redpacket: Object.assign(JSON.parse(redpacketSnapshot(rp)), {
        fromAvatar: (findUser(rp.fromId) || {}).avatar || '',
        claimedTotal: rpClaimed(rp),
        leftAmount: rpLeftAmount(rp),
        leftCount: rpLeftCount(rp),
        mine: myClaim ? { amount: myClaim.amount, at: myClaim.at } : null,
        bestUserId: best ? best.userId : '',
        bestAmount: best ? best.amount : 0,
        claims: rpClaims(rp).map((c) => {
          const u = findUser(c.userId) || {};
          return {
            userId: c.userId,
            name: c.name || u.nickname || u.username || '好友',
            avatar: u.avatar || '',
            amount: c.amount,
            at: c.at,
            fromId: rp.fromId,
            fromName: rp.fromName || (findUser(rp.fromId) || {}).nickname || ''
          };
        })
      })
    });
    return;
  }

  /* 我收到的 / 我发出的红包（微信「红包记录」） */
  if (parts[0] === 'redpackets' && parts[1] === 'mine' && method === 'GET') {
    const list = (db.redpackets || []).filter((r) =>
      r.fromId === user.id || rpClaims(r).some((c) => c.userId === user.id));
    const rows = list.slice(0, 100).map((r) => {
      const mine = rpClaims(r).find((c) => c.userId === user.id) || null;
      const u = findUser(r.fromId) || {};
      return {
        id: r.id,
        chatId: r.chatId,
        direction: r.fromId === user.id ? 'out' : 'in',
        total: r.total,
        count: r.count,
        type: r.type,
        note: r.note || '',
        status: r.status,
        expired: !!r.expired,
        claimedCount: rpClaims(r).length,
        fromName: r.fromName || u.nickname || '',
        fromAvatar: u.avatar || '',
        mineAmount: mine ? mine.amount : 0,
        createdAt: r.createdAt,
        expiresAt: r.expiresAt
      };
    });
    ok(res, { redpackets: rows });
    return;
  }

  /* 拆红包：点「开」才真正进余额。发红包的人不能抢自己的，同一个人只能抢一次 */
  if (parts[0] === 'redpackets' && parts[2] === 'claim' && method === 'POST') {
    const rp = (db.redpackets || []).find((x) => x.id === str(parts[1], 60));
    if (!rp) return fail(res, 404, '红包不存在');
    const chat = db.chats.find((c) => c.id === rp.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (rp.fromId === user.id) return fail(res, 403, '不能抢自己发的红包');
    if (rpClaims(rp).some((c) => c.userId === user.id)) return fail(res, 409, '这个红包你已经抢过了');
    if (rp.expiresAt <= Date.now()) {
      expireRedPackets();
      return fail(res, 409, '红包超过 24 小时了，没抢到的钱已经退回给对方');
    }
    if (rp.status !== 'pending') return fail(res, 409, '手慢了，红包已经被抢完了');
    const amount = drawRedPacketAmount(rp);
    if (!(amount > 0)) { expireRedPackets(); return fail(res, 409, '红包已经过期了'); }
    if (!Array.isArray(rp.claims)) rp.claims = [];
    rp.claims.push({
      userId: user.id,
      name: user.nickname || user.username || '',
      amount,
      at: now()
    });
    /* 抢到的红包钱：和收转账一样走「收款流水」（开了经营账户就进经营账户余额） */
    const rpSender = findUser(rp.fromId) || {};
    bizCollect(user, amount, rpSender.nickname || rpSender.username || '好友', rp.fromId, 'redpacket', rp.note || '红包');
    if (rp.claims.length >= (Number(rp.count) || 1)) rp.status = 'done';
    saveRedPackets();
    broadcastRedPacket(rp, 'claim');
    /* 群聊里抢红包会多一条灰条（微信就是这样），单聊不刷屏 */
    if (chat.type === 'group') {
      const sys = pushSystemMessage(chat, (user.nickname || user.username || '好友') + ' 领取了你的红包');
      chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
      saveChats();
    }
    const best = rpBest(rp);
    ok(res, {
      balance: user.balance,
      amount,
      redpacket: JSON.parse(redpacketSnapshot(rp)),
      bestUserId: best ? best.userId : '',
      leftCount: rpLeftCount(rp)
    });
    return;
  }

  /* 余额充值（手机端自助）：POST { amount } */
  /* ============================================================
     零钱：银行卡 / 充值 / 提现（微信「我 → 服务 → 钱包 → 零钱」那一套）
     · 银行卡只存「银行名 + 末四位」，完整卡号不留在服务器上
     · 充值：银行卡 → 零钱（我们自己记账，后台 allowRecharge 开关控制）
     · 提现：零钱 → 银行卡，手续费 0.1%（最低 0.1 元），要支付密码
     · 充值 / 提现 / 提现手续费 都会进账单
     ============================================================ */
  if (parts[0] === 'wallet' && parts[1] === 'banks' && method === 'GET') {
    ok(res, { banks: userBanks(user) });
    return;
  }

  if (parts[0] === 'wallet' && parts[1] === 'banks' && method === 'POST') {
    const body = await readBody(req);
    const cardNo = String(body.cardNo || '').replace(/\D/g, '');
    if (cardNo.length < 12 || cardNo.length > 19) return fail(res, 422, '卡号不对（12~19 位数字）');
    const list = userBanks(user);
    if (list.length >= 10) return fail(res, 422, '最多绑 10 张卡');
    const row = {
      id: uid('bk'),
      bank: str(body.bank, 20) || '银行卡',
      tail: cardNo.slice(-4),
      holder: str(body.holder, 20),
      isDefault: list.length === 0,
      addedAt: now()
    };
    list.push(row);
    saveUsers();
    recordSecurity(user.id, req, 'bank-add', { note: row.bank + ' 尾号' + row.tail });
    ok(res, { bank: row, banks: list });
    return;
  }

  if (parts[0] === 'wallet' && parts[1] === 'banks' && parts[2] === 'remove' && method === 'POST') {
    const body = await readBody(req);
    const id = str(body.id, 40);
    const list = userBanks(user);
    const hit = list.find((b) => b.id === id);
    if (!hit) return fail(res, 404, '这张卡不在了');
    user.banks = list.filter((b) => b.id !== id);
    if (hit.isDefault && user.banks.length) user.banks[0].isDefault = true;
    saveUsers();
    ok(res, { banks: user.banks });
    return;
  }

  /* 充值：银行卡 → 零钱 */
  if (parts[0] === 'wallet' && parts[1] === 'recharge' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const rules = readWalletRules();
    if (!rules.allowRecharge || !secCfg().allowRecharge) {
      return fail(res, 403, '充值暂未开放，请让管理员在后台打开「允许用户自助充值」');
    }
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '充值金额要大于 0');
    if (amount < 0.01) return fail(res, 422, '充值金额太小');
    if (amount > rules.rechargeMax) return fail(res, 422, '单次充值最多 ¥' + rules.rechargeMax);
    const list = userBanks(user);
    const bank = list.find((b) => b.id === str(body.bankId, 40)) || list.find((b) => b.isDefault) || list[0] || null;
    const before = Number(user.balance) || 0;
    user.balance = Math.round((before + amount) * 100) / 100;
    saveUsers();
    const op = pushWalletOp({
      id: uid('wop'), userId: user.id, kind: 'recharge', amount,
      bankText: bank ? (bank.bank + '（' + bank.tail + '）') : '银行卡',
      status: 'done', createdAt: now(), doneAt: now()
    });
    recordSecurity(user.id, req, 'recharge', { note: '充值 ' + amount });
    sendTo(user.id, { type: 'balance', balance: user.balance });
    ok(res, { recharged: amount, balanceBefore: before, balance: user.balance, op });
    return;
  }

  /* 提现：零钱 → 银行卡（微信：每笔 0.1%，最低 0.1 元，2 小时内到账） */
  if (parts[0] === 'wallet' && parts[1] === 'withdraw' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const rules = readWalletRules();
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '提现金额要大于 0');
    if (amount < rules.withdrawMin) return fail(res, 422, '提现最少 ¥' + rules.withdrawMin.toFixed(2));
    if (amount > rules.withdrawMax) return fail(res, 422, '单笔提现最多 ¥' + rules.withdrawMax);
    /* 提现也算转出额度（微信也是一样按账户等级限额） */
    const wdLim = walletLimitCheck(user, amount);
    if (wdLim.error) return fail(res, 403, wdLim.error);
    const face = !!body.face;
    const pwd = String(body.password || '').trim();
    if (hasPayPassword(user) && !face) {
      if (!pwd) return fail(res, 422, '请输入支付密码');
      if (!verifyPayPassword(user, pwd)) {
        recordSecurity(user.id, req, 'pay-password-fail', { note: '提现时支付密码错' });
        return fail(res, 422, '支付密码不正确');
      }
    }
    const list = userBanks(user);
    const bank = list.find((b) => b.id === str(body.bankId, 40)) || list.find((b) => b.isDefault) || list[0] || null;
    if (!bank) return fail(res, 422, '先加一张银行卡');
    const fee = Math.max(rules.feeMin, Math.round(amount * rules.feeRate * 100) / 100);
    const before = Number(user.balance) || 0;
    if (before < amount + fee) {
      return fail(res, 402, '零钱不够：要提 ¥' + amount.toFixed(2) + '，手续费 ¥' + fee.toFixed(2)
        + '，当前零钱 ¥' + before.toFixed(2));
    }
    user.balance = Math.round((before - amount - fee) * 100) / 100;
    saveUsers();
    const op = pushWalletOp({
      id: uid('wop'), userId: user.id, kind: 'withdraw', amount, fee,
      bankText: bank.bank + '（' + bank.tail + '）', bankId: bank.id,
      /* 后台关了「提现审核」就直接算到账（微信也是即时处理），开着就要等后台点 */
      status: rules.withdrawReview ? 'pending' : 'done',
      createdAt: now(), doneAt: rules.withdrawReview ? '' : now()
    });
    recordSecurity(user.id, req, 'withdraw', { note: '提现 ' + amount + ' 手续费 ' + fee });
    sendTo(user.id, { type: 'balance', balance: user.balance });
    ok(res, {
      amount, fee, balance: user.balance, status: 'pending',
      bankText: op.bankText, expect: rules.withdrawReview ? '已提交，等待管理员审核' : '预计 2 小时内到账'
    });
    return;
  }

  /* 提现记录 */
  if (parts[0] === 'wallet' && parts[1] === 'withdraws' && method === 'GET') {
    const mine = readWalletOps().ops.filter((o) => o.userId === user.id).slice(0, 100);
    const rules = readWalletRules();
    ok(res, { ops: mine, rules: { feeRate: rules.feeRate, feeMin: rules.feeMin, withdrawMin: rules.withdrawMin, withdrawMax: rules.withdrawMax, allowRecharge: !!rules.allowRecharge, rechargeMax: rules.rechargeMax, note: rules.note } });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'recharge' && method === 'POST') {
    /* 安全：以前任何登录用户都能自己给自己加钱（等于自己印钱）。
       现在默认关闭，要充值走后台（后台 → 用户 → 充值），
       确实想让用户自己充，再把 data/security.json 里的 allowRecharge 改成 1。 */
    if (!secCfg().allowRecharge) {
      strikeIp(clientInfo(req).ip, '用户自助充值');
      return fail(res, 403, '自助充值已关闭，请让管理员在后台给你充值');
    }
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '充值金额要大于 0');
    if (amount > 1000000) return fail(res, 422, '单次充值不能超过 1000000');
    const before = Number(user.balance) || 0;
    user.balance = Math.round((before + amount) * 100) / 100;
    saveUsers();
    recordSecurity(user.id, req, 'recharge', { note: '充值 ' + amount });
    ok(res, { recharged: amount, balanceBefore: before, balance: user.balance });
    return;
  }

  /* 收藏：GET 列表 / POST 加一条 / DELETE 删一条 */
  if (parts[0] === 'favorites' && method === 'GET') {
    ok(res, { favorites: Array.isArray(user.favorites) ? user.favorites : [] });
    return;
  }
  if (parts[0] === 'favorites' && method === 'POST') {
    const body = await readBody(req);
    const kind = ['text', 'image', 'transfer'].indexOf(body.kind) >= 0 ? body.kind : 'text';
    /* 单条收藏最多 2 万字：以前能塞 200 万字 × 300 条，一个人就能把数据库撑爆 */
    const content = str(body.content, 20000);
    if (!content) return fail(res, 422, '内容为空，收藏不了');
    if (!Array.isArray(user.favorites)) user.favorites = [];
    if (user.favorites.length >= 300) return fail(res, 429, '收藏夹最多 300 条，先删几条');
    if (!Array.isArray(user.favorites)) user.favorites = [];
    const fav = {
      id: uid('fav'),
      kind,
      content,
      title: str(body.title, 60),
      from: str(body.from, 40),
      at: now()
    };
    user.favorites.unshift(fav);
    if (user.favorites.length > 300) user.favorites.length = 300;
    saveUsers();
    ok(res, { favorite: fav, count: user.favorites.length });
    return;
  }
  if (parts[0] === 'favorites' && parts.length === 3 && method === 'DELETE') {
    const id = str(parts[2], 40);
    if (!Array.isArray(user.favorites)) user.favorites = [];
    const before = user.favorites.length;
    user.favorites = user.favorites.filter((f) => f.id !== id);
    saveUsers();
    ok(res, { deleted: before !== user.favorites.length });
    return;
  }

  /* 支付密码：GET 看有没有设置 / POST 设置或修改 / POST verify 校验（转账确认用） */
  if (parts[0] === 'me' && parts[1] === 'paypassword') {
    if (parts[2] === 'verify' && method === 'POST') {
      if (!hasPayPassword(user)) return fail(res, 409, '还没有设置支付密码');
      const body = await readBody(req);
      const pwd = String(body.password || '').trim();
      if (!verifyPayPassword(user, pwd)) {
        recordSecurity(user.id, req, 'pay-password-fail', { note: '支付密码输错' });
        return fail(res, 422, '支付密码不正确');
      }
      ok(res, { verified: true });
      return;
    }
    if (method === 'GET') {
      ok(res, { has: hasPayPassword(user), updatedAt: user.payPasswordAt || '' });
      return;
    }
    if (method === 'POST') {
      const body = await readBody(req);
      const next = String(body.password || '').trim();
      const current = String(body.current || '').trim();
      if (!/^\d{6}$/.test(next)) return fail(res, 422, '支付密码要 6 位数字');
      if (hasPayPassword(user)) {
        if (!verifyPayPassword(user, current)) return fail(res, 401, '原支付密码不正确');
        if (current === next) return fail(res, 422, '新支付密码不能和原来的相同');
      }
      const salt = crypto.randomBytes(16).toString('hex');
      user.paySalt = salt;
      user.payPasswordHash = hashPassword(next, salt);
      user.payPasswordAt = now();
      saveUsers();
      recordSecurity(user.id, req, 'pay-password');
      ok(res, { has: true, updatedAt: user.payPasswordAt });
      return;
    }
  }

  /* 只认 /api/me 本身：/api/me/bankcards 这种子路径要用自己的分支 */
  if (parts[0] === 'me' && parts.length === 1 && method === 'GET') {
    ok(res, {
      user: Object.assign(publicUser(user), {
        phone: user.phone || '',
    alipay: user.alipay || '',
    alipayQr: user.alipayQr || '',
        phoneUpdatedAt: user.phoneUpdatedAt || '',
        balance: Number(user.balance) || 0,                       // 自己的零钱余额（别人看不到）
        transferLimit: user.transferLimit === undefined ? 20000 : Number(user.transferLimit) || 0
      }),
      online: onlineUserIds()
    });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'status' && method === 'POST') {
    const body = await readBody(req);
    const st = str(body.status, 12);
    const allowed = ['online', 'busy', 'away', 'invisible'];
    if (!allowed.includes(st)) return fail(res, 422, '不支持的在线状态');
    user.status = st;
    saveUsers();
    // 通知好友（隐身在别人眼里就是离线）
    friendIds(user.id).forEach((fid) => sendTo(fid, { type: 'presence', userId: user.id, online: true, status: visibleStatus(user.id) }));
    ok(res, { status: st });
    return;
  }

  if (parts[0] === 'me' && parts.length === 1 && method === 'PATCH') {
    const body = await readBody(req);
    if (body.nickname !== undefined) user.nickname = str(body.nickname, 24) || user.nickname;
    if (body.bio !== undefined) user.bio = str(body.bio, 60);
    if (body.region !== undefined) user.region = str(body.region, 40);
    if (body.gender !== undefined) user.gender = normalizeGender(body.gender);
    /* 生日：对应功能清单里的「生日」（个人资料里能改） */
    if (body.birthday !== undefined) {
      const b = str(body.birthday, 20);
      user.birthday = /^\d{4}-\d{2}-\d{2}$/.test(b) ? b : '';
    }
    /* 头像/封面/聊天背景存的都是 /uploads 路径或短网址，2 千字符足够；
       以前允许 30 万字符，一个人就能把 users.json 撑到几百 MB。 */
    if (body.avatar !== undefined) {
      const v = safeImageRef(str(body.avatar, 2000));
      if (v === null) return fail(res, 422, '头像只能用 App 上传的图片');
      user.avatar = v;
    }
    if (body.alipay !== undefined) user.alipay = str(body.alipay, 60).replace(/\s/g, '');
    if (body.alipayQr !== undefined) {
      const v = safeImageRef(str(body.alipayQr, 2000));
      if (v === null) return fail(res, 422, '收款码只能用 App 上传的图片');
      user.alipayQr = v;
    }
    if (body.phone !== undefined) {
      const next = str(body.phone, 20).replace(/[^0-9+]/g, '');
      const pure = next.replace(/^\+?86/, '');
      if (!/^1[3-9]\d{9}$/.test(pure) && !/^\d{6,20}$/.test(pure)) return fail(res, 422, '手机号格式不对，要 11 位手机号');
      const YEAR_MS = 365 * 24 * 60 * 60 * 1000;
      const last = user.phoneUpdatedAt ? new Date(user.phoneUpdatedAt).getTime() : 0;
      if (last && Date.now() - last < YEAR_MS) {
        const can = new Date(last + YEAR_MS);
        return fail(res, 429, '手机号一年只能改一次，下次可改：' + can.getFullYear() + '年' + (can.getMonth() + 1) + '月' + can.getDate() + '日');
      }
      if (pure !== (user.phone || '')) {
        user.phone = pure;
        user.phoneUpdatedAt = now();
      }
    }
    if (body.moodText !== undefined || body.moodIcon !== undefined
        || body.moodLabel !== undefined || body.moodCaption !== undefined) {
      /* 微信那套：状态 24 小时自动过期；「说点什么」最多 30 字；选完记一下时间。
         状态名（moodLabel，后台配的「摸鱼」这种）和自定义文案（moodCaption）分开存，
         moodText 留「拿来展示的那一句」给所有页面用（有文案用文案，没文案用状态名）。 */
      const label = str(body.moodLabel !== undefined ? body.moodLabel : body.moodText, 20);
      const caption = str(body.moodCaption, 30);
      user.moodLabel = label;
      user.moodCaption = caption;
      user.moodText = caption || label;
      user.moodIcon = str(body.moodIcon, 8);
      if (user.moodText || user.moodIcon) {
        /* 换了状态名/图标才重新计时（24 小时）；只改「说点什么」不动到期时间 */
        const key = (user.moodIcon || '') + '|' + label;
        if (user.moodKey !== key) {
          user.moodKey = key;
          user.moodAt = now();
          user.moodExpiresAt = Date.now() + 24 * 60 * 60 * 1000;
          user.moodViews = [];
        } else if (!Number(user.moodExpiresAt)) {
          user.moodExpiresAt = Date.now() + 24 * 60 * 60 * 1000;
        }
      } else {
        user.moodAt = '';
        user.moodExpiresAt = 0;
        user.moodViews = [];
        user.moodKey = '';
      }
      if (body.moodColor !== undefined) {
        const mc = str(body.moodColor, 9);
        user.moodColor = /^#[0-9a-f]{6}$/i.test(mc) ? mc : '';
      }
      if (body.moodColor2 !== undefined) {
        const mc2 = str(body.moodColor2, 9);
        user.moodColor2 = /^#[0-9a-f]{6}$/i.test(mc2) ? mc2 : '';
      }
      if (!user.moodText) user.moodColor = '';
      if (!user.moodText) user.moodColor2 = '';
    }
    if (body.momentCover !== undefined) {
      const v = safeImageRef(str(body.momentCover, 2000));
      if (v === null) return fail(res, 422, '朋友圈封面只能用 App 上传的图片');
      user.momentCover = v;
    }
    if (body.momentCoverPos !== undefined) {
      const p = Number(body.momentCoverPos);
      user.momentCoverPos = isFinite(p) ? Math.min(100, Math.max(0, Math.round(p))) : 50;
    }
    if (body.chatBackground !== undefined) {
      const v = safeImageRef(str(body.chatBackground, 2000));
      if (v === null) return fail(res, 422, '聊天背景只能用 App 上传的图片');
      user.chatBackground = v === 'auto' ? 'auto' : v;
    }
    saveUsers();
    // 改了资料：好友那边和自己在别的设备上都能立刻看到新头像 / 新名字
    friendIds(user.id).forEach((fid) => sendTo(fid, { type: 'profile', user: publicUser(user) }));
    sendTo(user.id, { type: 'profile', user: publicUser(user) });
    /* 换了头像：把 TA 所在的群头像（九宫格）重拼一遍，否则群里还是旧头像 */
    if (body.avatar !== undefined) {
      db.chats.filter((c) => c.type === 'group' && (c.memberIds || []).indexOf(user.id) >= 0)
        .forEach((c) => { if (refreshGroupAvatar(c)) { saveChats(); } });
    }
    ok(res, { user: Object.assign(publicUser(user), { phone: user.phone || '', phoneUpdatedAt: user.phoneUpdatedAt || '' }) });
    return;
  }

  // 单个用户资料（微信名片用）
  // 安全中心：登录记录 / 安全评分
  // 修改密码（会踢掉其他设备）
  if (parts[0] === 'me' && parts[1] === 'password' && method === 'POST') {
    const body = await readBody(req);
    const curPwd = String(body.currentPassword || '');
    const nextPwd = String(body.newPassword || '');
    if (!verifyPassword(user, curPwd)) return fail(res, 401, '当前密码不正确');
    if (nextPwd.length < 6) return fail(res, 422, '新密码至少 6 位');
    if (nextPwd === curPwd) return fail(res, 422, '新密码不能和当前密码一样');
    const salt = crypto.randomBytes(16).toString('hex');
    user.salt = salt;
    user.passwordHash = hashPassword(nextPwd, salt);
    user.passwordUpdatedAt = now();
    user.tokenVersion = (user.tokenVersion || 0) + 1;
    saveUsers();
    recordSecurity(user.id, req, 'password');
    ok(res, { updated: true },
      { 'Set-Cookie': sessionCookie(signToken(user.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* 银行卡：列表 / 绑定 / 解绑（对应功能清单里的「银行卡 / 绑定银行卡」） */
  /* 隐私设置：读 / 改（没设过就是默认值） */
  if (parts[0] === 'me' && parts[1] === 'privacy' && method === 'GET') {
    ok(res, { privacy: userPrivacy(user), notify: userNotify(user) });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'privacy' && method === 'PATCH') {
    const body = await readBody(req);
    const next = userPrivacy(user);
    ['needVerify', 'strangerMoments', 'addByWx', 'addByPhone', 'addByGroup', 'addByQR'].forEach((k) => {
      if (body[k] !== undefined) next[k] = !!body[k];
    });
    user.privacy = next;
    saveUsers();
    ok(res, { privacy: next });
    return;
  }

  /* 消息通知设置：开不开、声音、振动、显示详情、免打扰时段 */
  if (parts[0] === 'me' && parts[1] === 'notify' && method === 'PATCH') {
    const body = await readBody(req);
    const next = userNotify(user);
    ['on', 'sound', 'vibrate', 'showDetail'].forEach((k) => {
      if (body[k] !== undefined) next[k] = !!body[k];
    });
    ['muteStart', 'muteEnd'].forEach((k) => {
      if (body[k] !== undefined) {
        const v = str(body[k], 5);
        next[k] = /^\d{2}:\d{2}$/.test(v) ? v : '';
      }
    });
    user.notify = next;
    saveUsers();
    ok(res, { notify: next });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'bankcards' && method === 'GET') {
    ok(res, { cards: (user.bankCards || []).map(maskBankCard) });
    return;
  }
  /* 绑卡时能选的银行（名字 + 品牌色）：App 和网页共用一份，后台不用配 */
  if (parts[0] === 'banks' && method === 'GET') {
    ok(res, { banks: BANK_LIST });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'bankcards' && method === 'POST') {
    const body2 = await readBody(req);
    let bank = str(body2.bank, 20);
    const number = String(body2.number || '').replace(/\s/g, '');
    const holder = str(body2.holder, 20);
    const idCard = str(body2.idCard, 20);
    const phone = String(body2.phone || '').replace(/\D/g, '');
    let cardType = String(body2.type || '').trim();
    if (!/^\d{16,19}$/.test(number)) return fail(res, 422, '卡号要 16~19 位数字');
    /* 微信那套：先按卡号认银行，认不出来才让用户自己选 */
    const guess = guessBankByCardNo(number);
    if (!bank) bank = guess.name;
    if (!bank) return fail(res, 422, '这张卡没认出来，自己选一下银行');
    if (!cardType) cardType = /^(62|62[0-9])/.test(number) && /^(4|5)/.test(number.slice(1)) ? '储蓄卡' : '储蓄卡';
    cardType = (cardType === '信用卡') ? '信用卡' : '储蓄卡';
    if (!holder) return fail(res, 422, '请填写持卡人姓名');
    const cards = Array.isArray(user.bankCards) ? user.bankCards.slice() : [];
    if (cards.length >= 10) return fail(res, 422, '最多绑定 10 张银行卡');
    const tail = number.slice(-4);
    if (cards.some((c) => c.tail === tail && c.bank === bank)) return fail(res, 409, '这张卡已经绑过了');
    /* 微信要求实名一致：填了身份证就跟已实名的姓名对一下 */
    if (user.realName && holder && user.realName !== holder) {
      return fail(res, 422, '持卡人要和实名信息一致（实名是「' + user.realName + '」），只能绑本人的卡');
    }
    const lv = walletLevelInfo(user);
    cards.push({
      id: uid('bc'), bank: bank, number: number, tail: tail, holder: holder,
      type: cardType, idCardTail: idCard ? String(idCard).slice(-4) : '',
      phoneMask: phone.length === 11 ? (phone.slice(0, 3) + '****' + phone.slice(7)) : '',
      noPin: false,                       // 免密支付默认关（微信也是默认关）
      single: lv.single, day: lv.day,     // 这张卡的额度跟着账户等级走
      addedAt: now()
    });
    user.bankCards = cards;
    saveUsers();
    ok(res, { cards: cards.map(maskBankCard) });
    return;
  }
  /* 卡详情里改「免密支付」开关（微信那张卡点进去就这一个开关） */
  if (parts[0] === 'me' && parts[1] === 'bankcards' && parts[2] && method === 'PATCH') {
    const body3 = await readBody(req);
    const id = str(parts[2], 40);
    const card = (user.bankCards || []).find((c) => c.id === id);
    if (!card) return fail(res, 404, '这张卡不在了');
    if (body3.noPin !== undefined) card.noPin = !!body3.noPin;
    saveUsers();
    ok(res, { card: maskBankCard(card) });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'bankcards' && parts[2] && method === 'DELETE') {
    const id = str(parts[2], 40);
    const card = (user.bankCards || []).find((c) => c.id === id);
    if (!card) return fail(res, 404, '这张卡不在了');
    if (pendingWithdrawToTail(user, card.tail)) {
      return fail(res, 422, '这张卡上还有正在提现的钱，等到账后再解绑');
    }
    user.bankCards = (user.bankCards || []).filter((c) => c.id !== id);
    saveUsers();
    ok(res, { cards: user.bankCards.map(maskBankCard) });
    return;
  }

  /* 意见反馈：写进 data/feedback.jsonl，后台「用户反馈」里能看 */
  if (parts[0] === 'feedback' && method === 'POST') {
    const body = await readBody(req);
    const content = str(body.content, 1000);
    if (!content) return fail(res, 422, '先写点要反馈的内容');
    const row = {
      id: uid('fb'), userId: user.id, username: user.username, nickname: user.nickname,
      contact: str(body.contact, 60), platform: str(body.platform, 20),
      content: content, createdAt: now()
    };
    try {
      fs.appendFileSync(path.join(DATA_DIR, 'feedback.jsonl'), JSON.stringify(row) + '\n', 'utf8');
    } catch (err) { return fail(res, 500, '提交失败，稍后再试'); }
    ok(res, { sent: true, id: row.id });
    return;
  }

  // 退出其他所有设备
  if (parts[0] === 'me' && parts[1] === 'logout-others' && method === 'POST') {
    user.tokenVersion = (user.tokenVersion || 0) + 1;
    saveUsers();
    recordSecurity(user.id, req, 'logout-others');
    ok(res, { loggedOut: true },
      { 'Set-Cookie': sessionCookie(signToken(user.id), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* 手机把自己拿到的 APNs device token 报上来（App 启动 + 登录后各报一次） */
  if (parts[0] === 'push' && parts[1] === 'register' && method === 'POST') {
    const body = await readBody(req);
    const token = str(body.token, 200).replace(/[^0-9a-fA-F]/g, '').toLowerCase();
    if (token.length < 32) return fail(res, 422, '推送 token 不合法');
    const p = readPush();
    const env = str(body.env, 10) === 'sandbox' ? 'sandbox' : 'prod';
    const list = p.tokens[user.id] || (p.tokens[user.id] = []);
    const exist = list.find((d) => d.token === token);
    if (exist) { exist.env = env; exist.updatedAt = now(); }
    else list.push({ token, env, platform: str(body.platform, 12) || 'ios', updatedAt: now() });
    /* 同一台手机换个账号登录：token 从旧账号名下摘掉，免得推给错的人 */
    Object.keys(p.tokens).forEach((uid) => {
      if (uid === user.id) return;
      p.tokens[uid] = p.tokens[uid].filter((d) => d.token !== token);
      if (!p.tokens[uid].length) delete p.tokens[uid];
    });
    if (p.tokens[user.id] && p.tokens[user.id].length > 5) p.tokens[user.id] = p.tokens[user.id].slice(-5);
    savePush();
    ok(res, { registered: true, devices: (p.tokens[user.id] || []).length });
    return;
  }

  /* 手机把「通知权限开没开 / 标记开没开」报上来：桌面图标没数字时，后台一眼看出卡在哪 */
  if (parts[0] === 'push' && parts[1] === 'settings' && method === 'POST') {
    const body = await readBody(req);
    const p = readPush();
    if (!p.settings) p.settings = {};
    p.settings[user.id] = {
      status: str(body.status, 20) || 'unknown',
      badge: body.badge !== false,
      alert: body.alert !== false,
      sound: body.sound !== false,
      env: str(body.env, 10) === 'sandbox' ? 'sandbox' : 'prod',
      at: now()
    };
    savePush();
    pushLog({
      userId: user.id, kind: 'settings',
      title: '通知设置：' + p.settings[user.id].status + (p.settings[user.id].badge ? ' · 标记开' : ' · 标记关')
    });
    ok(res, { saved: true });
    return;
  }

  /* 退出登录时不推了 */
  if (parts[0] === 'push' && parts[1] === 'unregister' && method === 'POST') {
    const body = await readBody(req);
    const token = str(body.token, 200).replace(/[^0-9a-fA-F]/g, '').toLowerCase();
    if (token) pushRemoveToken(user.id, token);
    ok(res, { removed: true });
    return;
  }

  /* 自检：推送配好了没、这台手机在服务器上登记过没 */
  if (parts[0] === 'push' && parts[1] === 'status' && method === 'GET') {
    const p = readPush();
    ok(res, {
      configured: pushReady(),
      enabled: !!p.config.enabled,
      sandbox: !!p.config.sandbox,
      devices: (p.tokens[user.id] || []).length
    });
    return;
  }

  if (parts[0] === 'users' && parts.length === 2 && method === 'GET') {
    const u = findUser(parts[1]);
    if (!u) return fail(res, 404, '用户不存在');
    /* 别人点开我的资料：如果我有状态，就记一笔「他看过」（微信里点自己的状态能看到「X 人看过」） */
    if (u.id !== user.id && moodAlive(u) && friendshipBetween(user.id, u.id)) {
      try {
        const views = (Array.isArray(u.moodViews) ? u.moodViews : []).filter((v) => v.userId !== user.id);
        views.push({ userId: user.id, at: now() });
        u.moodViews = views.slice(-50);
        saveUsers();
      } catch (e) { }
    }
    const f = friendshipBetween(user.id, u.id);
    const isFriend = !!(f && f.status === 'accepted');
    const online = onlineUserIds();
    const meta = metaOf(user.id, u.id);
    const addedAt = f ? (f.respondedAt || f.createdAt || '') : '';
    ok(res, {
      user: Object.assign(memberProfile(u, user.id), {
        relation: !f ? (u.id === user.id ? 'self' : 'none') : (f.status === 'accepted' ? 'friend' : (f.fromId === user.id ? 'requested' : 'incoming')),
        online: online.includes(u.id),
        banned: !!u.banned,
        momentCount: db.moments.filter((m) => m.authorId === u.id).length,
        phone: (u.id === user.id || isFriend) ? (u.phone || '') : '',
        alipay: (u.id === user.id || isFriend) ? (u.alipay || '') : '',
        mutualGroups: db.chats.filter((c) => c.type === 'group' && c.memberIds.includes(user.id) && c.memberIds.includes(u.id)).length,
        /* 我给他设的朋友资料（备注名/标签/星标/朋友权限）+ 好友关系的来源和添加时间 */
        remark: meta.remark || '',
        realNickname: u.nickname || u.username || '',
        tags: meta.tags || [],
        star: meta.star === true,
        block: meta.block === true,
        noMoments: meta.noMoments === true,
        chatOnly: meta.chatOnly === true,
        addedAt,
        source: f && f.fromId === user.id ? 'me' : (f ? 'them' : '')
      }, (meta.remark && String(meta.remark).trim()) ? { nickname: String(meta.remark).trim() } : {})
    });
    return;
  }

  if (parts[0] === 'users' && method === 'GET') {
    const q = str(query.get('q'), 24).toLowerCase();
    if (!q) return ok(res, { users: [] });            // 空搜索不再把全站用户吐出来
    if (!searchRateAllow(user.id)) return fail(res, 429, '搜索太频繁了，歇一下再搜');
    const online = onlineUserIds();
    const myFriends = friendSetCached(user.id);
    /* 仿微信：微信号 / 手机号要完全对上才出结果，靠字母表一个个扫扫不出来。
       另外补一条：**完整昵称**也能搜到（新用户注册完只知道自己叫什么，
       光靠微信号搜不到人）。自己的好友额外允许昵称模糊匹配。 */
    const exact = (u) => String(u.username || '').toLowerCase() === q
      || String(u.phone || '') === q
      || String(u.nickname || '').toLowerCase() === q;
    let matched = secCfg().strictSearch
      ? db.users.filter((u) => u.id !== user.id && exact(u))
      : db.users.filter((u) => u.id !== user.id &&
          (String(u.username || '').toLowerCase().includes(q) || String(u.nickname || '').toLowerCase().includes(q)));
    if (!matched.length && secCfg().strictSearch) {
      matched = db.users.filter((u) => u.id !== user.id && myFriends.has(u.id) &&
        (String(u.nickname || '').toLowerCase().includes(q) || String(u.username || '').toLowerCase().includes(q)));
    }
    const list = matched.slice(0, 20).map((u) => {
        const f = friendshipBetween(user.id, u.id);
        return Object.assign(publicUserBrief(u, user.id, myFriends), {
          relation: !f ? 'none' : (f.status === 'accepted' ? 'friend' : (f.fromId === user.id ? 'requested' : 'incoming')),
          online: online.includes(u.id)
        });
      });
    ok(res, { users: list });
    return;
  }

  if (parts[0] === 'contacts' && method === 'GET') {
    const online = onlineUserIds();
    const friends = friendIds(user.id).map((id) => {
      const u = findUser(id);
      if (!u) return null;
      /* 好友列表带上「我给他设的资料」：备注名、标签、星标、拉黑、不看朋友圈。
         备注名直接替换昵称 —— 老版本 App 不装包也能看到备注生效。 */
      const m = metaOf(user.id, id);
      return Object.assign(publicUser(u), {
        online: online.includes(id),
        realNickname: u.nickname || u.username || '',
        remark: m.remark || '',
        tags: m.tags || [],
        star: m.star === true,
        block: m.block === true,
        noMoments: m.noMoments === true
      }, (m.remark && String(m.remark).trim()) ? { nickname: String(m.remark).trim() } : {});
    }).filter(Boolean);
    const incoming = db.friendships
      .filter((f) => f.toId === user.id && f.status === 'pending')
      .map((f) => Object.assign({ requestId: f.id, createdAt: f.createdAt, requestMessage: f.note || '' },
        publicUserBrief(findUser(f.fromId), user.id)));
    const outgoing = db.friendships
      .filter((f) => f.fromId === user.id && f.status === 'pending')
      .map((f) => Object.assign({ requestId: f.id, createdAt: f.createdAt, requestMessage: f.note || '' },
        publicUserBrief(findUser(f.toId), user.id)));
    /* 刚通过的那几个人：微信上会留在「新的朋友」里显示「已添加」，保留 3 天 */
    const added = db.friendships
      .filter((f) => f.toId === user.id && f.status === 'accepted'
        && (Date.parse(f.respondedAt || f.createdAt) || 0) > Date.now() - 3 * 86400000)
      .sort((a, b) => String(b.respondedAt || b.createdAt).localeCompare(String(a.respondedAt || a.createdAt)))
      .slice(0, 30)
      .map((f) => {
        const u = findUser(f.fromId);
        if (!u) return null;
        return Object.assign({ requestId: f.id, createdAt: f.createdAt, requestMessage: f.note || '' },
          publicUserBrief(u, user.id));
      })
      .filter(Boolean);
    ok(res, { friends, incoming, outgoing, added });
    return;
  }

  if (parts[0] === 'friends' && parts[1] === 'request' && method === 'POST') {
    const body = await readBody(req);
    const target = str(body.username, 24) ? findUserByName(body.username) : findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    if (target.id === user.id) return fail(res, 422, '不能添加自己');
    /* 风控：被临时限制的账号先挡住；加得太快记一笔（营销号/养号特征） */
    const fReqBlocked = riskBlocked(user);
    if (fReqBlocked) return fail(res, 429, '账号功能被临时限制，还有 ' + fReqBlocked + ' 分钟（如有疑问请联系管理员）');
    noteFriendReqRisk(user);
    /* 隐私：对方关掉「通过微信号找到我」就不给加（手机号那条走注册/绑定那条路） */
    const tp = userPrivacy(target);
    if (str(body.username, 24) && !tp.addByWx) return fail(res, 403, '对方关闭了「通过微信号添加我」');
    /* 从群里点人加好友：对方关了「通过群聊添加我」也拦 */
    if (str(body.from, 12) === 'group' && !tp.addByGroup) return fail(res, 403, '对方关闭了「通过群聊添加我」');
    const exist = friendshipBetween(user.id, target.id);
    if (exist) {
      if (exist.status === 'accepted') return fail(res, 409, '你们已经是好友');
      if (exist.fromId === user.id) return fail(res, 409, '已经发送过好友请求');
      exist.status = 'accepted';
      exist.respondedAt = now();
      saveFriendships();
      /* 互相加好友（对方先加过我）：同样立刻在两个人的「微信」首页开出会话 */
      const c2 = openChatForFriendship(exist.fromId, exist.toId);
      sendTo(target.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(exist.fromId, { type: 'chat', chatId: c2 ? c2.id : '' });
      sendTo(exist.toId, { type: 'chat', chatId: c2 ? c2.id : '' });
      return ok(res, { accepted: true, friend: publicUser(target) });
    }
    /* 对方关了「加我为朋友时需要验证」→ 直接变成好友，不再等他点同意 */
    if (!tp.needVerify) {
      const auto = { id: uid('f'), fromId: target.id, toId: user.id, status: 'accepted', createdAt: now(),
        respondedAt: now() };
      db.friendships.push(auto);
      saveFriendships();
      const c0 = openChatForFriendship(target.id, user.id);
      sendTo(target.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(user.id, { type: 'chat', chatId: c0 ? c0.id : '' });
      sendTo(target.id, { type: 'chat', chatId: c0 ? c0.id : '' });
      return ok(res, { accepted: true, friend: publicUser(target) });
    }
    /* 微信那套：申请里那句「我是XXX」要留着，「新的朋友」页上要显示出来 */
    const f = { id: uid('f'), fromId: user.id, toId: target.id, status: 'pending', createdAt: now(),
      note: str(body.message, 60) };
    db.friendships.push(f);
    saveFriendships();
    sendTo(target.id, { type: 'friend', action: 'request', requestId: f.id, user: publicUser(user) });
    /* 对方手机没连着 → 推一条「新的朋友」 */
    pushToUser(target.id, {
      kind: 'friend',
      title: '新的朋友',
      body: (user.nickname || user.username || '有人') + ' 请求添加你为好友' + (f.note ? '：' + f.note : '')
    }).catch(() => { });
    ok(res, { requestId: f.id, to: publicUser(target) });
    return;
  }

  /* 朋友资料：备注名 / 标签 / 星标 / 朋友权限 / 拉黑（微信「设置备注和标签」那一套） */
  if (parts[0] === 'friends' && parts[1] === 'meta' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    if (target.id === user.id) return fail(res, 422, '不能给自己设备注');
    const patch = {};
    if (body.remark !== undefined) patch.remark = str(body.remark, 24).trim();
    if (body.tags !== undefined) {
      const raw = Array.isArray(body.tags) ? body.tags
        : String(body.tags || '').split(/[，,\s]+/).filter(Boolean);
      patch.tags = raw.map((t) => String(t).trim()).filter(Boolean).slice(0, 10);
    }
    ['star', 'block', 'noMoments', 'chatOnly', 'hideMyMoments'].forEach((k) => {
      if (body[k] !== undefined) patch[k] = !!body[k];
    });
    const saved = setMeta(user.id, target.id, patch);
    /* 拉黑/取消拉黑：会话、通讯录、对方那边都要跟着变 */
    sendTo(user.id, { type: 'friend', action: 'meta', userId: target.id });
    ok(res, {
      meta: {
        remark: saved.remark || '', tags: saved.tags || [],
        star: saved.star === true, block: saved.block === true,
        noMoments: saved.noMoments === true, chatOnly: saved.chatOnly === true
      }
    });
    return;
  }

  if (parts[0] === 'friends' && parts[1] === 'meta' && method === 'GET') {
    const target = findUser(str(query.get('userId'), 40));
    if (!target) return fail(res, 404, '用户不存在');
    const f = friendshipBetween(user.id, target.id);
    const m = metaOf(user.id, target.id);
    ok(res, {
      meta: {
        remark: m.remark || '', tags: m.tags || [],
        star: m.star === true, block: m.block === true,
        noMoments: m.noMoments === true, chatOnly: m.chatOnly === true,
        hideMyMoments: m.hideMyMoments === true
      },
      addedAt: f ? (f.respondedAt || f.createdAt || '') : '',
      source: f && f.fromId === user.id ? 'me' : (f ? 'them' : ''),
      blockedMe: blockedByUser(target.id, user.id)
    });
    return;
  }

  /* 删除好友（微信：对方还在你的列表里，只是彼此不再是好友，聊天记录可选删） */
  if (parts[0] === 'friends' && parts[1] === 'remove' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    const f = friendshipBetween(user.id, target.id);
    if (!f) return fail(res, 404, '你们还不是好友');
    db.friendships = db.friendships.filter((x) => x.id !== f.id);
    saveFriendships();
    /* 只动我这边：把会话从我的列表里藏掉（对方那边不受影响，微信就是这样） */
    const chat = db.chats.find((c) => c.type === 'direct' && c.memberIds.includes(user.id) && c.memberIds.includes(target.id));
    if (chat) {
      if (!Array.isArray(chat.hiddenFor)) chat.hiddenFor = [];
      if (!chat.hiddenFor.includes(user.id)) chat.hiddenFor.push(user.id);
      chatsDirty = true;
      sendTo(user.id, { type: 'chat', action: 'deleted', chatId: chat.id });
    }
    /* 备注之类的一并清掉 */
    const dbm = readFriendMeta();
    if (dbm.byOwner[user.id]) {
      delete dbm.byOwner[user.id][target.id];
      saveFriendMeta();
    }
    sendTo(user.id, { type: 'friend', action: 'removed', userId: target.id });
    ok(res, { removed: true });
    return;
  }

  if (parts[0] === 'friends' && parts[1] === 'respond' && method === 'POST') {
    const body = await readBody(req);
    const f = db.friendships.find((x) => x.id === str(body.requestId, 40));
    if (!f || f.toId !== user.id || f.status !== 'pending') return fail(res, 404, '好友请求不存在');
    if (body.accept) {
      f.status = 'accepted';
      f.respondedAt = now();
      saveFriendships();
      /* 通过好友以后，两个人的「微信」首页立刻各多一个会话（不用等谁先说话） */
      const newChat = openChatForFriendship(f.fromId, f.toId);
      /* 和微信一样：通过以后聊天里留一条系统提示 */
      try {
        const fromUser = findUser(f.fromId);
        const toUser = findUser(f.toId);
        if (newChat && fromUser && toUser) {
          pushSystemMessage(newChat, '你已添加了' + (fromUser.nickname || fromUser.username)
            + '，现在可以开始聊天了');
        }
      } catch (e) { /* 提示加不上不影响通过 */ }
      sendTo(f.fromId, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(f.fromId, { type: 'chat', chatId: newChat ? newChat.id : '' });
      sendTo(f.toId, { type: 'chat', chatId: newChat ? newChat.id : '' });
      ok(res, { accepted: true, friend: publicUser(findUser(f.fromId)) });
    } else {
      db.friendships = db.friendships.filter((x) => x.id !== f.id);
      saveFriendships();
      ok(res, { rejected: true });
    }
    return;
  }

  if (parts[0] === 'chats' && method === 'GET' && parts.length === 1) {
    // 一次把最近几个会话的消息也带上：登录时「同步最近的聊天记录」用的就是这个
    if (query.get('withMessages') === '1') {
      const chatCount = Math.min(30, Math.max(1, Number(query.get('syncChats')) || 10));
      const perChat = Math.min(100, Math.max(5, Number(query.get('syncLimit')) || 30));
      /* 和普通列表一样排序：置顶 → 贾维斯AI → 其它机器人 → 按时间 */
      const sortChats = (arr) => arr.slice().sort((a, b) => {
        const pa = (a.pinnedFor || []).includes(user.id), pb = (b.pinnedFor || []).includes(user.id);
        if (pa !== pb) return pa ? -1 : 1;
        const rankOf = (c) => {
          if (c.type !== 'direct') return 9;
          const other = findUser(c.memberIds.find((id) => id !== user.id) || '');
          if (!other || !other.bot) return 9;
          return other.username === 'housekeeper' ? 0 : (other.username === AI_USERNAME ? 1 : 2);
        };
        const ra = rankOf(a), rb = rankOf(b);
        if (ra !== rb) return ra - rb;
        return String(b.updatedAt).localeCompare(String(a.updatedAt));
      });
      const mine = sortChats(chatsOf(user.id).slice());
      const list = mine.map((c) => chatSummary(c, user.id));
      const batch = mine.slice(0, chatCount).map((c) => ({
        id: c.id,
        title: chatSummary(c, user.id).title,
        messages: loadMessages(c.id).slice(-perChat).map((m) => Object.assign({}, m, {
          senderName: displayNameFor(user.id, findUser(m.senderId)),
          senderAvatar: (findUser(m.senderId) || {}).avatar || ''
        }))
      }));
      ok(res, { chats: list, sync: { chats: batch, syncedAt: now() } });
      return;
    }
    const list = chatsOf(user.id)
      .map((c) => chatSummary(c, user.id))
      .sort((a, b) => {
        if (!!a.pinned !== !!b.pinned) return a.pinned ? -1 : 1;   // 置顶会话永远在最上面（QQ 就是这样）
        const ra = a.botRank == null ? 9 : a.botRank, rb = b.botRank == null ? 9 : b.botRank;
        if (ra !== rb) return ra - rb;                            // 贾维斯AI 固定第一，其次其它机器人
        return String(b.updatedAt).localeCompare(String(a.updatedAt));
      });
    ok(res, { chats: list });
    return;
  }

  if (parts[0] === 'chats' && parts[1] === 'direct' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    // 自己给自己发消息也允许（名片里的「发消息」按钮）
    if (target.id !== user.id && !friendIds(user.id).includes(target.id) && !readIm().allowStranger) {
      return fail(res, 403, '先加为好友才能聊天');
    }
    let chat = directChatBetween(user.id, target.id);
    if (!chat) {
      chat = {
        id: uid('c'), type: 'direct', name: '', avatar: '',
        memberIds: [user.id, target.id], ownerId: user.id, seq: 0, createdAt: now()
      };
      db.chats.push(chat);
      saveChats();
      sendTo(target.id, { type: 'chat', action: 'created', chat: chatSummary(chat, target.id) });
    }
    ok(res, { chat: chatSummary(chat, user.id) });
    return;
  }

  if (parts[0] === 'chats' && parts[1] === 'group' && method === 'POST') {
    const body = await readBody(req);
    const im = readIm();
    if (!im.allowCreateGroup) return fail(res, 403, '管理员关闭了建群');
    const name = str(body.name, 30);
    if (!name) return fail(res, 422, '请填写群名称');
    const allowed = friendIds(user.id);
    const ids = (Array.isArray(body.memberIds) ? body.memberIds : [])
      .map((x) => str(x, 40))
      .filter((id) => id && id !== user.id && findUser(id) && allowed.includes(id));
    const members = Array.from(new Set([user.id].concat(ids)));
    if (members.length < 2) return fail(res, 422, '至少选择一个好友');
    if (members.length > im.maxGroupMembers) return fail(res, 422, '群人数最多 ' + im.maxGroupMembers + ' 人');
    const chat = {
      id: uid('c'), type: 'group', name, avatar: str(body.avatar, 300000),
      memberIds: members, ownerId: user.id, seq: 0, createdAt: now()
    };
    db.chats.push(chat);
    /* 没自带群头像就按成员头像拼一张九宫格（微信那种效果） */
    if (!chat.avatar) buildGroupAvatar(chat);
    saveChats();
    members.forEach((id) => {
      if (id !== user.id) sendTo(id, { type: 'chat', action: 'created', chat: chatSummary(chat, id) });
    });
    ok(res, { chat: chatSummary(chat, user.id) });
    return;
  }

  /* -------------------------------------------------------- 面对面建群 */
  // 微信那种：大家输入同一个 4 位数字，就进同一个群；数字 3 分钟内有效
  if (parts[0] === 'chats' && parts[1] === 'face' && method === 'POST') {
    const body = await readBody(req);
    const code = String(body.code == null ? '' : body.code).trim();
    if (!/^[0-9]{4}$/.test(code)) return fail(res, 422, '请输入 4 位数字');
    /* 安全：4 位数字只有 1 万种，脚本一路试过去，几十秒就能撞进别人的面对面群。
       所以每人 10 分钟最多试 10 次（正常建群一次就够）。 */
    if (!faceCodeRateAllow(user.id)) {
      strikeIp(clientInfo(req).ip, '狂试面对面群码');
      return fail(res, 429, '试得太频繁了，10 分钟后再建群');
    }
    const t = Date.now();
    pruneFaceRooms();
    let room = db.faceRooms.find((r) => r.code === code && r.expiresAt > t) || null;
    let chat = room ? db.chats.find((c) => c.id === room.chatId) : null;
    if (room && !chat) {
      db.faceRooms = db.faceRooms.filter((r) => r !== room);
      room = null;
    }
    let created = false;
    let joined = false;
    if (!room) {
      chat = {
        id: uid('c'), type: 'group', name: '面对面建群 · ' + code, avatar: '',
        memberIds: [user.id], ownerId: user.id, seq: 0, createdAt: now(), faceCode: code
      };
      db.chats.push(chat);
      room = { code, chatId: chat.id, createdAt: now(), expiresAt: t + FACE_ROOM_WINDOW_MS, joinedCount: 1 };
      db.faceRooms.push(room);
      created = true;
    } else {
      room.expiresAt = t + FACE_ROOM_WINDOW_MS; // 每次有人进来，有效期重新计时
      if (!chat.memberIds.includes(user.id)) {
        chat.memberIds.push(user.id);
        room.joinedCount = (room.joinedCount || chat.memberIds.length) + 1;
        joined = true;
      }
    }
    if (created || joined) {
      chat.seq = (chat.seq || 0) + 1;
      /* 群成员变了：重拼一次九宫格群头像（面对面建群也是一样） */
      buildGroupAvatar(chat);
      const text = created ? '你创建了面对面群聊（数字 ' + code + '）'
        : (user.nickname + ' 通过面对面建群加入，数字 ' + code);
      const sysMsg = {
        id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
        kind: 'system', content: text, createdAt: now(), recalled: false
      };
      appendMessage(chat.id, sysMsg);
      chat.memberIds.forEach((id) => {
        sendTo(id, { type: 'message', message: sysMsg, chat: chatSummary(chat, id), clientId: null });
      });
    }
    saveChats();
    saveFaceRooms();
    if (joined) {
      chat.memberIds.forEach((id) => {
        if (id === user.id) return;
        sendTo(id, {
          type: 'chat', action: 'created', chat: chatSummary(chat, id),
          notice: user.nickname + ' 通过面对面建群加入了群聊'
        });
      });
    }
    ok(res, {
      chat: chatSummary(chat, user.id),
      created, joined,
      memberCount: chat.memberIds.length,
      expiresIn: Math.max(0, Math.round((room.expiresAt - Date.now()) / 1000))
    });
    return;
  }

  // 置顶 / 取消置顶会话（只对自己生效，QQ 右键菜单里的「置顶会话」）
  if (parts[0] === 'chats' && parts[2] === 'pin' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    const body = await readBody(req);
    const set = new Set(chat.pinnedFor || []);
    const hasBot = chat.memberIds.map(findUser).some((u) => u && u.bot);
    if (hasBot) {
      set.add(user.id);                       // 机器人会话永远置顶，取消不了
    } else if (body.pinned === false) {
      set.delete(user.id);
    } else {
      set.add(user.id);
    }
    chat.pinnedFor = Array.from(set);
    saveChats();
    ok(res, { pinned: chat.pinnedFor.includes(user.id), forced: hasBot });
    return;
  }

  // 删除会话：只从自己的列表里移除（对齐 QQ 的右键删除），对方不受影响
  if (parts[0] === 'chats' && parts.length === 2 && method === 'DELETE') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    /* 贾维斯AI / AI 助手 / 腾讯新闻：会话固定置顶，不能被「不显示」或「删除」藏起来 */
    const botPeer = chat.memberIds.filter((id) => id !== user.id)
      .map((id) => findUser(id)).find((u) => u && u.bot);
    if (botPeer) {
      chat.hiddenFor = (chat.hiddenFor || []).filter((id) => id !== user.id);
      const set = new Set(chat.pinnedFor || []);
      if (!set.has(user.id)) set.add(user.id);
      chat.pinnedFor = Array.from(set);
      saveChats();
      return fail(res, 400, (botPeer.nickname || '机器人') + '的会话不能删，它是自动置顶的');
    }
    chat.hiddenFor = Array.from(new Set((chat.hiddenFor || []).concat([user.id])));
    saveChats();
    ok(res, { hidden: true, chatId: chat.id });
    return;
  }

  /* ============================================================
     聊天记录导出 / 导入（微信的「聊天记录迁移与备份」）
       导出 GET  /api/chats/export?chatId=xxx&format=json|txt
             不带 chatId 就是导出全部；JSON 可以再导入，TXT 是给人看的
       导入 POST /api/chats/import   { payload: <导出的 JSON> }
             按消息 id 去重（导两次也不会重复），导入后按时间重排、重编 seq
     ============================================================ */
  if (parts[0] === 'chats' && parts[1] === 'export' && method === 'GET') {
    const format = String(query.get('format') || 'json').toLowerCase() === 'txt' ? 'txt' : 'json';
    const one = str(query.get('chatId'), 60);
    const mine = chatsOf(user.id).filter((c) => !one || c.id === one);
    if (one && !mine.length) return fail(res, 404, '这个会话不在你名下');

    const picked = [];
    let total = 0;
    for (const c of mine) {
      const msgs = loadMessages(c.id);
      if (!msgs.length) continue;
      total += msgs.length;
      if (total > 60000) break;          // 一次别导太多，内存撑不住
      picked.push({ chat: c, messages: msgs });
    }

    const titleOf = (c) => {
      if (c.type === 'group') return c.name || '群聊';
      const other = findUser((c.memberIds || []).find((id) => id !== user.id) || '');
      return other ? displayNameFor(user.id, other) : '聊天';
    };
    const memberList = (c) => (c.memberIds || []).map((id) => ({
      id,
      name: id === user.id ? (user.nickname || user.username || '我') : displayNameFor(user.id, findUser(id))
    }));
    const stamp = new Date().toISOString().slice(0, 10);

    if (format === 'txt') {
      const lines = [];
      lines.push('Luchat 聊天记录备份 · 导出于 ' + now());
      lines.push('账号：' + (user.nickname || user.username || user.id));
      lines.push('');
      picked.forEach(({ chat, messages }) => {
        lines.push('========== ' + titleOf(chat) + '（共 ' + messages.length + ' 条） ==========');
        messages.forEach((m) => {
          const who = m.senderId === user.id ? '我'
            : (displayNameFor(user.id, findUser(m.senderId)) || '对方');
          const body = m.recalled ? '[消息已撤回]' : previewTextOf(m);
          lines.push('[' + String(m.createdAt || '').replace('T', ' ').slice(0, 19) + '] ' + who + '：' + body);
        });
        lines.push('');
      });
      ok(res, {
        fileName: 'luchat-chat-' + stamp + '.txt',
        format: 'txt',
        total,
        chats: picked.length,
        data: lines.join('\n')
      });
      return;
    }

    ok(res, {
      fileName: 'luchat-chat-' + stamp + '.json',
      format: 'json',
      total,
      chats: picked.length,
      data: {
        app: 'Luchat',
        version: 1,
        exportedAt: now(),
        user: { id: user.id, username: user.username || '', nickname: user.nickname || '' },
        chats: picked.map(({ chat, messages }) => ({
          id: chat.id,
          type: chat.type,
          title: titleOf(chat),
          memberIds: chat.memberIds || [],
          members: memberList(chat),
          messages: messages.map((m) => ({
            id: m.id,
            seq: m.seq,
            senderId: m.senderId,
            senderName: m.senderId === user.id ? (user.nickname || '我')
              : (displayNameFor(user.id, findUser(m.senderId)) || ''),
            kind: m.kind || 'text',
            content: m.content || '',
            createdAt: m.createdAt,
            recalled: !!m.recalled
          }))
        }))
      }
    });
    return;
  }

  if (parts[0] === 'chats' && parts[1] === 'import' && method === 'POST') {
    const body = await readBody(req);
    let payload = body.payload;
    if (typeof payload === 'string') {
      try { payload = JSON.parse(payload); } catch (e) { return fail(res, 422, '文件内容不是聊天记录备份'); }
    }
    if (!payload || !Array.isArray(payload.chats)) return fail(res, 422, '文件内容不是聊天记录备份');

    const allowedKinds = ['text', 'image', 'file', 'audio', 'gift', 'transfer', 'location', 'redpacket', 'link'];
    const MAX_TOTAL = 30000;
    let imported = 0;
    let skipped = 0;
    const touched = [];

    for (const item of payload.chats.slice(0, 300)) {
      if (!item || !Array.isArray(item.messages) || !item.id) continue;
      let chat = db.chats.find((c) => c.id === item.id);
      if (chat && !chat.memberIds.includes(user.id)) { skipped += item.messages.length; continue; }
      if (!chat) {
        /* 会话不在了（换手机 / 换了账号）：单聊就按导出里的成员重建一条，
           对方账号不存在（注销了）就只挂在自己名下，记录还能看 */
        const others = (item.memberIds || []).filter((id) => id !== user.id && findUser(id));
        chat = {
          id: String(item.id).slice(0, 60),
          type: item.type === 'group' ? 'group' : 'direct',
          name: item.type === 'group' ? String(item.title || '群聊').slice(0, 40) : '',
          memberIds: [user.id].concat(others),
          seq: 0,
          createdAt: now(),
          updatedAt: now()
        };
        db.chats.push(chat);
        touched.push(chat.id);
        chatsDirty = true;
      }

      const existing = loadMessages(chat.id);
      const have = new Set(existing.map((m) => m.id));
      const merged = existing.slice();
      for (const m of item.messages) {
        if (!m || !m.id || have.has(String(m.id))) { skipped += 1; continue; }
        if (imported >= MAX_TOTAL) break;
        have.add(String(m.id));
        const kind = allowedKinds.includes(m.kind) ? m.kind : 'text';
        merged.push({
          id: String(m.id).slice(0, 60),
          chatId: chat.id,
          seq: 0,
          senderId: String(m.senderId || user.id),
          kind,
          content: String(m.content == null ? '' : m.content).slice(0, 8000),
          createdAt: String(m.createdAt || now()),
          recalled: !!m.recalled
        });
        imported += 1;
      }
      if (merged.length === existing.length) continue;

      /* 按时间重排、重编 seq：导入的旧消息要回到它们该在的位置 */
      merged.sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
      merged.forEach((m, i) => { m.seq = i + 1; m.chatId = chat.id; });
      chat.seq = merged.length;
      chat.updatedAt = now();
      saveMessagesFile(chat.id, merged);
      chatsDirty = true;
      /* 导入的历史不算未读 */
      if (!db.reads[user.id]) db.reads[user.id] = {};
      db.reads[user.id][chat.id] = chat.seq;
      readsDirty = true;
      if (!touched.includes(chat.id)) touched.push(chat.id);
    }

    if (imported) saveUsers();
    audit(req, { username: user.username, name: user.nickname, role: '用户' }, '导入聊天记录', user.username,
      '导入 ' + imported + ' 条，跳过 ' + skipped + ' 条，涉及 ' + touched.length + ' 个会话');
    ok(res, { imported, skipped, chats: touched.length });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'messages' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const limit = Math.min(100, Math.max(1, Number(query.get('limit')) || 30));
    const before = Number(query.get('before')) || Number.MAX_SAFE_INTEGER;
    /* 自己清空过聊天记录：清空点之前的一律不返回（别人不受影响） */
    const clearedSeq = ((db.cleared || {})[user.id] || {})[chat.id] || 0;
    const slice = loadMessages(chat.id)
      .filter((m) => m.seq < before && m.seq > clearedSeq).slice(-limit);
    const messages = slice.map((m) => Object.assign({}, m, {
      senderName: displayNameFor(user.id, findUser(m.senderId)),
      senderAvatar: (findUser(m.senderId) || {}).avatar || ''
    }));
    ok(res, { chat: chatSummary(chat, user.id), messages, hasMore: slice.length === limit });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'messages' && method === 'POST') {
    const body = await readBody(req);
    if (!msgRateAllow(user.id) || !globalMsgAllow()) {
      riskEvent(user, 'fast_send', { note: '触发消息限流' });      // 频率异常记一笔（不罚，累计到阈值才受限）
      return fail(res, 429, '发得太快了，歇一秒再发');
    }
    /* 风控：被临时限制的账号先挡住 */
    const rw = riskBlocked(user);
    if (rw) return fail(res, 429, '账号功能被临时限制，还有 ' + rw + ' 分钟（如有疑问请联系管理员）');
    /* 文字炸弹（几千个换行 / 几千个一样的字）会让手机排版卡死，先洗一遍 */
    const clean = (body.kind || 'text') === 'text' ? sanitizeText(body.content) : body.content;
    if ((body.kind || 'text') === 'text') {
      const sameTo = noteTextSend(user.id, parts[1], clean);      // 群发检测
      if (sameTo >= 5) riskEvent(user, 'mass_send', { note: '同一内容发给了 ' + sameTo + ' 个会话' });
      if (/https?:\/\/|www\./i.test(String(clean || ''))) riskEvent(user, 'link', { note: '消息里带外链' });
    }
    const result = deliverMessage(user, parts[1], body.kind || 'text', clean, body.clientId);
    if (result.error) return fail(res, 422, result.error);
    ok(res, { message: result.message });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'read' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    /* 打开会话就把「标为未读」的小红点清掉 */
    if ((chat.flaggedUnread || []).includes(user.id)) {
      chat.flaggedUnread = chat.flaggedUnread.filter((id) => id !== user.id);
      saveChats();
    }
    sendToChat(chat, { type: 'read', chatId: chat.id, userId: user.id, seq: lastSeq }, user.id);
    ok(res, { seq: lastSeq });
    return;
  }

  /* 群聊信息页：群成员资料 + 群主 + 建群时间
     顺序和九宫格群头像一致（群主排第一），客户端照着画成员格子就行 */
  if (parts[0] === 'chats' && parts[2] === 'members' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    const ownerId = chat.ownerId && chat.memberIds.includes(chat.ownerId) ? chat.ownerId : '';
    const ordered = (ownerId ? [ownerId] : []).concat(chat.memberIds.filter((id) => id !== ownerId));
    ok(res, {
      name: chat.name || '',
      avatar: chat.avatar || '',
      ownerId: ownerId,
      createdAt: chat.createdAt || '',
      memberCount: chat.memberIds.length,
      members: ordered.map((id) => publicUser(findUser(id))).filter(Boolean)
    });
    return;
  }

  /* ================= 群管理（群名称 / 群公告 / 群屏蔽 / 群踢人 / 群解散 / 退群）================= */

  /* 群二维码：给当前群生成一个邀请码（不带状态，随时可重算），扫进来直接进群 */
  /* 我的二维码：每个人一张，扫了能加好友 */
  if (parts[0] === 'me' && parts[1] === 'qrcode' && method === 'GET') {
    const code = userCode(user.username);
    /* 二维码里写公网域名（不是服务器内网 IP）：外面用相机扫也能打开这个链接 */
    const url = payBaseUrl(req) + '/add.html?u=' + encodeURIComponent(code);
    const enc = QR.encode(url);
    ok(res, {
      code: code, url: url,
      rows: enc ? enc.modules.map((r) => r.join('')) : [], size: enc ? enc.size : 0,
      user: publicUser(user)
    });
    return;
  }

  /* 扫到别人的个人二维码：先看看是谁 */
  if (parts[0] === 'user-by-code' && method === 'GET') {
    const u = findUserByName(usernameFromUserCode(str(query.get('code'), 80)));
    if (!u) return fail(res, 404, '这个二维码无效或者过期了');
    ok(res, { user: publicUser(u) });
    return;
  }

  /* 扫到别人的个人二维码：直接加好友 */
  if (parts[0] === 'add-by-code' && method === 'POST') {
    const body = await readBody(req);
    const u = findUserByName(usernameFromUserCode(str(body.code, 80)));
    if (!u) return fail(res, 404, '这个二维码无效或者过期了');
    if (u.id === user.id) return fail(res, 422, '这是你自己的二维码');
    /* 隐私：对方关掉「通过二维码添加我」就不给加 */
    if (!userPrivacy(u).addByQR) return fail(res, 403, '对方关闭了「通过二维码添加我」');
    const exist = friendshipBetween(user.id, u.id);
    if (exist) {
      if (exist.status === 'accepted') return ok(res, { already: true, user: publicUser(u) });
      if (exist.fromId === user.id) return ok(res, { pending: true, user: publicUser(u) });
      /* 对方之前加过我：互加，直接变好友 */
      exist.status = 'accepted';
      exist.respondedAt = now();
      saveFriendships();
      const c2 = openChatForFriendship(exist.fromId, exist.toId);
      sendTo(u.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(exist.fromId, { type: 'chat', chatId: c2 ? c2.id : '' });
      sendTo(exist.toId, { type: 'chat', chatId: c2 ? c2.id : '' });
      ok(res, { accepted: true, user: publicUser(u) });
      return;
    }
    const f = { id: uid('f'), fromId: user.id, toId: u.id, status: 'pending', createdAt: now() };
    db.friendships.push(f);
    saveFriendships();
    sendTo(u.id, { type: 'friend', action: 'request', requestId: f.id, user: publicUser(user) });
    ok(res, { sent: true, user: publicUser(u) });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'invite' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊有群二维码');
    const code = inviteCode(chat.id);
    /* 同上：写公网域名，别写内网 IP */
    const url = payBaseUrl(req) + '/join.html?c=' + encodeURIComponent(code);
    const enc = QR.encode(url);
    ok(res, {
      code: code, url: url, svg: QR.svg(url, 7),
      rows: enc ? enc.modules.map((r) => r.join('')) : [], size: enc ? enc.size : 0
    });
    return;
  }

  /* 扫码进群：/join.html 打开后调它（没登录会先去登录） */
  if (parts[0] === 'join' && method === 'POST') {
    const body = await readBody(req);
    const code = str(body.code, 60);
    const chatId = chatIdFromInvite(code);
    if (!chatId) return fail(res, 404, '这个群二维码无效或者过期了');
    const chat = db.chats.find((c) => c.id === chatId && c.type === 'group');
    if (!chat || chat.dismissed) return fail(res, 404, '这个群已经不在了');
    if (chat.memberIds.includes(user.id)) return ok(res, { joined: false, already: true, chat: chatSummary(chat, user.id) });
    if (chat.memberIds.length >= 200) return fail(res, 422, '群人数满了');
    chat.memberIds.push(user.id);
    buildGroupAvatar(chat);
    const sys = pushSystemMessage(chat, user.nickname + ' 通过群二维码加入了群聊');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    saveChats();
    ok(res, { joined: true, chat: chatSummary(chat, user.id) });
    return;
  }

  /* 群禁言：全员禁言 / 单独禁言某个人（只有群主能开） */
  if (parts[0] === 'chats' && parts[2] === 'muteall' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能禁言');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能开启全员禁言');
    const body = await readBody(req);
    chat.muteAll = body.on !== false;
    const sys = pushSystemMessage(chat, chat.muteAll ? '群主开启了全员禁言' : '群主关闭了全员禁言');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    saveChats();
    ok(res, { muteAll: chat.muteAll });
    return;
  }
  if (parts[0] === 'chats' && parts[2] === 'mutemember' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能禁言');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能禁言成员');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target || !chat.memberIds.includes(target.id)) return fail(res, 404, '这个人不在群里');
    if (target.id === user.id) return fail(res, 422, '群主不用禁言自己');
    const set = new Set(chat.muteMembers || []);
    if (body.muted === false) set.delete(target.id); else set.add(target.id);
    chat.muteMembers = Array.from(set);
    saveChats();
    sendToChat(chat, { type: 'chat', action: 'updated', chat: chatSummary(chat, user.id) });
    ok(res, { muted: chat.muteMembers.includes(target.id) });
    return;
  }

  // 改群名称、群公告：只有群主能改
  if (parts[0] === 'chats' && parts[2] === 'info' && method === 'PATCH') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊才有群名称和群公告');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能改群名称和群公告');
    const body = await readBody(req);
    let changed = false;
    if (body.name !== undefined) {
      const n = str(body.name, 30);
      if (!n) return fail(res, 422, '群名称不能为空');
      chat.name = n;
      changed = true;
    }
    if (body.announce !== undefined) {
      chat.announce = str(body.announce, 500);
      changed = true;
    }
    if (!changed) return fail(res, 422, '没有要修改的内容');
    saveChats();
    chat.memberIds.forEach((id) => sendTo(id, { type: 'chat', action: 'updated', chat: chatSummary(chat, id) }));
    ok(res, { name: chat.name, announce: chat.announce || '' });
    return;
  }

  // 消息免打扰（群屏蔽）：每个人自己设，别人不受影响
  if (parts[0] === 'chats' && parts[2] === 'mute' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const body = await readBody(req);
    const set = new Set(chat.mutedFor || []);
    if (body.muted === false) set.delete(user.id); else set.add(user.id);
    chat.mutedFor = Array.from(set);
    saveChats();
    sendTo(user.id, { type: 'chat', action: 'updated', chat: chatSummary(chat, user.id) });
    ok(res, { muted: chat.mutedFor.includes(user.id) });
    return;
  }

  /* 群加人：群里任何一个成员都能拉人进来（微信默认也是这样），群上限 500。
     注意路径不能用 invite —— 那个已经被「群二维码/邀请码」占用了。 */
  if (parts[0] === 'chats' && parts[2] === 'add-members' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能加人');
    if (chat.dismissed) return fail(res, 422, '这个群已经解散了');
    const body = await readBody(req);
    const want = (Array.isArray(body.userIds) ? body.userIds : []).map((x) => String(x)).slice(0, 50);
    if (!want.length) return fail(res, 422, '先选要拉进来的人');

    const MAX_MEMBERS = 500;
    const added = [];
    let skipped = 0;
    for (const id of want) {
      if (chat.memberIds.includes(id)) { skipped += 1; continue; }
      const u = findUser(id);
      if (!u || u.banned) { skipped += 1; continue; }
      /* 跟拉人的这个人互相拉黑就不放进群 */
      if (chatBlockedBetween(user.id, u.id)) { skipped += 1; continue; }
      if (chat.memberIds.length >= MAX_MEMBERS) break;
      chat.memberIds.push(u.id);
      added.push(u);
    }
    if (!added.length) return fail(res, 409, '这几个人都已经在群里了');

    chat.dismissed = false;
    if (Array.isArray(chat.hiddenFor) && chat.hiddenFor.length) chat.hiddenFor = [];
    buildGroupAvatar(chat);
    const names = added.map((u) => u.nickname || u.username).join('、');
    const sys = pushSystemMessage(chat, user.nickname + ' 邀请 ' + names + ' 加入了群聊');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    /* 新进来的人：推一下「你被拉进这个群了」，App 收到就刷新会话列表 */
    added.forEach((u) => sendTo(u.id, { type: 'chat', action: 'added', chatId: chat.id, chat: chatSummary(chat, u.id) }));
    saveChats();
    ok(res, {
      memberCount: chat.memberIds.length,
      added: added.map((u) => ({ id: u.id, name: u.nickname || u.username })),
      skipped
    });
    return;
  }

  // 群踢人：群主把某个成员移出群聊
  if (parts[0] === 'chats' && parts[2] === 'kick' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能移出成员');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能移出成员');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target || !chat.memberIds.includes(target.id)) return fail(res, 404, '这个人不在群里');
    if (target.id === user.id) return fail(res, 422, '群主不能移出自己，想散就直接解散群');
    chat.memberIds = chat.memberIds.filter((id) => id !== target.id);
    chat.mutedFor = (chat.mutedFor || []).filter((id) => id !== target.id);
    chat.pinnedFor = (chat.pinnedFor || []).filter((id) => id !== target.id);
    buildGroupAvatar(chat);
    const sys = pushSystemMessage(chat, target.nickname + ' 被移出了群聊');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    sendTo(target.id, { type: 'chat', action: 'removed', chatId: chat.id });
    saveChats();
    ok(res, { memberCount: chat.memberIds.length });
    return;
  }

  // 退出群聊：群主退群就顺位把群主交给下一个人
  if (parts[0] === 'chats' && parts[2] === 'leave' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    const others = chat.memberIds.filter((id) => id !== user.id);
    if (!others.length) {
      chat.memberIds = [];
      chat.dismissed = true;
      saveChats();
      ok(res, { left: true, dismissed: true });
      return;
    }
    if (chat.ownerId === user.id) chat.ownerId = others[0];
    chat.memberIds = others;
    chat.mutedFor = (chat.mutedFor || []).filter((id) => id !== user.id);
    chat.pinnedFor = (chat.pinnedFor || []).filter((id) => id !== user.id);
    buildGroupAvatar(chat);
    const sys = pushSystemMessage(chat, user.nickname + ' 退出了群聊');
    others.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    sendTo(user.id, { type: 'chat', action: 'removed', chatId: chat.id });
    saveChats();
    ok(res, { left: true, ownerId: chat.ownerId });
    return;
  }

  // 解散群聊：只有群主
  if (parts[0] === 'chats' && parts[2] === 'dismiss' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能解散');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能解散群聊');
    const members = chat.memberIds.slice();
    const sys = pushSystemMessage(chat, '群主解散了该群聊');
    members.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    chat.memberIds = [];
    chat.dismissed = true;
    saveChats();
    members.forEach((id) => sendTo(id, { type: 'chat', action: 'removed', chatId: chat.id }));
    ok(res, { dismissed: true });
    return;
  }

  // 查找聊天记录：在服务器上翻这个会话的历史（不只是手机里加载的那几十条）
  if (parts[0] === 'chats' && parts[2] === 'search' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const q = str(query.get('q'), 40);
    if (!q) return ok(res, { messages: [] });
    const clearedSeq = ((db.cleared || {})[user.id] || {})[chat.id] || 0;
    const kw = q.toLowerCase();
    const hit = loadMessages(chat.id)
      .filter((m) => m.seq > clearedSeq && !m.recalled && m.kind !== 'system'
        && String(m.content || '').toLowerCase().indexOf(kw) >= 0)
      .slice(-60)
      .reverse();
    ok(res, {
      messages: hit.map((m) => {
        const sender = findUser(m.senderId) || {};
        return {
          id: m.id, seq: m.seq, kind: m.kind, content: m.content, createdAt: m.createdAt,
          senderId: m.senderId, senderName: sender.nickname || ''
        };
      })
    });
    return;
  }

  // 清空聊天记录：只清自己这边的，别人不受影响
  if (parts[0] === 'chats' && parts[2] === 'clear' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.cleared[user.id]) db.cleared[user.id] = {};
    db.cleared[user.id][chat.id] = lastSeq;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    ok(res, { cleared: lastSeq });
    return;
  }

  // 标为未读：把已读位置退回一条，这样最后一条又算未读（QQ / 微信左滑里的「标为未读」）
  if (parts[0] === 'chats' && parts[2] === 'unread' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = Math.max(0, lastSeq - 1);
    saveReads();
    chat.flaggedUnread = Array.from(new Set((chat.flaggedUnread || []).concat([user.id])));
    saveChats();
    ok(res, { unread: unreadCount(user.id, chat) });
    return;
  }

  if (parts[0] === 'messages' && parts[2] === 'recall' && method === 'POST') {
    const body = await readBody(req);
    const result = recallMessage(user, body.chatId, parts[1]);
    if (result.error) return fail(res, 422, result.error);
    ok(res, { message: result.message });
    return;
  }

  /* ------------------------------------------------ 设备确认登录：确认方 */
  if (parts[0] === 'pair' && parts[1] === 'approve' && method === 'POST') {
    const body = await readBody(req);
    prunePairCodes();
    const code = str(body.code, 10);
    const rec = pairCodes.get(code);
    if (!rec) return fail(res, 404, '登录码已过期，让那台设备刷新一下');
    rec.userId = user.id;
    rec.approvedName = user.nickname;
    ok(res, { approved: true, code, user: publicUser(user) });
    return;
  }

  /* -------------------------------------------------------------- 朋友圈 */

  if (parts[0] === 'moments' && method === 'POST' && parts[1] === 'seen') {
    db.momentViews[user.id] = now();
    saveMomentViews();
    ok(res, { unread: 0 });
    return;
  }

  /* 补机器人：登录后调一次，保证「AI 助手 / 贾维斯AI / 腾讯新闻」一定在
     （哪怕账号是刚注册的、或者服务器还没重启过） */
  if (parts[0] === 'bots' && parts[1] === 'ensure' && method === 'POST') {
    ensureBots();
    const hello = {
      ai: '你好，我是 AI 助手，只负责这个 App 的使用问题 👋\n哪找不到、怎么操作都可以问我，比如「怎么换头像」「朋友圈在哪发」。',
      housekeeper: '您好，我是 AI 助手，您的管家，随时为您效劳。\n整个微信里的事都能吩咐我：\n· 给张三发消息 你好　· 建个群 张三 李四　· 加好友 微信号\n· 提醒我 8:30 开会　· 天气 上海　· 记账 午饭 25 / 账本\n· 发朋友圈 今天天气真好 / 写条朋友圈 加班 / 改签名 岁月静好\n· 给张三的朋友圈点赞　· 评论张三的朋友圈：好看\n· 置顶/免打扰/删掉 张三　· 清空和张三的聊天记录\n· 我和张三聊了什么 / 找张三说过 合同\n· 给张三转 50　· 我的账单　· 谁在线　· 余额',
      qqnews: '你好，我是腾讯新闻，只报新闻～\n发「新闻」看今天的热点，或者说「讲讲第 2 条」让我讲细一点。'
    };
    const made = [];
    /* 在线客服（service）不算：它的会话只在你点「联系客服」时才建 */
    db.users.filter((u) => u.bot && !u.service).forEach((bot) => {
      const f = friendshipBetween(user.id, bot.id);
      if (!f) db.friendships.push({ id: uid('f'), fromId: bot.id, toId: user.id, status: 'accepted', createdAt: now() });
      else if (f.status !== 'accepted') f.status = 'accepted';
      let chat = directChatBetween(user.id, bot.id);
      if (!chat) chat = createDirectChat(user.id, bot.id);
      const set = new Set(chat.pinnedFor || []);
      if (bot.username !== 'qqnews' && !set.has(user.id)) { set.add(user.id); chat.pinnedFor = Array.from(set); }
      const msgs = loadMessages(chat.id);
      if (!msgs.some((m) => m.senderId === bot.id)) {
        try { deliverMessage(bot, chat.id, 'text', hello[bot.username] || '你好，我是机器人', null); } catch (e) { }
      }
      made.push(bot.username);
    });
    saveFriendships(); saveChats();
    ok(res, { bots: made });
    return;
  }

  if (parts[0] === 'news' && method === 'GET') {
    const list = await fetchTencentNews(query.get('limit'));
    ok(res, { list, updatedAt: newsCache.at });
    return;
  }

  if (parts[0] === 'moments' && method === 'GET' && parts.length === 1) {
    const limit = Math.min(50, Math.max(1, Number(query.get('limit')) || 20));
    const before = str(query.get('before'), 40);
    const beforeId = str(query.get('beforeId'), 40);
    const onlyUser = str(query.get('userId'), 40);
    /* 陌生人的朋友圈不给看：只能看自己或好友的 */
    if (onlyUser && onlyUser !== user.id && !friendSetCached(user.id).has(onlyUser)) {
      /* 隐私：对方开了「允许陌生人查看朋友圈」就给看（但只给看最近 10 条） */
      const other = findUser(onlyUser);
      if (!other || !userPrivacy(other).strangerMoments) return fail(res, 403, '只能看好友的朋友圈');
    }
    const audience = momentAudience(user.id);
    const audienceSet = new Set(audience);      // 同上：数组 includes 在几千条动态时会拖死服务器
    /* 谁可以看：公开 / 私密（只有自己）/ 部分可见 / 不给谁看（对应功能清单里的那一行） */
    let list = db.moments.filter((m) => audienceSet.has(m.authorId) && momentVisibleTo(m, user.id));
    /* 朋友权限（微信「设置备注和标签 → 朋友权限」那一栏）：
       · 我设了「不看他（她）的朋友圈」→ 他的动态不在我的列表里
       · 他设了「不让他（她）看我」或者拉黑了我 → 我也看不到 */
    const hiddenForMe = (authorId) => {
      const mine = metaOf(user.id, authorId);
      if (mine.block === true || mine.noMoments === true) return true;
      const theirs = metaOf(authorId, user.id);
      return theirs.block === true || theirs.hideMyMoments === true;
    };
    list = list.filter((m) => !hiddenForMe(m.authorId));
    if (onlyUser) list = list.filter((m) => m.authorId === onlyUser);
    /* 排序要稳定：时间一样时再按 id 排。
       否则「同一毫秒发的几十条」在翻页时会被整段跳过（时间戳当游标最怕这个）。 */
    list = list.slice().sort((a, b) => {
      /* 置顶的动态永远在最上面（自己置顶的），其余按时间倒序 —— 微信时间轴就是这个规矩 */
      const pa = a.pinned === true ? 1 : 0, pb = b.pinned === true ? 1 : 0;
      if (pa !== pb && !before) return pb - pa;
      const c = String(b.createdAt).localeCompare(String(a.createdAt));
      return c !== 0 ? c : String(b.id).localeCompare(String(a.id));
    });
    if (before) {
      list = beforeId
        ? list.filter((m) => String(m.createdAt) < before ||
            (String(m.createdAt) === before && String(m.id) < beforeId))
        : list.filter((m) => String(m.createdAt) < before);      // 老客户端没传 id 时还按老规矩
    }
    const slice = list.slice(0, limit);
    const target = onlyUser ? memberProfile(findUser(onlyUser), user.id) : null;
    ok(res, {
      moments: slice.map((m) => visibleMoment(m, user.id)),
      hasMore: list.length > slice.length,
      unread: momentUnread(user.id),
      total: list.length,
      target
    });
    return;
  }

  if (parts[0] === 'moments' && method === 'POST' && parts.length === 1) {
    if (!momentRateAllow(user.id)) {
      return fail(res, 429, '发朋友圈太频繁了（1 分钟最多 20 条）');
    }
    /* 风控：被临时限制的账号先挡住 */
    const moBlocked = riskBlocked(user);
    if (moBlocked) return fail(res, 429, '账号功能被临时限制，还有 ' + moBlocked + ' 分钟（如有疑问请联系管理员）');
    const body = await readBody(req);
    const content = str(body.content, 1000);
    const images = (Array.isArray(body.images) ? body.images : [])
      .map((x) => safeImageRef(str(x, 2000))).filter(Boolean).slice(0, 9);
    if (!content && !images.length) return fail(res, 422, '写点什么，或者发张图');
    const moment = {
      id: uid('mo'),
      authorId: user.id,
      content,
      images,
      /* 所在位置（微信发表页那一行；不填就是空的，不发 */
      location: str(body.location, 40),
      /* 可见范围：public（好友可见，默认）/ private（仅自己）/ partial（只给这些人看）/ exclude（不给这些人看） */
      visibility: ['private', 'partial', 'exclude'].includes(String(body.visibility)) ? String(body.visibility) : 'public',
      visibleTo: (Array.isArray(body.visibleTo) ? body.visibleTo : []).map((x) => str(x, 40)).filter(Boolean).slice(0, 200),
      hiddenFrom: (Array.isArray(body.hiddenFrom) ? body.hiddenFrom : []).map((x) => str(x, 40)).filter(Boolean).slice(0, 200),
      createdAt: now(),
      likes: [],
      comments: []
    };
    appendMoment(moment);          // 只追加一行日志，不再整体重写 moments.json
    broadcastMoment(user.id, {
      type: 'moment', action: 'new', authorId: user.id, moment: visibleMoment(moment, user.id)
    });
    ok(res, { moment: visibleMoment(moment, user.id) });
    return;
  }

  if (parts[0] === 'moments' && method === 'POST' && parts[2] === 'like') {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    if (!momentAudience(m.authorId).includes(user.id)) return fail(res, 403, '看不到这条动态');
    if (!m.likes) m.likes = [];
    const idx = m.likes.findIndex((l) => l.userId === user.id);
    const liked = idx === -1;
    if (liked) m.likes.push({ userId: user.id, at: now() });
    else m.likes.splice(idx, 1);
    saveMoments();
    broadcastMoment(m.authorId, {
      type: 'moment', action: 'like', momentId: m.id, authorId: m.authorId, userId: user.id, liked
    });
    ok(res, { moment: visibleMoment(m, user.id) });
    return;
  }

  /* 置顶 / 取消置顶自己发的动态：置顶的固定排在朋友圈最上面 */
  if (parts[0] === 'moments' && method === 'POST' && parts[2] === 'pin') {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    if (m.authorId !== user.id) return fail(res, 403, '只能置顶自己的动态');
    const body = await readBody(req);
    const on = body.pinned !== false;
    if (on) {
      /* 只能置顶一条：新的置顶把旧的取消（QQ空间/微博都是这个规矩） */
      db.moments.forEach((x) => { if (x.authorId === user.id && x.id !== m.id) delete x.pinned; });
    }
    if (on) m.pinned = true; else delete m.pinned;
    saveMoments();
    ok(res, { pinned: on });
    return;
  }

  /* 删评论：只能删自己发的；动态作者可以删自己动态下的任何评论（微信那套） */
  if (parts[0] === 'moments' && method === 'DELETE' && parts[2] === 'comments' && parts.length === 4) {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    const idx = (m.comments || []).findIndex((c) => c.id === parts[3]);
    if (idx < 0) return fail(res, 404, '这条评论不在了');
    const c = m.comments[idx];
    if (c.userId !== user.id && m.authorId !== user.id) return fail(res, 403, '只能删自己的评论');
    m.comments.splice(idx, 1);
    saveMoments();
    const audience = momentAudience(m.authorId);
    audience.forEach((id) => sendTo(id, {
      type: 'moment', action: 'comment-deleted', momentId: m.id, commentId: c.id
    }));
    ok(res, { deleted: true });
    return;
  }

  if (parts[0] === 'moments' && method === 'POST' && parts[2] === 'comments') {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    if (!momentAudience(m.authorId).includes(user.id)) return fail(res, 403, '看不到这条动态');
    /* 风控：被临时限制的账号先挡住 */
    const cmBlocked = riskBlocked(user);
    if (cmBlocked) return fail(res, 429, '账号功能被临时限制，还有 ' + cmBlocked + ' 分钟（如有疑问请联系管理员）');
    const body = await readBody(req);
    const content = str(body.content, 300);
    if (!content) return fail(res, 422, '评论不能为空');
    const replyTo = str(body.replyTo, 40) || null;
    if (!m.comments) m.comments = [];
    m.comments.push({ id: uid('cm'), userId: user.id, content, replyTo, at: now() });
    saveMoments();
    const views = visibleMoment(m, user.id);
    const audience = momentAudience(m.authorId);
    audience.forEach((id) => {
      sendTo(id, {
        type: 'moment',
        action: 'comment',
        momentId: m.id,
        authorId: m.authorId,
        comment: views.comments[views.comments.length - 1],
        commentCount: views.comments.length
      });
    });
    ok(res, { moment: views });
    return;
  }

  if (parts[0] === 'moments' && method === 'DELETE' && parts.length === 2) {
    const idx = db.moments.findIndex((x) => x.id === parts[1]);
    if (idx === -1) return fail(res, 404, '动态不存在');
    if (db.moments[idx].authorId !== user.id) return fail(res, 403, '只能删除自己发的动态');
    const [removed] = db.moments.splice(idx, 1);
    saveMoments();
    broadcastMoment(user.id, {
      type: 'moment', action: 'delete', momentId: removed.id, authorId: user.id
    });
    ok(res, { deleted: true });
    return;
  }

  /* 用户举报：App 里长按消息 / 动态可以举报，后台「举报处理」里看 */
  if (parts[0] === 'reports' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.targetUserId, 40));
    if (!target) return fail(res, 404, '被举报的人不存在');
    const row = {
      id: uid('rp'),
      at: now(),
      byUserId: user.id,
      byName: user.nickname || user.username,
      targetUserId: target.id,
      targetName: target.nickname || target.username,
      reason: str(body.reason, 60) || '未填写原因',
      content: str(body.content, 300),
      chatId: str(body.chatId, 60),
      status: 'open'
    };
    opsStore.reports.unshift(row);
    if (opsStore.reports.length > 500) opsStore.reports.length = 500;
    saveReports();
    audit(req, null, '用户举报', target.username, row.reason);
    ok(res, { reported: true });
    return;
  }

  /* 二进制直传：视频/图片直接把原始字节 PUT 上来，不再塞 base64
     （base64 会多传 33%，一条 5MB 视频要多跑 1.7MB 流量 → 手机上就是多等十几秒） */
  if (parts[0] === 'upload' && parts[1] === 'raw' && method === 'POST') {
    if (!uploadRateAllow(user.id)) {
      return fail(res, 429, '上传太频繁了，歇一会儿再传');
    }
    if (uploadDirFull()) return fail(res, 507, '服务器空间不够了，先清理上传目录');
    const ctype = String(req.headers['content-type'] || '').toLowerCase();
    let ext = 'bin';
    if (ctype.indexOf('video/') === 0) ext = ctype.indexOf('quicktime') >= 0 ? 'mov' : 'mp4';
    else if (ctype.indexOf('png') >= 0) ext = 'png';
    else if (ctype.indexOf('image/') === 0) ext = 'jpg';
    let name = uid('file') + '.' + ext;
    const outPath = path.join(UPLOAD_DIR, name);
    const MAX = 60 * 1024 * 1024;
    let size = 0, tooBig = false;
    const ws2 = fs.createWriteStream(outPath);
    await new Promise((resolve) => {
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX) { tooBig = true; try { ws2.destroy(); } catch (err) { } req.destroy(); resolve(); }
      });
      req.on('end', () => resolve());
      req.on('error', () => resolve());
      req.pipe(ws2);
      ws2.on('close', () => resolve());
    });
    if (tooBig) { try { fs.unlinkSync(outPath); } catch (err) { } return fail(res, 413, '文件超过 60MB'); }
    if (!size) { try { fs.unlinkSync(outPath); } catch (err) { } return fail(res, 422, '没有收到文件'); }
    /* 这个口原来是"写进去就不管了"：图片炸弹能从这里溜进来。
       现在图片一律过一遍尺寸体检：超限直接拒，大图自动缩小。 */
    if (ctype.indexOf('image/') === 0) {
      try {
        const buf2 = fs.readFileSync(outPath);
        const mime2 = sniffImageMime(buf2) || (ctype.indexOf('png') >= 0 ? 'image/png' : 'image/jpeg');
        const img2 = checkImage(buf2, mime2);
        if (!img2.ok) { try { fs.unlinkSync(outPath); } catch (err) { } return fail(res, 422, img2.error); }
        let final2 = img2.buffer;
        if (img2.needShrink) {
          const small2 = shrinkImageBuffer(img2.buffer, '.' + ext);
          if (small2 && small2.length) final2 = small2;
        }
        fs.writeFileSync(outPath, final2);
        size = final2.length;
      } catch (err) {
        try { fs.unlinkSync(outPath); } catch (err2) { }
        return fail(res, 422, '图片校验失败');
      }
    }
    /* 视频：按视频号同一套规格压一遍（720p / 1.2Mbps / faststart）再落盘。
       以前「传多大存多大」—— 聊天里一条 10MB 的视频，对方手机上要转十几秒才出画面。 */
    if (ctype.indexOf('video/') === 0 && size > 2 * 1024 * 1024) {
      const before = size;
      try {
        const tmpIn = path.join(os.tmpdir(), 'chris-up-' + crypto.randomBytes(6).toString('hex') + '.' + ext);
        const outTmp = tmpIn + '.small.mp4';
        fs.writeFileSync(tmpIn, fs.readFileSync(outPath));
        const rr = await runFfAsync(ffmpegExe(), ['-y', '-loglevel', 'error', '-i', tmpIn,
          '-vf', "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'",
          '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'veryfast',
          '-b:v', '1200k', '-maxrate', '1500k', '-bufsize', '3000k',
          '-r', '30', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
          '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k', '-ac', '1',
          '-movflags', '+faststart', outTmp], 300000);
        if (rr.ok && fs.existsSync(outTmp)) {
          const nb = fs.readFileSync(outTmp);
          const smallName = uid('file') + '.mp4';
          fs.writeFileSync(path.join(UPLOAD_DIR, smallName), sealUploadBuffer(smallName, nb));
          try { fs.unlinkSync(outPath); } catch (err) { }
          name = smallName;
          size = nb.length;
          callTrace('聊天视频压缩 ' + Math.round(before / 1024) + 'KB → ' + Math.round(size / 1024) + 'KB');
        }
        try { fs.unlinkSync(outTmp); } catch (err) { }
        try { fs.unlinkSync(tmpIn); } catch (err) { }
      } catch (err) {
        callTrace('聊天视频压缩失败，用原文件：' + String(err && err.message || err).slice(0, 120));
      }
    }
    /* 上传目录里的东西一律加密落盘（以前这个口是直接写明文，重启才补加密） */
    sealUploadInPlace(name);
    noteUpload(user.id, size);
    ok(res, { url: '/uploads/' + name, bytes: size });
    return;
  }

  if (parts[0] === 'upload' && method === 'POST') {
    if (!uploadRateAllow(user.id)) {
      return fail(res, 429, '上传太频繁了，歇一会儿再传（10 分钟最多 60 个、200MB）');
    }
    if (uploadDirFull()) {
      return fail(res, 507, '服务器空间不够了，先让管理员清一下上传目录');
    }
    const body = await readBody(req);
    const saved = saveUploadedFile(body);
    if (saved.error) return fail(res, saved.status, saved.error);
    noteUpload(user.id, saved.bytes || 0);
    ok(res, saved);
    return;
  }

  fail(res, 404, '接口不存在');
}

/* ------------------------------------------------------------------ 静态 */

let assetVersionCache = { at: 0, version: '' };

/** public 目录的指纹：任何前端文件改动都会让版本号变，用来提示/自动刷新页面 */
function assetVersion() {
  const t = Date.now();
  if (assetVersionCache.version && t - assetVersionCache.at < 1000) return assetVersionCache.version;
  const hash = crypto.createHash('sha1');
  try {
    fs.readdirSync(PUBLIC_DIR).sort().forEach((name) => {
      try {
        const st = fs.statSync(path.join(PUBLIC_DIR, name));
        if (st.isFile()) hash.update(name + ':' + st.size + ':' + Math.round(st.mtimeMs));
      } catch (err) { /* 单个文件读不到就跳过 */ }
    });
  } catch (err) { /* 目录读不到就用空指纹 */ }
  const version = hash.digest('hex').slice(0, 12);
  assetVersionCache = { at: t, version };
  return version;
}

/** 能压缩的文本类型（html/css/js/json/svg…） */
const COMPRESSIBLE = { '.html': 1, '.css': 1, '.js': 1, '.json': 1, '.svg': 1, '.txt': 1 };
/** 压缩结果按 文件+版本 缓存，避免每次请求都压一遍 */
const gzipCache = new Map();

function gzipFor(file, buf, version) {
  const key = file + '|' + version;
  const hit = gzipCache.get(key);
  if (hit) return hit;
  const gz = zlib.gzipSync(buf, { level: 6 });
  if (gzipCache.size > 40) gzipCache.clear();
  gzipCache.set(key, gz);
  return gz;
}

function sendFile(req, res, file, rel) {
  fs.stat(file, (err, stat) => {
    if (err || !stat.isFile()) return fail(res, 404, '文件不存在: ' + rel);
    const ext = path.extname(file).toLowerCase();
    const version = assetVersion();
    const acceptGzip = /\bgzip\b/.test(String(req.headers['accept-encoding'] || ''));
    /* 安全：上传目录里只允许"直接显示"的媒体类型；其它一律当二进制附件下载，
       并且禁掉浏览器猜类型 —— 不然传个 .html/.svg 上来就能当网页跑脚本（存储型 XSS）。 */
    const inUploads = String(rel || '').indexOf('/uploads/') === 0;
    /* 上传目录里的文件是**加密落盘**的（见 sealUploadBuffer）：
       对外服务时先解密到内存再发。热文件留一份缓存，避免每次请求都解一遍。 */
    let plain = null;
    /* 视频/音频边下边播、拖进度条会连着发很多 Range 请求：
       这种请求只解需要的那一段（见 readUploadRange），不再把整个文件解一遍。 */
    const rangeHdr = String(req.headers.range || '').trim();
    const wantRange = /^bytes=/.test(rangeHdr);
    const sealed = inUploads ? uploadIsSealed(file) : false;
    if (inUploads && !(wantRange && sealed)) {
      try { plain = readUploadPlain(file); } catch (e2) { plain = null; }
    }
    const totalSize = plain ? plain.length : (sealed ? Math.max(0, stat.size - 20) : stat.size);
    /* 访问流水带上 Range 和真实状态：以后「视频怎么一直在转圈」看这一行就知道
       客户端是在整包下载（200）还是分片边下边播（206）、要的是哪一段。 */
    if (inUploads) {
      const r0 = /^bytes=(\d*)-(\d*)$/.exec(rangeHdr);
      uploadAccessLog(clientInfo(req).ip, (r0 && (r0[1] || r0[2])) ? 206 : 200,
        path.basename(file), req.url,
        'range=' + (rangeHdr || '-') + ' size=' + totalSize + (sealed ? ' sealed' : ' plain')
          + ' ua=' + String(req.headers['user-agent'] || '').slice(0, 24).replace(/\s+/g, '_'));
    }
    const DISPLAYABLE = ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico', '.mp4', '.webm', '.mp3', '.m4a', '.ogg', '.wav'];
    const forceDownload = inUploads && DISPLAYABLE.indexOf(ext) < 0;
   const headers = {
      'Content-Type': forceDownload ? 'application/octet-stream' : (MIME[ext] || 'application/octet-stream'),
      'X-Content-Type-Options': 'nosniff',
      /* 上传目录里的东西（头像、封面、朋友圈图、聊天图、视频、语音）文件名都是随机生成的，
         永远不会被同名覆盖 —— 所以可以按「一年内不用再问服务器」来发。
         以前一律 no-cache，App 每次启动、每次翻列表都要重新校验一遍每张图/每个视频，
         4G 上就是一顿一顿的（这是"卡"的主要来源之一）。
         页面和脚本仍然走 no-cache + ETag，保证后台改了刷新就能看到最新。 */
      'Cache-Control': inUploads
        ? 'public, max-age=31536000, immutable'
        : 'no-cache, must-revalidate',
      'ETag': '"' + version + '-' + stat.size + '"',
      'X-Asset-Version': version
    };
    /* 按真实内容定类型：大到几 MB 的 PNG 截图会被压成 JPEG（文件名不变，
       消息里的地址不用改），这时如果还按扩展名发 image/png，浏览器可能会挑刺。
       这里用已经解出来的明文头判断一下，稳一点。 */
    if (inUploads && plain && !forceDownload && plain.length > 3) {
      const h0 = plain[0], h1 = plain[1], h2 = plain[2];
      if (h0 === 0xff && h1 === 0xd8 && h2 === 0xff) headers['Content-Type'] = 'image/jpeg';
      else if (h0 === 0x89 && h1 === 0x50 && h2 === 0x4e) headers['Content-Type'] = 'image/png';
      else if (h0 === 0x52 && h1 === 0x49 && h2 === 0x46) headers['Content-Type'] = 'image/webp';
      else if (h0 === 0x47 && h1 === 0x49 && h2 === 0x46) headers['Content-Type'] = 'image/gif';
    }
    if (forceDownload) headers['Content-Disposition'] = 'attachment';
    if (req.headers['if-none-match'] === headers['ETag']) {
      res.writeHead(304, { 'Cache-Control': headers['Cache-Control'], 'ETag': headers['ETag'] });
      res.end();
      return;
    }
    if (ext === '.html') {
      /* 防木马的关键响应头：
         CSP    —— 只让本站自己的脚本跑，别人注入的 <script> 一律执行不了
         DENY   —— 不让别人用 iframe 套住这个页面（防点击劫持）
         Permissions-Policy —— 关掉屏幕录制等危险能力 */
      const inlineOk = /^(index|admin|admin2|manage|ai)\.html$/i.test(path.basename(file));
      headers['Content-Security-Policy'] = [
        "default-src 'self'",
        "script-src 'self'" + (inlineOk ? " 'unsafe-inline'" : ''),
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob: http: https:",
        "media-src 'self' data: blob: http: https:",
        "font-src 'self' data:",
        "connect-src 'self' http: https: ws: wss:",
        "object-src 'none'",
        /* 登录页允许被后台「实时预览」用 iframe 嵌，其它页面一律禁止被嵌套 */
        "frame-ancestors " + (/^login\.html$/i.test(path.basename(file)) ? "'self'" : "'none'"),
        "base-uri 'none'",
        "form-action 'none'"
      ].join('; ');
      headers['X-Frame-Options'] = 'DENY';
      headers['Permissions-Policy'] = 'display-capture=(), geolocation=(self), camera=(self), microphone=(self)';
      // 给 html 里的 css / js 加上 ?v=版本号，双保险
      let html = fs.readFileSync(file, 'utf8');
      html = html.replace(/(href|src)="([^":?]+\.(?:css|js))"/g, (m, attr, url) => attr + '="' + url + '?v=' + version + '"');
      let buf = Buffer.from(html, 'utf8');
      if (acceptGzip) {
        buf = gzipFor(file, buf, version);
        headers['Content-Encoding'] = 'gzip';
        headers['Vary'] = 'Accept-Encoding';
      }
      headers['Content-Length'] = buf.length;
      res.writeHead(200, headers);
      res.end(buf);
      return;
    }
    if (acceptGzip && COMPRESSIBLE[ext] && stat.size > 1024) {
      const buf = gzipFor(file, fs.readFileSync(file), version);
      headers['Content-Encoding'] = 'gzip';
      headers['Vary'] = 'Accept-Encoding';
      headers['Content-Length'] = buf.length;
      res.writeHead(200, headers);
      res.end(buf);
      return;
    }
    /* 视频/音频支持 Range 分片：播放器才能边下边播、拖进度条。
       以前只回整包（200），所以每条视频都要等整个下完才出画面 —— 又慢又卡。 */
    headers['Accept-Ranges'] = 'bytes';
    const range = rangeHdr;
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (m && (m[1] || m[2])) {
      let start = m[1] ? parseInt(m[1], 10) : Math.max(0, totalSize - parseInt(m[2], 10));
      let end = m[1] && m[2] ? parseInt(m[2], 10) : totalSize - 1;
      if (isNaN(start) || isNaN(end) || start > end || start >= totalSize) {
        res.writeHead(416, { 'Content-Range': 'bytes */' + totalSize });
        res.end();
        return;
      }
      end = Math.min(end, totalSize - 1);
      headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + totalSize;
      headers['Content-Length'] = end - start + 1;
      res.writeHead(206, headers);
      if (plain) res.end(plain.subarray(start, end + 1));
      else if (sealed) {
        let part = null;
        try { part = readUploadRange(file, path.basename(file), start, end); } catch (err) { part = null; }
        if (part) res.end(part);
        else fs.createReadStream(file, { start: start, end: end }).pipe(res);
      } else fs.createReadStream(file, { start: start, end: end }).pipe(res);
      return;
    }
    headers['Content-Length'] = totalSize;
    res.writeHead(200, headers);
    if (plain) res.end(plain);
    else if (sealed) streamUploadPlain(file, res);
    else fs.createReadStream(file).pipe(res);
  });
}

/* 上传图片的访问流水：谁取的、给没给、带没带签名。
   「背景加载不出来」这种事，看这个文件就知道是没请求到、还是被 403 挡了。 */
function uploadAccessLog(ip, status, name, url, extra) {
  try {
    const signed = /[?&]s=/.test(String(url || '')) ? 'signed' : 'noSig';
    fs.appendFileSync(path.join(DATA_DIR, 'uploads-access.log'),
      '[' + new Date().toISOString() + '] ' + status + ' ' + signed + ' ' + ip + ' ' + name
        + (extra ? ' ' + extra : '') + '\n', 'utf8');
  } catch (err) { /* 日志写不了不影响服务 */ }
}

/* ============================================================
   视频分片（HLS）：先播放后加载
   data/hls/<id>/index.m3u8 + seg_00000.ts（和服务端其它上传一样加密落盘）。
   整包 MP4 就算是边下边播，也要「从某个位置一直下到结尾」；切成 3 秒一段之后，
   AVPlayer 拿到第一段就能出画面，剩下的按播放进度边看边下。
   没生成过分片的视频回 404，客户端会自动退回整包 MP4，不会播不出来。
   ============================================================ */
const HLS_DIR = path.join(DATA_DIR, 'hls');

/* 新视频进 feed 后自动补 HLS 分片（防退化的那一步）。
   合并成一个 4 秒的防抖：连发几条视频只跑一次；detached + unref 所以
   不占请求、也不会拦着服务退出。 */
let hlsBuildTimer = null;
function scheduleHlsBuild() {
  try {
    if (hlsBuildTimer) clearTimeout(hlsBuildTimer);
    hlsBuildTimer = setTimeout(() => {
      hlsBuildTimer = null;
      try {
        const child = spawn(process.execPath, ['hls-build.js'], {
          cwd: __dirname, detached: true, stdio: 'ignore'
        });
        child.on('error', () => { });
        child.unref();
        callTrace('视频号：新视频已排队做 HLS 分片（自动）');
      } catch (e) { callTrace('视频号：HLS 自动分片起不来 ' + String(e && e.message || e)); }
    }, 4000);
  } catch (e) { }
}

/** 找同一个视频「重建后」的分片目录（<id>-t<时间戳>），多个就取最新的；没有返回 '' */
function findRebuiltHlsDir(id) {
  try {
    const prefix = String(id) + '-t';
    const list = fs.readdirSync(HLS_DIR).filter((d) => d.indexOf(prefix) === 0);
    if (!list.length) return '';
    list.sort((a, b) => {
      const ta = fs.statSync(path.join(HLS_DIR, a)).mtimeMs;
      const tb = fs.statSync(path.join(HLS_DIR, b)).mtimeMs;
      return tb - ta;
    });
    return list[0];
  } catch (e) { return ''; }
}

function serveHls(req, res, rel) {
  const parts = String(rel).split('/').filter(Boolean);      // ['hls', id, 文件名]
  if (parts.length !== 3) return fail(res, 404, '文件不存在');
  const id = parts[1].replace(/[^A-Za-z0-9._-]/g, '');
  const name = parts[2].replace(/[^A-Za-z0-9._-]/g, '');
  if (!id || !name) return fail(res, 404, '文件不存在');
  const dir = path.join(HLS_DIR, id);
  const file = path.join(dir, name);
  if (file.indexOf(dir) !== 0) return fail(res, 403, '禁止访问');
  /* 和 /uploads 一个口径：开了「上传要签名」就必须带签名或登录 */
  if (secCfg().signUploads && !currentUser(req)) {
    let q = null;
    try { q = new URL(req.url, 'http://x').searchParams; } catch (err) { q = null; }
    if (!(q && uploadSigOk(name, q.get('e'), q.get('s')))) {
      strikeIp(clientInfo(req).ip, '裸链访问 HLS');
      return fail(res, 403, '这个文件需要登录或签名链接才能访问');
    }
  }
  /* 分片重建过（目录名换成 <id>-t<时间戳>）时，客户端手里可能还拿着老 URL。
     老目录已经删掉了，直接 404 的话客户端会退回整包 MP4（又变重）——
     所以这里 302 到重建后的同名视频目录，播放列表和分片都走新的。 */
  if (!fs.existsSync(file)) {
    const alt = findRebuiltHlsDir(id);
    if (alt) {
      res.writeHead(302, { Location: '/hls/' + alt + '/' + name, 'Cache-Control': 'no-store' });
      return res.end();
    }
  }
  if (!fs.existsSync(file)) return fail(res, 404, '文件不存在');
  const ext = path.extname(name).toLowerCase();
  const type = ext === '.m3u8' ? 'application/vnd.apple.mpegurl'
    : (ext === '.ts' ? 'video/mp2t'
      : (ext === '.m4s' ? 'video/iso.segment' : 'application/octet-stream'));
  fs.stat(file, (err, stat) => {
    if (err || !stat.isFile()) return fail(res, 404, '文件不存在');
    const sealed = uploadIsSealed(file);
    const total = sealed ? Math.max(0, stat.size - 20) : stat.size;
    const headers = {
      'Content-Type': type,
      /* 播放列表每次都要新的（重新生成过分片就要立刻生效），分片本身永远不变 */
      'Cache-Control': ext === '.m3u8' ? 'no-cache, must-revalidate' : 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
      'Accept-Ranges': 'bytes'
    };
    const range = String(req.headers.range || '').trim();
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (m && (m[1] || m[2])) {
      let start = m[1] ? parseInt(m[1], 10) : Math.max(0, total - parseInt(m[2], 10));
      let end = m[1] && m[2] ? parseInt(m[2], 10) : total - 1;
      if (isNaN(start) || isNaN(end) || start > end || start >= total) {
        res.writeHead(416, { 'Content-Range': 'bytes */' + total });
        res.end();
        return;
      }
      end = Math.min(end, total - 1);
      headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + total;
      headers['Content-Length'] = end - start + 1;
      res.writeHead(206, headers);
      if (sealed) {
        let part = null;
        try { part = readUploadRange(file, name, start, end); } catch (e2) { part = null; }
        if (part) return res.end(part);
      }
      return fs.createReadStream(file, { start: sealed ? start + 20 : start, end: sealed ? end + 20 : end }).pipe(res);
    }
    headers['Content-Length'] = total;
    res.writeHead(200, headers);
    if (sealed) return streamUploadPlain(file, res);
    fs.createReadStream(file).pipe(res);
  });
}

function serveStatic(req, res, pathname) {
  let rel = decodeURIComponent(pathname);
  /* 首页 = 新的登录/注册页（原来的桌面版仍在 /index.html?desktop=1） */
  if (rel === '/' || rel === '') rel = '/login.html';
  /* 有人把链接和中文标点一起复制走了（"…/Luchat.ipa）；"）：
     这种请求直接给真正的安装包，别回 404。 */
  /* 大小写、以及尾巴上粘着中文标点的情况，统一给真正的安装包（Linux 文件名区分大小写，
     以前 /luchat.ipa 也会 404）。 */
  if (/^\/luchat\.ipa/i.test(rel)) rel = '/Luchat.ipa';
  /* 视频分片（HLS）：先播放后加载 —— 播放器拿到第一段就能出画面，
     后面按播放进度边看边下，不用像整包 MP4 那样从头拖到尾 */
  if (rel.indexOf('/hls/') === 0) return serveHls(req, res, rel);
  if (rel.startsWith('/uploads/')) {
    /* 上传目录默认不对外裸奔：要么带服务器签发的签名，要么本人已登录 */
    if (secCfg().signUploads) {
      const name = path.basename(rel);
      let q = null;
      try { q = new URL(req.url, 'http://x').searchParams; } catch (err) { q = null; }
      const sigOk = q && uploadSigOk(name, q.get('e'), q.get('s'));
      if (!sigOk && !currentUser(req)) {
        strikeIp(clientInfo(req).ip, '裸链访问上传文件');
        uploadAccessLog(clientInfo(req).ip, 403, name, req.url);
        return fail(res, 403, '这个文件需要登录或签名链接才能访问');
      }
    }
    return sendFile(req, res, path.join(UPLOAD_DIR, path.basename(rel)), rel);
  }
  const target = path.join(PUBLIC_DIR, path.normalize(rel).replace(/^(\.\.[/\\])+/, ''));
  if (!target.startsWith(PUBLIC_DIR)) return fail(res, 403, '禁止访问');
  return sendFile(req, res, target, rel);
}

/* ------------------------------------------------------------------ 启动 */

loadStore();
loadSecurityState();   // 恢复「登录失败计数 / IP 封禁」（重启也不会被清掉）
ensureAdminKey();      // 后台入口暗号（没有就自动生成一个，写在 data/security.json）
migrateAllUserSecrets(); // 密码只存 scrypt 哈希：老账号/机器人里残留的明文就地转掉（原密码不变）
migrateMessagesToEncrypted(); // 聊天内容落盘加密：磁盘上剩下的明文消息一次性改成 AES-256-GCM 密文
migrateUploadsToEncrypted();  // 图片/语音/视频/文件同样加密落盘（AES-256-CTR + "LUC1" 头）
scheduleReminderTick();// 管家的定时提醒
/* 机器人相关要等模块全部加载完再做：给用户开欢迎会话时会走违规词检查，
   而违规检查用的 opsStore 在文件更下面才定义。原来在启动时就调用，会报
   「Cannot access 'opsStore' before initialization」——日志刷屏、欢迎语也发不出去。 */
setTimeout(() => {
  try {
    ensureBots();        // 建「AI 助手 / 管家 / 腾讯新闻」几个机器人账号，并和所有人加好友
    /* 一次性补齐：所有还没有机器人会话的用户（含之前注册的），都给他们开好欢迎会话 */
    db.users.filter((u) => !u.bot).forEach((u) => { try { attachBotsFor(u); } catch (e) { } });
    welcomeBots();       // 给主要账号开个「欢迎」会话，一打开就能看到机器人
  } catch (e) {
    console.log('[bots] 启动异常：' + e.message);
  }
}, 0);

async function handleHttpRequest(req, res) {
  res.__req = req;      // sendJson 里判断客户端要不要 gzip 用（别的地方不用管）
  const parsed = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));
  try {
    /* 被封的 IP：接口和上传文件一律 403；静态页面还让过，
       这样正常用户只是看到「操作失败」，不会整个 App 白屏。
       （状态存在 security-state.json，重启也不清） */
    const reqIp = clientInfo(req).ip;
    const bannedSec = ipBanRemain(reqIp);
    const gated = parsed.pathname.indexOf('/api') === 0 || parsed.pathname.indexOf('/uploads/') === 0;
    if (bannedSec && gated) {
      const body = JSON.stringify({ ok: false, error: '这个 IP 已被临时封禁，请 ' + Math.ceil(bannedSec / 60) + ' 分钟后再试', details: null });
      res.writeHead(403, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Retry-After': String(bannedSec) });
      res.end(body);
      return;
    }
    /* 后台入口：默认只允许局域网/本机（外网打进来直接 403） */
    if (isAdminPath(parsed.pathname) && !adminIpOk(peerIp(req))) {
      strikeIp(reqIp, '外网访问后台 ' + parsed.pathname);
      const body = JSON.stringify({ ok: false, error: '后台只允许局域网访问', details: null });
      res.writeHead(403, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
      res.end(body);
      return;
    }
    /* 后台一律走加密通道：明文 http 打开后台，密码和暗号会被同网段的人抓走。
       本机（127.0.0.1）除外，方便本地脚本；其它来源自动跳到 https://<主机>:5443。 */
    if (isAdminPath(parsed.pathname) && !req.socket.encrypted && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      const hostOnly = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
      res.writeHead(302, {
        Location: 'https://' + hostOnly + ':5443' + parsed.pathname + (parsed.search || ''),
        'Cache-Control': 'no-store'
      });
      res.end();
      return;
    }
    /* 前台（App / 网页版）也统一走加密通道：
       http://…:5180 上的任何请求都 308 跳到 https://…:5443。
       308 会保留请求方法和请求体，所以 App 不用改代码也能无感切换过来；
       浏览器里打开的 http://192.168.2.7:5180/m.html 也会自动变成 https。
       本机（127.0.0.1）不跳，方便服务器上的脚本和工具。 */
    if (!req.socket.encrypted && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      const hostOnly = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
      /* 只对「网页」做跳转（浏览器跟跳转没问题）；
         接口（/api）和上传文件不走跳转 —— App 里的登录态不会因为跨端口跳转丢掉，
         保证老版本 App 依然能正常用。App 的安全性靠"新版 App 内置 https 地址"来解决。 */
      const isPage = /^\/(index|m|install|admin|admin2|manage|ai|login)\.html$/i.test(parsed.pathname) || parsed.pathname === '/';
      if (!isPage) {
        /* 接口请求：以前为了兼容老版 App 原样放行 —— 等于把密码和令牌放在明文上过网，
           抓包就能用。现在只放行本机 / 局域网（服务器上的脚本、内网调试），
           公网来的明文接口一律让他改用 https（新版 App 本来就是 https/wss）。 */
        if (!isLocalOrLan(peerIp(req))) {
          if (parsed.pathname.indexOf('/api/login') === 0 && parsed.pathname.indexOf('phone') < 0) {
            securityNotePlainLogin(req);
          }
          return fail(res, 403, '请用加密通道访问：https://' + hostOnly + ':5443'
            + (parsed.pathname || '') + '（明文请求会被同网络的人抓到密码）');
        }
        if (parsed.pathname.indexOf('/api/login') === 0 && parsed.pathname.indexOf('phone') < 0) {
          securityNotePlainLogin(req);
        }
      } else {
      const headers = {
        Location: 'https://' + hostOnly + ':5443' + parsed.pathname + (parsed.search || ''),
        'Cache-Control': 'no-store'
      };
      /* 打包成 App 的网页版是从 file:// 发请求的，跨域跳转要在这一跳也带上 CORS 头 */
      const origin = req.headers.origin;
      if (origin && origin !== 'null') {
        try {
          const o = new URL(origin);
          if (/^(localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+)$/.test(o.hostname)) {
            headers['Access-Control-Allow-Origin'] = origin;
            headers['Access-Control-Allow-Credentials'] = 'true';
          }
        } catch (err) { /* 忽略 */ }
      } else if (origin === 'null') {
        headers['Access-Control-Allow-Origin'] = 'null';
      }
      res.writeHead(308, headers);
      res.end();
      return;
      }
    }
    /* 后台页面要带暗号才开：/manage.html?k=<暗号>（开过一次会记 30 天的 Cookie）。
       没带暗号的请求一律当「没这个页面」，扫描器扫过去只会看到 404。 */
    /* 一次性免密链接：/manage.html?k=…&m=<token> —— 用掉立刻作废，并把 m 从地址里去掉 */
    /* 带密码直接进：/manage.html?k=<暗号>&pw=<管理员密码>
       —— 页面自己拿 pw 去 /api/admin/quicklogin 换登录态（同源 fetch，Cookie 一定存得住），
          然后把 pw 从地址里去掉。这里只在密码不对时记一笔，不再做 302（302 设的 Cookie
          有些内置浏览器不保存，会变成「跳过去了但还是登录页」）。 */
    if (/^\/(manage|admin|admin2|ai)\.html$/i.test(parsed.pathname) && parsed.searchParams.get('pw')
        && !verifySecretRecord(adminAuth, String(parsed.searchParams.get('pw') || '').trim())) {
      strikeIp(reqIp, '后台免密参数不对');
    }
    if (/^\/(manage|admin|admin2|ai)\.html$/i.test(parsed.pathname) && parsed.searchParams.get('m')) {
      const magicAdmin = takeMagicToken(parsed.searchParams.get('m'));
      if (magicAdmin) {
        const hostOnly = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
        const proto = req.socket.encrypted ? 'https' : 'http';
        const port = req.socket.encrypted ? ':5443' : ':5180';
        res.writeHead(302, {
          Location: proto + '://' + hostOnly + port + parsed.pathname + '?k=' + encodeURIComponent(String(secCfg().adminKey || '')),
          'Set-Cookie': OPS_COOKIE + '=' + encodeURIComponent(signOpsToken(magicAdmin, peerIp(req)))
            + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + Math.floor(OPS_SESSION_TTL_MS / 1000),
          'Cache-Control': 'no-store'
        });
        audit(req, magicAdmin, '免密链接进入后台', magicAdmin.username, '一次性');
        res.end();
        return;
      }
      strikeIp(reqIp, '用过期的后台免密链接');
    }
    if (/^\/(manage|admin|admin2|ai|index)\.html$/i.test(parsed.pathname) && isAdminPath(parsed.pathname)) {
      if (!adminEntryOk(req, parsed.searchParams)) {
        /* 没暗号也不直接甩 404 —— 给一个「输入暗号」的小页面，
           这样你平时那个地址 http://192.168.2.7:5180/manage.html 还是能用，
           只是第一次要输一次暗号（输对了这台设备记 30 天）。 */
        const wrong = !!(parsed.searchParams.get('k') || '').length;
        if (wrong) strikeIp(reqIp, '后台暗号输错 ' + parsed.pathname);
        const html = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
          + '<title>后台入口</title><style>'
          + 'body{font:15px/1.7 -apple-system,"Microsoft YaHei",sans-serif;background:#0f1216;color:#dfe7ef;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}'
          + '.box{background:#161c24;border:1px solid #24303c;border-radius:12px;padding:26px 24px;width:320px;text-align:center}'
          + 'h1{font-size:16px;margin:0 0 6px;color:#7fc4ff}p{color:#7b8b9c;font-size:12px;margin:0 0 16px}'
          + 'input{width:100%;box-sizing:border-box;padding:10px 12px;border-radius:8px;border:1px solid #2c3a48;background:#0d1319;color:#fff;font-size:15px;letter-spacing:1px}'
          + 'button{width:100%;margin-top:12px;padding:11px;border:0;border-radius:8px;background:#2f7fd8;color:#fff;font-size:15px;font-weight:600}'
          + '.err{color:#ff8080;font-size:12px;margin-top:10px}</style>'
          + '<div class="box"><h1>管理员后台</h1><p>请输入后台访问暗号（在 桌面\\飞信\\后台密码.txt 里）</p>'
          + '<form method="get" action="' + parsed.pathname + '">'
          + '<input name="k" placeholder="访问暗号" autocomplete="off" autofocus>'
          + '<button type="submit">进入后台</button></form>'
          + (wrong ? '<div class="err">暗号不对，再试一次</div>' : '')
          + '</div>';
        res.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'Content-Length': Buffer.byteLength(html),
          'Cache-Control': 'no-store',
          'X-Frame-Options': 'DENY',
          'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"
        });
        res.end(html);
        return;
      }
      const key = String(secCfg().adminKey || '');
      if (key) res.setHeader('Set-Cookie', 'chris_admin_key=' + encodeURIComponent(key) + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000');
    }
    if (parsed.pathname.startsWith('/api')) {
      /* API 限流：按 IP 算，10 秒内最多 300 个 /api 请求（约 30/秒）。
         正常用（一个手机）远远到不了；爬数据/刷接口会被卡住。
         注意：/uploads/ 下面的图片不算，不然翻通讯录会被误伤。 */
      const ip = clientInfo(req).ip;
      if (!apiRateAllow(ip, parsed.pathname)) {
        return fail(res, 429, '请求太频繁，稍等一下再试');
      }
      /* 跨域支持：打包进 App 的版本界面来自 file:// ，发请求到这个服务器属于跨域 */
      const origin = req.headers.origin;
      /* 安全：只对「自己人」回显 Origin —— 同主机、局域网 IP、file:// / null。
         以前是把任意 Origin 都回显回去（evil.com 也回显），配合 Cookie 就是个隐患。 */
      const host = String(req.headers.host || '');
      let originAllowed = false;
      if (origin && origin !== 'null') {
        try {
          const o = new URL(origin);
          originAllowed = o.host === host ||
            /^(localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$/.test(o.hostname);
        } catch (err) { originAllowed = false; }
      }
      if (origin && originAllowed) {
        res.setHeader('Access-Control-Allow-Origin', origin);
        res.setHeader('Vary', 'Origin');
        res.setHeader('Access-Control-Allow-Credentials', 'true');
      } else {
        res.setHeader('Access-Control-Allow-Origin', '*');   // 不带 Cookie 的公开读（老客户端兼容）
      }
      res.setHeader('Access-Control-Allow-Headers', 'content-type, authorization');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
      res.setHeader('Access-Control-Max-Age', '600');
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
      await handleApi(req, res, parsed.pathname, parsed.searchParams);
      return;
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') return fail(res, 405, '静态资源只支持 GET');
    serveStatic(req, res, parsed.pathname);
  } catch (err) {
    const status = err.status || 500;
    if (status >= 500) console.error('[error]', err);
    fail(res, status, err.message || '服务器内部错误');
  }
}

const server = http.createServer(handleHttpRequest);

/* ============================================================
   后台只允许局域网/本机访问：
   /manage.html、/admin.html、/ai.html 和所有 /api/ops、/api/admin 接口，
   局域网以外的请求一律 403。以后如果要用隧道从外网管后台，
   把 data/ui.json 里的 adminLanOnly 改成 0 即可（不推荐）。
   ============================================================ */
function peerIp(req) {
  const raw = String((req.socket && req.socket.remoteAddress) || '').replace('::ffff:', '');
  if (raw === '127.0.0.1' || raw === '::1') {
    // 走隧道/本机代理时，真实来源在转发头里（只有本机才信这个头，防止伪造绕过）
    const fwd = String(req.headers['cf-connecting-ip'] || '').trim() ||
      String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
    if (fwd) return fwd.replace('::ffff:', '');
  }
  return raw;
}
function isLanAddress(ip) {
  const s = String(ip || '');
  return s === '127.0.0.1' || s === '::1' || s === 'localhost' ||
    /^10\./.test(s) || /^192\.168\./.test(s) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(s) || /^169\.254\./.test(s);
}
function adminLanOnlyOn() {
  const ui = readJson(path.join(DATA_DIR, 'ui.json'), {});
  return ui.adminLanOnly === undefined ? true : !!Number(ui.adminLanOnly);
}
function isAdminPath(pathname) {
  return pathname === '/manage.html' || pathname === '/admin.html' || pathname === '/ai.html' ||
    pathname.indexOf('/api/ops') === 0 || pathname.indexOf('/api/admin') === 0;
}

/** 后台入口暗号：数据里只存密文（scrypt + 盐），不再存明文。
    老数据里如果还是明文 adminKey，第一次验对的时候会自动升级成密文。 */
function adminKeyOk(k) {
  const file = path.join(DATA_DIR, 'security.json');
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return true; }
  const provided = String(k == null ? '' : k);
  if (raw.adminKeyHash && raw.adminKeySalt) {
    return verifySecretRecord({ salt: String(raw.adminKeySalt), hash: String(raw.adminKeyHash) }, provided);
  }
  if (raw.adminKey) {
    const ok = provided === String(raw.adminKey);
    if (ok) {
      /* 明文 → 密文：写回文件，把 adminKey 那行删掉 */
      try {
        const rec = makeSecretRecord(String(raw.adminKey));
        delete raw.adminKey;
        raw.adminKeyHash = rec.hash;
        raw.adminKeySalt = rec.salt;
        raw.adminKeyUpdatedAt = now();
        fs.writeFileSync(file, JSON.stringify(raw, null, 2), 'utf8');
        console.log('[安全] 后台入口暗号已从明文升级为密文');
      } catch (e) { }
    }
    return ok;
  }
  return true;       // 从来没设过暗号：不拦（老部署兼容）
}

/* 长连接的每 IP 限制（连接数 + 新建速率） */
/* 压测时可以临时放宽（用环境变量），默认值和以前一样 */
const WS_MAX_PER_IP = Number(process.env.WS_MAX_PER_IP) || 60;
const WS_NEW_PER_SEC = Number(process.env.WS_NEW_PER_SEC) || 30;
const wsConns = new Map();          // ip -> 当前条数
const wsRate = new Map();           // ip -> { t, n }

function wsAllow(ip) {
  const now = Date.now();
  const r = wsRate.get(ip) || { t: now, n: 0 };
  if (now - r.t > 1000) { r.t = now; r.n = 0; }
  r.n += 1;
  wsRate.set(ip, r);
  if (r.n > WS_NEW_PER_SEC) return 'rate';
  const cur = wsConns.get(ip) || 0;
  if (cur >= WS_MAX_PER_IP) return 'count';
  wsConns.set(ip, cur + 1);
  return '';
}
function wsRelease(ip) {
  const cur = wsConns.get(ip) || 0;
  if (cur <= 1) wsConns.delete(ip); else wsConns.set(ip, cur - 1);
}

/* API 限流：每 IP 10 秒最多 300 个 /api 请求 */
const API_WINDOW_MS = 10 * 1000;
/* 10 秒内的接口预算。原来是 200 —— 多人共用一个网络（家庭/公司 Wi-Fi、运营商 NAT）
   会共享这一个额度，一起用就容易被限流，表现成"卡/一直转圈"。
   放宽到 600（约 60/秒）仍然能挡住爬数据，但正常人怎么用都够。 */
const API_MAX_PER_WINDOW = Number(process.env.API_MAX_PER_WINDOW) || 600;
const apiHits = new Map();          // ip -> { t, n }

function apiRateAllow(ip, path) {
  const now = Date.now();
  let r = apiHits.get(ip);
  if (!r || now - r.t > API_WINDOW_MS) { r = { t: now, n: 0 }; apiHits.set(ip, r); }
  r.n += 1;
  if (apiHits.size > 5000) apiHits.clear();       // 防止这个表本身涨爆
  // 后台接口是人点出来的，单独放宽（600/10 秒）
  const cap = String(path || '').indexOf('/api/ops') === 0 ? 600 : API_MAX_PER_WINDOW;
  return r.n <= cap;
}

/* 发消息限流：每个人 10 秒最多 120 条（约 12 条/秒）。
   正常聊天绝对够；脚本刷屏、拿客户端当短信轰炸机都会被拦住。 */
const MSG_WINDOW_MS = 10 * 1000;
const MSG_MAX_PER_WINDOW = 60;    // 10 秒 60 条（约 6 条/秒），正常聊天够，刷屏会被卡
const msgHits = new Map();          // userId -> { t, n }

function msgRateAllow(userId) {
  const now = Date.now();
  let r = msgHits.get(userId);
  if (!r || now - r.t > MSG_WINDOW_MS) { r = { t: now, n: 0 }; msgHits.set(userId, r); }
  r.n += 1;
  if (msgHits.size > 5000) msgHits.clear();
  return r.n <= MSG_MAX_PER_WINDOW;
}

/* 全局消息吞吐闸门：防"多个账号一起刷"把硬盘写爆 / 把 CPU 打死 */
let globalMsgWindow = { t: Date.now(), n: 0 };
const GLOBAL_MSG_PER_SEC = 3000;
function globalMsgAllow() {
  const now = Date.now();
  if (now - globalMsgWindow.t > 1000) globalMsgWindow = { t: now, n: 0 };
  globalMsgWindow.n += 1;
  return globalMsgWindow.n <= GLOBAL_MSG_PER_SEC;
}

/* 文本清洗：文字炸弹（几千个换行 / 几千个一样的字 / 大量组合符）会让手机排版卡死 */
function sanitizeText(input) {
  let s = String(input == null ? '' : input);
  s = s.replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, '');        // 去掉控制字符（保留 \n）
  s = s.replace(/\n{4,}/g, '\n\n\n');                              // 最多 3 个连续换行
  s = s.replace(/(.)\1{60,}/g, (m, c) => c.repeat(60));            // 同一个字符最多重复 60 次
  s = s.replace(/([\u0300-\u036F\u0483-\u0489]{10,})/g, '$1'.slice(0, 10)); // 组合符压到 10 个
  s = s.replace(/\S{500,}/g, (m) => m.slice(0, 500) + '…');        // 一个没有空格的长串最多 500 字（排版最怕这种）
  return s.slice(0, 4000);
}

/* 朋友圈限流：每人 1 分钟最多 20 条、1 天最多 300 条（防刷爆数据和 CPU） */
const momentHits = new Map();       // userId -> { t, n, day, dayN }
function momentRateAllow(userId) {
  const now = Date.now();
  const day = Math.floor(now / 86400000);
  let r = momentHits.get(userId);
  if (!r) r = { t: now, n: 0, day, dayN: 0 };
  if (now - r.t > 60000) { r.t = now; r.n = 0; }
  if (r.day !== day) { r.day = day; r.dayN = 0; }
  momentHits.set(userId, r);
  if (momentHits.size > 5000) momentHits.clear();
  return r.n < 20 && r.dayN < 300 ? (r.n += 1, r.dayN += 1, true) : false;
}

/* 搜索限流：每人 10 秒最多 30 次。
   防止有人写脚本按字母表逐条扫，把全站通讯录一次性扒下来。 */
const searchHits = new Map();       // userId -> { t, n }
function searchRateAllow(userId) {
  const now = Date.now();
  let r = searchHits.get(userId);
  if (!r) r = { t: now, n: 0 };
  if (now - r.t > 10000) { r.t = now; r.n = 0; }
  r.n += 1;
  searchHits.set(userId, r);
  if (searchHits.size > 5000) searchHits.clear();
  return r.n <= 30;
}

/* 手机号验证码限流：每个 IP 10 分钟最多 10 次（防号码库撞库） */
const phoneCodeHits = new Map();    // ip -> { t, n }
function phoneCodeRateAllow(ip) {
  const now = Date.now();
  let r = phoneCodeHits.get(ip);
  if (!r || now - r.t > 600000) { r = { t: now, n: 0 }; phoneCodeHits.set(ip, r); }
  r.n += 1;
  if (phoneCodeHits.size > 5000) phoneCodeHits.clear();
  return r.n <= 10;
}

/* 面对面建群限流：每人 10 分钟最多 10 次（4 位数字太短，不禁就成穷举入口） */
const faceCodeHits = new Map();     // userId -> { t, n }
function faceCodeRateAllow(userId) {
  const now = Date.now();
  let r = faceCodeHits.get(userId);
  if (!r || now - r.t > 600000) { r = { t: now, n: 0 }; faceCodeHits.set(userId, r); }
  r.n += 1;
  if (faceCodeHits.size > 5000) faceCodeHits.clear();
  return r.n <= 10;
}

/* 上传配额：防止有人（或坏掉的客户端）一直传把硬盘塞满。
   每人 10 分钟最多 60 个文件、最多 200MB；整个上传目录超过 8GB 就不再收。 */
const UPLOAD_WINDOW_MS = 10 * 60 * 1000;
const UPLOAD_MAX_COUNT = 60;
const UPLOAD_MAX_BYTES = 200 * 1024 * 1024;
const UPLOAD_DIR_MAX = 8 * 1024 * 1024 * 1024;
const uploadHits = new Map();       // userId -> { t, n, bytes }

function uploadRateAllow(userId) {
  const now = Date.now();
  let r = uploadHits.get(userId);
  if (!r || now - r.t > UPLOAD_WINDOW_MS) { r = { t: now, n: 0, bytes: 0 }; uploadHits.set(userId, r); }
  if (uploadHits.size > 5000) uploadHits.clear();
  return r.n < UPLOAD_MAX_COUNT && r.bytes < UPLOAD_MAX_BYTES;
}
function noteUpload(userId, bytes) {
  const r = uploadHits.get(userId);
  if (!r) return;
  r.n += 1;
  r.bytes += bytes;
}
function uploadDirFull() {
  try {
    const files = fs.readdirSync(UPLOAD_DIR);
    let total = 0;
    for (const f of files) {
      try { total += fs.statSync(path.join(UPLOAD_DIR, f)).size; } catch (err) { }
    }
    return total > UPLOAD_DIR_MAX;
  } catch (err) { return false; }
}

function handleWsUpgrade(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key || String(req.headers.upgrade || '').toLowerCase() !== 'websocket') {
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
    return;
  }
  /* 实时通道必须是加密的 wss：明文 ws:// 会把令牌和聊天内容摊在网络上。
     公网来的明文 ws 一律挡掉（本机 / 局域网还留着，方便内网调试）。 */
  if (!req.socket.encrypted && !isLocalOrLan(clientInfo(req).ip)) {
    securityNotePlainWs(clientInfo(req).ip);
    strikeIp(clientInfo(req).ip, '明文 ws 连实时通道');
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  /* 连接数/连接速率限制：防止一个 IP 开几千条连接（每条都发几十 MB 畸形帧）把服务拖死。
     正常用户一个设备就一条长连接，60 条上限完全够。 */
  const wsIp = clientInfo(req).ip;
  if (ipBanRemain(wsIp)) {
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  const why = wsAllow(wsIp);
  if (why) {
    socket.end('HTTP/1.1 429 Too Many Requests\r\n\r\n');
    return;
  }
  socket.on('close', () => wsRelease(wsIp));
  let user = currentUser(req);
  if (!user) {
    /* 打包进 App 的版本带不了 Cookie，WebSocket 允许用 ?token= 认证 */
    try {
      const q = new URL(req.url, 'http://localhost');
      const data = verifyTokenData(q.searchParams.get('token'));
      const u = data && db.users.find((x) => x.id === data.sub);
      if (u && (data.v || 0) === (u.tokenVersion || 0)) user = u;
    } catch (err) { /* 忽略 */ }
  }
  if (user && user.banned) {
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  if (!user) {
    strikeIp(wsIp, '未授权连 WebSocket');
    socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n');
    return;
  }
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: ' + ws.acceptKey(key) + '\r\n\r\n'
  );
  socket.setNoDelay(true);
  /* 客户端会带 X-App-Build（"B456 · 09-23 21:08" 这种）——
     记在 socket 上，通话日志里打出来，排查「两台手机版本不一样」时一眼可见 */
  socket.__appBuild = String(req.headers['x-app-build'] || '').slice(0, 40);
  callTrace('ws 连上(带IP) ' + user.id + ' ip=' + wsIp + (socket.encrypted ? ' wss' : ' ws'));
  userIps.set(user.id, wsIp);           // 记一下每个账号的出口 IP：通话时判断两边是不是同一个网络
  handleSocket(user, socket);
}

server.on('upgrade', handleWsUpgrade);

server.on('error', (err) => {
  console.error('');
  if (err.code === 'EADDRINUSE') {
    console.error('  ✗ 启动失败：端口 ' + PORT + ' 已被占用。');
    console.error('    换端口：set PORT=5181 && node server.js');
  } else {
    console.error('  ✗ 启动失败：' + err.message);
  }
  console.error('');
});

server.listen(PORT, BIND_HOST, () => {
  console.log('CHRIS Chat 已启动');
  /* 内置 TURN：语音/视频通话直连不上时，声音走服务器中转（手机 4G、
     路由器 AP 隔离、公司网挡 UDP 这些情况全靠它）。端口 3478/udp。 */
  try {
    require('./turn.js').startTurn({
      port: TURN_PORT_NUM, user: TURN_USER, pass: TURN_PASS, realm: TURN_REALM,
      log: (m) => { console.log('  ' + m); callTrace(m); }
    });
  } catch (err) {
    console.log('  ✗ TURN 没起来：' + err.message);
  }
  const replayed = replayMomentsLog();          // 把上次没合并的朋友圈日志并回 moments.json
  if (replayed) console.log('  朋友圈 合并追加日志 ' + replayed + ' 条');
  console.log('  前台   http://' + HOST + ':' + PORT + '/');
  console.log('  管理   http://' + HOST + ':' + PORT + '/admin.html');
  if (BIND_HOST === '0.0.0.0') {
    // 顺便列出局域网地址，方便手机访问
    try {
      const nets = os.networkInterfaces();
      Object.keys(nets).forEach((name) => {
        (nets[name] || []).forEach((n) => {
          if (n.family === 'IPv4' && !n.internal) {
            console.log('  手机   http://' + n.address + ':' + PORT + '/   （' + name + '，手机连同一个 Wi-Fi）');
          }
        });
      });
    } catch (err) { /* 忽略 */ }
  }
  console.log('  数据   ' + DATA_DIR);
  console.log('  用户 ' + db.users.length + ' 人 · 会话 ' + db.chats.length + ' 个');
  try { expireTransfers(); } catch (err) { /* 忽略 */ }
  try { expireRedPackets(); } catch (err) { /* 忽略 */ }
  setInterval(() => {
    try { expireTransfers(); } catch (err) { /* 忽略 */ }
    try { expireRedPackets(); } catch (err) { /* 忽略 */ }
  }, 60 * 1000);
  if (adminJustCreated) {
    console.log('');
    console.log('  ┌────────────────────────────────────────────┐');
    console.log('  │  管理后台密码已生成                        │');
    console.log('  │  密码：' + DEFAULT_ADMIN_PASSWORD.padEnd(34) + '│');
    console.log('  │  文件：data/admin.json（scrypt 哈希）      │');
    console.log('  └────────────────────────────────────────────┘');
  } else {
    console.log('  管理   需要密码登录（密码存于 data/admin.json）');
  }
});

process.on('SIGINT', () => { console.log('\n正在退出…'); server.close(() => process.exit(0)); });
process.on('SIGTERM', () => process.exit(0));

/* 兜底：任何一处没接住的异常都不能让整个服务退出（否则一条恶意请求就能把所有人踢下线）。
   记一条日志，继续服务。 */
process.on('uncaughtException', (err) => {
  console.error('[未捕获异常] ' + (err && err.stack ? err.stack : err));
});
process.on('unhandledRejection', (reason) => {
  console.error('[未处理的 Promise 拒绝] ' + (reason && reason.stack ? reason.stack : reason));
});

/* -------------------------------------------------------------- HTTPS
   手机端语音/视频通话要用麦克风、摄像头，而浏览器只允许「安全页面」调用它们，
   http://192.168.x.x 这种局域网地址不算安全页面，所以额外起一个 HTTPS 端口。
   证书放在 app/tls/server.pfx（自签，第一次访问手机浏览器会提示不安全，点「继续访问」即可）。 */
const HTTPS_PORT = Number(process.env.HTTPS_PORT || 5443);
function startHttps() {
  const tlsDir = path.join(__dirname, 'tls');
  const pfxPath = path.join(tlsDir, 'server.pfx');
  const passPath = path.join(tlsDir, 'pass.txt');
  if (!fs.existsSync(pfxPath)) return;
  let passphrase = '';
  try { if (fs.existsSync(passPath)) passphrase = fs.readFileSync(passPath, 'utf8').trim(); } catch (err) { /* 忽略 */ }
  const httpsServer = https.createServer(
    { pfx: fs.readFileSync(pfxPath), passphrase: passphrase || undefined },
    handleHttpRequest
  );
  httpsServer.on('upgrade', handleWsUpgrade);
  httpsServer.on('error', (err) => console.error('  ✗ HTTPS 没起来：' + err.message));
  httpsServer.listen(HTTPS_PORT, BIND_HOST, () => {
    console.log('  通话   https://' + HOST + ':' + HTTPS_PORT + '/m.html   （手机用这个地址才能打电话）');
    if (BIND_HOST === '0.0.0.0') {
      try {
        const nets = os.networkInterfaces();
        Object.keys(nets).forEach((name) => {
          (nets[name] || []).forEach((n) => {
            if (n.family === 'IPv4' && !n.internal) {
              console.log('  通话   https://' + n.address + ':' + HTTPS_PORT + '/m.html   （手机用这个地址才能打电话）');
            }
          });
        });
      } catch (err) { /* 忽略 */ }
    }
  });
}
startHttps();

/* ==================================================================
   独立的管理员后台：/manage.html
   —— 多账号 + 角色权限 + 全量审计日志 + 敏感词风控 + 消息检索
   —— 只走 /api/ops/* 自己的接口，不直接碰数据库文件
   ================================================================== */

const OPS_FILE = 'ops.json';
const SENSITIVE_FILE = 'sensitive.json';
const REPORTS_FILE = 'reports.json';
const VIOLATIONS_FILE = 'violations.json';
const APPROVALS_FILE = 'ops-approvals.json';   // 高危操作的复核工单（双人复核）
const AUDIT_FILE = 'audit.log';
const ICONS_FILE = 'icons.json';
const OPS_COOKIE = 'chris_ops';

/* 角色 = 一串权限点（最小权限原则）。
   每个角色只拿到「干这件事需要的那几项」，读和写也分开：

   超管     全部（含支付、后台账号、界面配置、封号、解除好友）
   审核员   看用户资料 + 封号；看/撤回消息；风控（敏感词·违规）；处理举报；朋友圈删违规动态
   客服     看用户资料 + 重置密码；看消息（排查用户问题）。不能封号、不能看钱、不能动内容
   运维     服务器指标；发公告；看审计日志。**看不到任何用户资料和聊天记录**（隐私）
   ------------------------------------------------------------------ */
const OPS_ROLES = {
  super: ['dashboard', 'users', 'users.ban', 'users.reset', 'users.money',
    'messages', 'messages.write', 'friends', 'friends.write',
    'risk', 'risk.write', 'reports', 'moments', 'moments.write',
    'payments', 'payments.write', 'ops', 'ops.write', 'system',
    'audit', 'admins', 'icons', 'icons.write', 'support', 'support.write'],
  auditor: ['dashboard', 'users', 'users.ban', 'messages', 'messages.write',
    'risk', 'risk.write', 'reports', 'moments', 'moments.write', 'support'],
  support: ['dashboard', 'users', 'users.reset', 'messages', 'support', 'support.write'],
  ops: ['dashboard', 'system', 'ops', 'ops.write', 'audit']
};
const OPS_ROLE_NAMES = { super: '超级管理员', auditor: '审核员', support: '客服', ops: '运维' };

/* 红点提醒：后台可以逐个位置设成 auto（按真实数据）/ on（一直亮）/ off（不显示） */
const BADGE_DEFAULT = {
  chats: 'auto',        // 底部第一个「微信」：未读数字
  contacts: 'auto',     // 底部「通讯录」：有人加好友
  discover: 'auto',     // 底部「发现」：有人发朋友圈
  me: 'off',            // 底部「我」
  newFriends: 'auto',   // 通讯录里「新的朋友」那一行
  momentsRow: 'auto'    // 发现页里「朋友圈」那一行
};
const BADGE_KEYS = Object.keys(BADGE_DEFAULT);
const BADGE_VALUES = ['auto', 'on', 'off'];

const DEFAULT_SENSITIVE = ['赌博', '代开发票', '办证', '加微信刷单', '杀猪盘', '毒品'];



const opsStore = { admins: [], sensitive: [], reports: [], violations: [], approvals: [], dualReview: false };

function loadOps() {
  const raw = readJson(path.join(DATA_DIR, OPS_FILE), { admins: null });
  let admins = Array.isArray(raw.admins) ? raw.admins : [];
  if (!admins.length) {
    const salt = crypto.randomBytes(16).toString('hex');
    admins = [{
      id: uid('ops'), username: 'admin', name: '超级管理员', role: 'super',
      salt, hash: hashPassword(DEFAULT_ADMIN_PASSWORD, salt), createdAt: now(), disabled: false
    }];
    writeJson(path.join(DATA_DIR, OPS_FILE), { admins });
  }
  opsStore.admins = admins;

  const sen = readJson(path.join(DATA_DIR, SENSITIVE_FILE), { words: null });
  if (Array.isArray(sen.words)) {
    opsStore.sensitive = sen.words;
  } else {
    opsStore.sensitive = DEFAULT_SENSITIVE.slice();
    writeJson(path.join(DATA_DIR, SENSITIVE_FILE), { words: opsStore.sensitive });
  }
  opsStore.reports = readJson(path.join(DATA_DIR, REPORTS_FILE), []);
  opsStore.violations = readJson(path.join(DATA_DIR, VIOLATIONS_FILE), []);
  /* 高危操作的双人复核：默认关（只有一个管理员时不能开，否则谁都批不了） */
  opsStore.dualReview = !!raw.dualReview;
  opsStore.approvals = readJson(path.join(DATA_DIR, APPROVALS_FILE), []);
  if (!Array.isArray(opsStore.approvals)) opsStore.approvals = [];
}
const saveOpsAdmins = () => writeJson(path.join(DATA_DIR, OPS_FILE), { admins: opsStore.admins, dualReview: !!opsStore.dualReview });
const saveApprovals = () => writeJson(path.join(DATA_DIR, APPROVALS_FILE), opsStore.approvals);
const saveSensitive = () => writeJson(path.join(DATA_DIR, SENSITIVE_FILE), { words: opsStore.sensitive });
const saveReports = () => writeJson(path.join(DATA_DIR, REPORTS_FILE), opsStore.reports);
const saveViolations = () => writeJson(path.join(DATA_DIR, VIOLATIONS_FILE), opsStore.violations);

/** 审计日志：只追加，不提供删除接口 */
function audit(req, admin, action, target, detail) {
  /* 日志也会被刷爆：超过 5MB 就归档一份，别把硬盘写满 */
  try {
    const p = path.join(DATA_DIR, AUDIT_FILE);
    if (fs.existsSync(p) && fs.statSync(p).size > 5 * 1024 * 1024) {
      try { fs.renameSync(p, p + '.1'); } catch (err) { try { fs.unlinkSync(p + '.1'); fs.renameSync(p, p + '.1'); } catch (e2) { } }
    }
  } catch (err) { }
  const ip = clientInfo(req).ip;
  const line = JSON.stringify({
    at: now(),
    admin: admin ? admin.username : '-',
    name: admin ? admin.name : '-',
    role: admin ? (OPS_ROLE_NAMES[admin.role] || admin.role) : '-',
    ip, action, target: target || '', detail: detail || ''
  });
  try { fs.appendFileSync(path.join(DATA_DIR, AUDIT_FILE), line + '\n'); } catch (err) { /* 忽略 */ }
}

function readAudit(limit) {
  try {
    const text = fs.readFileSync(path.join(DATA_DIR, AUDIT_FILE), 'utf8').trim();
    if (!text) return [];
    return text.split('\n').slice(-limit).reverse().map((l) => {
      try { return JSON.parse(l); } catch (err) { return null; }
    }).filter(Boolean);
  } catch (err) { return []; }
}

/* 审计日志按「年月日」核对：可传 from / to（毫秒时间戳）+ 关键词，
   返回命中的行、总条数，以及每天各自的条数（给后台做按天分组用） */
function readAuditQuery(opt) {
  const o = opt || {};
  const limit = Math.min(5000, Math.max(10, Number(o.limit) || 200));
  const from = Number(o.from) || 0;
  const to = Number(o.to) || 0;
  const q = String(o.q || '').trim().toLowerCase();
  const maxScan = 200000;
  /* 日志里的 at 存的是 ISO 字符串（"2026-09-18T08:11:59.996Z"），
     老代码直接 Number() 会变成 NaN→0，全被算成 1970 年 1 月 1 日，这里统一解析 */
  const tsOf = (v) => {
    if (typeof v === 'number' && isFinite(v)) return v;
    const n = Date.parse(String(v == null ? '' : v));
    return isNaN(n) ? 0 : n;
  };
  const pad = (n) => String(n).padStart(2, '0');
  const dayKey = (t) => {
    const d = new Date(tsOf(t));
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  };
  let lines = [];
  try {
    const text = fs.readFileSync(path.join(DATA_DIR, AUDIT_FILE), 'utf8').trim();
    if (!text) return { rows: [], total: 0, days: [], truncated: false };
    lines = text.split('\n');
  } catch (err) {
    return { rows: [], total: 0, days: [], truncated: false };
  }
  const rows = [];
  const dayMap = new Map();
  let scanned = 0;
  let hit = 0;
  let truncated = false;
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    let a = null;
    try { a = JSON.parse(lines[i]); } catch (err) { continue; }
    if (!a) continue;
    scanned += 1;
    const at = tsOf(a.at);
    if (to && at > to) continue;                     // 比「结束日期」新 → 跳过
    if (from && at < from) break;                    // 日志是按时间追加的，更旧的不用再看
    if (q) {
      const hay = (String(a.name || '') + ' ' + String(a.admin || '') + ' ' + String(a.action || '') + ' '
        + String(a.target || '') + ' ' + String(a.detail || '') + ' ' + String(a.ip || '') + ' '
        + String(a.role || '')).toLowerCase();
      if (hay.indexOf(q) < 0) continue;
    }
    hit += 1;
    const k = dayKey(at);
    const dd = dayMap.get(k) || { day: k, count: 0, first: at, last: at };
    dd.count += 1;
    if (at < dd.first) dd.first = at;
    if (at > dd.last) dd.last = at;
    dayMap.set(k, dd);
    if (rows.length < limit) rows.push(a);
    else truncated = true;
    if (scanned >= maxScan) { truncated = true; break; }
  }
  const days = [...dayMap.values()].sort((x, y) => (x.day < y.day ? 1 : -1));
  return { rows, total: hit, days, truncated };
}

/* ---------------------------------------------------------- 敏感词 */

/* ==========================================================================
   风控引擎（腾讯式：多维打分 → 分级处置 → 证据留痕）
   信号：内容命中 / 外链 / 群发 / 频率 / 加好友过快 / 被举报 / 新设备 / 同 IP 多账号 / 历史处罚
   分级：正常 → 关注 → 受限（临时限功能）→ 高危（限功能 + 后台告警）
   注意：自动处置最多到"临时限制功能"，**封号永远要人工确认**。
   ========================================================================== */
const RISK_FILE = 'risk.json';
const RISK_EVENT_FILE = 'risk-events.jsonl';   // 只追加，作为处置证据
const RISK_DECAY_PER_HOUR = 4;                 // 每小时自然衰减 4 分（不白罚、也不轻易洗白）
let riskStoreCache = null;
let riskSaveTimer = null;

function loadRiskStore() {
  if (!riskStoreCache) riskStoreCache = readJson(path.join(DATA_DIR, RISK_FILE), { users: {} });
  if (!riskStoreCache.users) riskStoreCache.users = {};
  return riskStoreCache;
}
function saveRiskStore() {
  if (riskSaveTimer) return;
  riskSaveTimer = setTimeout(() => {
    riskSaveTimer = null;
    try { writeJson(path.join(DATA_DIR, RISK_FILE), loadRiskStore()); } catch (e) { }
  }, 3000);
}
function riskRecord(userId) {
  const s = loadRiskStore();
  const rec = s.users[userId] || (s.users[userId] = { score: 0, updatedAt: Date.now(), kinds: {}, restrictUntil: 0 });
  /* 时间衰减：离上次评估多久，就按小时往回退分 */
  const hours = Math.max(0, (Date.now() - (rec.updatedAt || Date.now())) / 3600000);
  if (hours > 0.05) rec.score = Math.max(0, Math.round((rec.score || 0) - hours * RISK_DECAY_PER_HOUR));
  rec.updatedAt = Date.now();
  return rec;
}
function riskLevelOf(score) {
  if (score >= 80) return { level: '高危', action: 'restrict24h' };
  if (score >= 60) return { level: '受限', action: 'restrict30m' };
  if (score >= 30) return { level: '关注', action: 'watch' };
  return { level: '正常', action: 'none' };
}
const RISK_DELTA = {
  sensitive: 25,      // 内容命中敏感词
  link: 10,           // 发外链
  mass_send: 30,      // 同一内容短时间发给很多人（群发/营销）
  fast_send: 15,      // 发送频率异常
  fast_friend: 20,    // 加好友过快（养号/营销）
  report: 20,         // 被举报
  login_new_device: 15, // 新设备/异地登录
  same_ip_multi: 15,  // 同一 IP 下大量不同账号
  signup_burst: 20,   // 同 IP 批量注册
};
/** 记一次风险事件，返回 {score, level, action} */
function riskEvent(user, kind, detail) {
  try {
    if (!user || !RISK_DELTA[kind]) return null;
    const rec = riskRecord(user.id);
    const delta = RISK_DELTA[kind];
    /* 历史处罚也计入（违规记录 / 被封禁次数） */
    let hist = 0;
    try {
      const viol = (opsStore.violations || []).filter((v) => v.userId === user.id).length;
      hist = Math.min(20, viol * 3) + Math.min(20, (Number(user.banCount) || 0) * 10);
    } catch (e) { }
    rec.kinds[kind] = (Number(rec.kinds[kind]) || 0) + 1;
    rec.score = Math.max(0, Math.min(100, Math.round((rec.score || 0) + delta + Math.min(4, rec.kinds[kind] - 1) * 2 + (hist > rec.histApplied ? (hist - (rec.histApplied || 0)) : 0))));
    rec.histApplied = Math.max(rec.histApplied || 0, hist);
    const lv = riskLevelOf(rec.score);
    /* 分级处置：只在"受限/高危"时限功能，且是临时限制，不是封号 */
    if (lv.action === 'restrict30m') rec.restrictUntil = Math.max(rec.restrictUntil || 0, Date.now() + 30 * 60 * 1000);
    if (lv.action === 'restrict24h') rec.restrictUntil = Math.max(rec.restrictUntil || 0, Date.now() + 24 * 3600 * 1000);
    /* 证据留痕（只追加，不覆盖） */
    try {
      /* 事件流也会涨：超过 2MB 归档一份，免得把硬盘写满 */
      const evp = path.join(DATA_DIR, RISK_EVENT_FILE);
      if (fs.existsSync(evp) && fs.statSync(evp).size > 2 * 1024 * 1024) {
        try { fs.renameSync(evp, evp + '.1'); } catch (e2) {
          try { fs.unlinkSync(evp + '.1'); fs.renameSync(evp, evp + '.1'); } catch (e3) { }
        }
      }
      fs.appendFileSync(path.join(DATA_DIR, RISK_EVENT_FILE), JSON.stringify({
        at: now(), userId: user.id, username: user.username, kind, delta,
        score: rec.score, level: lv.level, restrictUntil: rec.restrictUntil || 0,
        ip: (detail && detail.ip) || '', device: (detail && detail.device) || '',
        note: (detail && detail.note) || ''
      }) + '\n', 'utf8');
    } catch (e) { }
    saveRiskStore();
    if (lv.action === 'restrict24h') console.log(`  [风控] ${user.username} 评分 ${rec.score}（高危）→ 临时限制 24 小时`);
    else if (lv.action === 'restrict30m') console.log(`  [风控] ${user.username} 评分 ${rec.score}（受限）→ 临时限制 30 分钟`);
    return { score: rec.score, level: lv.level, action: lv.action };
  } catch (e) { return null; }
}
/** 被临时限制的账号：挡在发消息/加好友/发动态之前 */
function riskBlocked(user) {
  if (!user) return 0;
  const rec = loadRiskStore().users[user.id];
  if (!rec || !rec.restrictUntil || rec.restrictUntil <= Date.now()) return 0;
  return Math.ceil((rec.restrictUntil - Date.now()) / 60000);   // 还剩多少分钟
}

/* 群发检测：同一内容在 10 分钟内发给了几个不同会话 */
const recentTextSends = new Map();   // userId -> [{hash, chatId, at}]
function noteTextSend(userId, chatId, text) {
  const list = (recentTextSends.get(userId) || []).filter((x) => Date.now() - x.at < 10 * 60 * 1000);
  const hash = crypto.createHash('sha1').update(String(text || '')).digest('hex').slice(0, 12);
  list.push({ hash, chatId, at: Date.now() });
  recentTextSends.set(userId, list.slice(-60));
  const same = list.filter((x) => x.hash === hash);
  const chats = new Set(same.map((x) => x.chatId));
  return chats.size;   // 同一内容发给了几个会话
}
/** 同一 IP 近一小时出现过几个不同账号（登录/注册） */
function ipAccountCount(ip) {
  try {
    return new Set((db.security.logins || [])
      .filter((l) => l.ip === ip && Date.now() - new Date(l.time).getTime() < 3600000)
      .map((l) => l.userId)).size;
  } catch (e) { return 0; }
}
/** 这个设备是不是该用户第一次用（粗粒度：IP+设备指纹） */
function isNewDevice(user, req) {
  try {
    const info = clientInfo(req);
    const seen = (db.security.logins || []).filter((l) => l.userId === user.id);
    if (!seen.length) return false;
    return !seen.some((l) => l.ip === info.ip || l.device === info.device);
  } catch (e) { return false; }
}

/* 每个账号自己记「登过的设备」（最多 10 条，最近的排前面）。
   滑动验证的「新设备」判断靠这张表 —— 全局的 security.logins 只有 600 条，
   用户一多就被别人的记录挤掉了，拿它判断等于永远不弹。 */
function rememberDevice(user, req) {
  try {
    if (!user) return;
    const info = clientInfo(req);
    const key = deviceKeyOf(info);
    const list = (Array.isArray(user.devices) ? user.devices : [])
      .filter((d) => deviceKeyOf(d) !== key);
    list.unshift({ id: info.deviceId || '', ip: info.ip, device: info.device, at: now() });
    if (list.length > 10) list.length = 10;
    user.devices = list;
    user.deviceUpdatedAt = now();
  } catch (e) { }
}

/** 一条设备记录 / 一次请求的「设备身份」：有设备 id 就用 id，没有才退回 IP+UA */
function deviceKeyOf(d) {
  if (d && d.deviceId) return 'id:' + String(d.deviceId);
  if (d && d.id) return 'id:' + String(d.id);
  return String((d && d.ip) || '') + '|' + String((d && d.device) || '');
}

/** 这台设备 / 这个出口 IP 在这个账号的设备表里见过吗 */
function knownDevice(user, req) {
  try {
    const info = clientInfo(req);
    const list = Array.isArray(user.devices) ? user.devices : [];
    if (!list.length) return true;            // 老账号还没这张表：不弹（别吓着老用户）
    if (info.deviceId) {
      /* 带设备 id 的表：认 id。表里全是老记录（还没有 id）时才退回 IP/UA 判断 */
      if (list.every((d) => !d.id)) {
        return list.some((d) => d.ip === info.ip || d.device === info.device);
      }
      return list.some((d) => d.id === info.deviceId);
    }
    return list.some((d) => d.ip === info.ip || d.device === info.device);
  } catch (e) { return true; }
}

/* 登录要不要弹滑动验证。跟微信一个思路：**默认不弹**，正常登录一路过；
   只有出现风险信号才要求补一次验证：
     ① 这台设备 / 这个出口 IP 从没登录过这个账号（新设备、异地登录）
     ② 最近 10 分钟内这个账号（≥3 次）或这个 IP（≥5 次）密码错得多
   想整层关掉：data/security.json 里写 "sliderLogin": 0。 */
function loginNeedsSlider(req, user) {
  try {
    if (!user) return false;
    const info = clientInfo(req);
    const t = Date.now();
    const byUser = LOGIN_FAILS.get('u:' + String(user.username || '').toLowerCase());
    if (byUser && t - byUser.first <= LOGIN_WINDOW_MS && byUser.n >= 3) return true;
    const byIp = LOGIN_FAILS.get('ip:' + info.ip);
    if (byIp && t - byIp.first <= LOGIN_WINDOW_MS && byIp.n >= 5) return true;
    /* 这台设备 / 这个 IP 从没见过 → 弹一次。
       设备表为空（老账号第一次用新版）等于「还不知道」，这时候不弹，
       免得所有老用户一升级就被要求验证。 */
    if (!knownDevice(user, req)) return true;
  } catch (e) { /* 风控出问题不能挡住正常登录 */ }
  return false;
}

/* 违规告警：以前只调不定义（命中敏感词会直接报错），这里补上 ——
   一份进后台「敏感词·违规」列表，一份进风控打分（sensitive +25）。 */
function recordViolation(user, chat, body, word) {
  try {
    const row = {
      id: uid('vio'),
      at: now(),
      userId: user ? user.id : '',
      username: user ? user.username : '',
      nickname: user ? (user.nickname || user.username) : '',
      chatId: chat ? chat.id : '',
      kind: chat ? 'chat' : 'content',
      word: String(word || ''),
      content: String(body || '').slice(0, 200),
      handled: false
    };
    opsStore.violations.unshift(row);
    if (opsStore.violations.length > 500) opsStore.violations.length = 500;
    saveViolations();
    if (user) riskEvent(user, 'sensitive', { note: '命中敏感词「' + word + '」' });
    return row;
  } catch (e) { return null; }
}

/* ---------------- 其余风控信号：登录 / 注册 / 加好友 ---------------- */
/** 登录风险评估。必须在 recordSecurity 之前调用：否则「这台设备以前登过没有」永远算不准 */
function noteLoginRisk(user, req) {
  try {
    if (!user || user.bot) return;                 // 机器人不参与风控，免得把评分榜刷满
    const info = clientInfo(req);
    if (isNewDevice(user, req)) riskEvent(user, 'login_new_device', { ip: info.ip, device: info.device, note: '新设备 / 异地登录' });
    const n = ipAccountCount(info.ip);
    if (n >= 8) riskEvent(user, 'same_ip_multi', { ip: info.ip, device: info.device, note: '同 IP 一小时内出现 ' + n + ' 个账号' });
  } catch (e) { }
}
/** 同一个 IP 24 小时内注册过几个账号 */
function signupSameIpCount(ip) {
  try {
    const cut = Date.now() - 24 * 3600 * 1000;
    return (db.security.logins || []).filter((l) => l.kind === 'register' && l.ip === ip
      && new Date(l.time).getTime() > cut).length;
  } catch (e) { return 0; }
}
/** 注册风险：同 IP 批量注册（机房换 IP 前最常见的薅号手法）。同样要放在 recordSecurity 之前 */
function noteSignupRisk(user, req) {
  try {
    const info = clientInfo(req);
    const n = signupSameIpCount(info.ip) + 1;      // 算上当前这一个
    if (n >= 3) riskEvent(user, 'signup_burst', { ip: info.ip, device: info.device, note: '同 IP 24 小时内注册 ' + n + ' 个账号' });
  } catch (e) { }
}
/** 加好友过快：10 分钟内发起的申请次数（营销号一天加几百个人的典型特征） */
const recentFriendReqs = new Map();
function noteFriendReqRisk(user) {
  const list = (recentFriendReqs.get(user.id) || []).filter((t) => Date.now() - t < 10 * 60 * 1000);
  list.push(Date.now());
  recentFriendReqs.set(user.id, list.slice(-200));
  if (list.length >= 10) riskEvent(user, 'fast_friend', { note: '10 分钟内发起 ' + list.length + ' 次好友申请' });
  return list.length;
}

/* ---------------- 后台风控面板要用的数据 ---------------- */
/** 评分榜：只看有分或有临时限制的账号，按分数倒序 */
function riskBoard(limit) {
  const s = loadRiskStore();
  return Object.keys(s.users).map((id) => {
    const rec = riskRecord(id);                    // 顺手做一次时间衰减
    const u = findUser(id);
    const lv = riskLevelOf(rec.score);
    return {
      userId: id,
      username: u ? u.username : '(已注销)',
      nickname: u ? (u.nickname || u.username) : '',
      score: Math.round(rec.score || 0),
      level: lv.level,
      banned: !!(u && u.banned),
      restrictMinutes: rec.restrictUntil && rec.restrictUntil > Date.now()
        ? Math.ceil((rec.restrictUntil - Date.now()) / 60000) : 0,
      kinds: rec.kinds || {},
      updatedAt: rec.updatedAt || 0
    };
  }).filter((r) => r.score > 0 || r.restrictMinutes > 0)
    .sort((a, b) => b.score - a.score || b.updatedAt - a.updatedAt)
    .slice(0, limit || 50);
}
/** 最近的风险事件（证据流，倒序） */
function riskEventsTail(limit) {
  try {
    const p = path.join(DATA_DIR, RISK_EVENT_FILE);
    if (!fs.existsSync(p)) return [];
    const text = fs.readFileSync(p, 'utf8').trim();
    if (!text) return [];
    return text.split('\n').slice(-(limit || 100)).reverse().map((l) => {
      try { return JSON.parse(l); } catch (e) { return null; }
    }).filter(Boolean);
  } catch (e) { return []; }
}

function sensitiveHit(text) {
  const s = String(text || '');
  if (!s) return '';
  for (let i = 0; i < opsStore.sensitive.length; i += 1) {
    const w = opsStore.sensitive[i];
    if (w && s.indexOf(w) >= 0) return w;
  }
  return '';
}

/* ---------------------------------------------------------- 后台登录态 */

function signOpsToken(admin, ip) {
  const payload = Buffer.from(JSON.stringify({
    sub: 'ops_' + admin.id, role: admin.role, exp: Date.now() + OPS_SESSION_TTL_MS,
    ip: ipFingerprint(ip)          // 令牌绑定登录时的 IP
  })).toString('base64url');
  const sig = crypto.createHmac('sha256', adminAuth.secret).update(payload).digest('base64url');
  return payload + '.' + sig;
}

function currentOps(req) {
  const auth = String((req.headers && req.headers.authorization) || '');
  let token = /^bearer\s+/i.test(auth) ? auth.replace(/^bearer\s+/i, '').trim() : '';
  if (!token) token = parseCookies(req)[OPS_COOKIE] || '';
  if (!token) return null;
  const parts = token.split('.');
  if (parts.length !== 2) return null;
  const expect = crypto.createHmac('sha256', adminAuth.secret).update(parts[0]).digest('base64url');
  const a = Buffer.from(parts[1]);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  let data = null;
  try { data = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8')); } catch (err) { return null; }
  if (!data || typeof data.exp !== 'number' || data.exp <= Date.now()) return null;
  if (!data.sub || String(data.sub).indexOf('ops_') !== 0) return null;
  /* 令牌绑了 IP：换了 IP 就等于失效（防被人拷走 Cookie 在他机器上用） */
  if (data.ip && data.ip !== ipFingerprint(clientInfo(req).ip)) return null;
  const admin = opsStore.admins.find((x) => x.id === String(data.sub).slice(4));
  if (!admin || admin.disabled) return null;
  return admin;
}

function opsMe(admin) {
  return {
    id: admin.id, username: admin.username, name: admin.name, role: admin.role,
    roleName: OPS_ROLE_NAMES[admin.role] || admin.role,
    perms: OPS_ROLES[admin.role] || []
  };
}

function can(admin, perm) {
  const perms = OPS_ROLES[admin.role] || [];
  return perms.indexOf(perm) >= 0;
}

/* ==========================================================================
   高危操作的闸门：二次确认（+ 可选双人复核）
   ① 二次确认：不管点得多顺手，都要再输一次「当前登录管理员自己的密码」。
   ② 双人复核：后台默认关闭；一旦开启，下面这几类不可逆操作要另一个管理员
      用他自己的密码批准后才真正执行（腾讯的 4-eyes 那一层）。
   ③ 所有拦截、提交、批准、驳回都写审计日志（audit.log），不给删除接口。
   ========================================================================== */
const DANGEROUS_OPS = [
  { re: /^POST \/api\/ops\/users\/[^/]+\/ban$/, label: '封禁 / 解封账号' },
  { re: /^POST \/api\/ops\/users\/[^/]+\/reset$/, label: '重置用户密码' },
  { re: /^POST \/api\/ops\/messages\/[^/]+\/recall$/, label: '强制撤回消息' },
  { re: /^POST \/api\/ops\/chats\/[^/]+\/clear$/, label: '清空会话记录' },
  { re: /^POST \/api\/ops\/groups\/[^/]+\/dismiss$/, label: '解散群聊' },
  { re: /^POST \/api\/ops\/friendships\/[^/]+\/remove$/, label: '解除好友关系' },
  { re: /^DELETE \/api\/ops\/moments\/[^/]+$/, label: '删除朋友圈动态' },
  { re: /^DELETE \/api\/ops\/feed\/posts\/[^/]+$/, label: '删除视频号作品' },
  { re: /^POST \/api\/ops\/payments\/[^/]+\/revoke$/, label: '撤销交易' },
  { re: /^POST \/api\/ops\/payments\/freeze$/, label: '冻结 / 解冻账号（支付风控）' },
  { re: /^POST \/api\/ops\/wallet\/op$/, label: '处理提现申请' },
  { re: /^POST \/api\/ops\/system\/announce$/, label: '发布系统公告' },
  { re: /^POST \/api\/ops\/admins$/, label: '新增后台账号' },
  { re: /^POST \/api\/ops\/admins\/[^/]+\/disable$/, label: '停用 / 启用后台账号' },
  { re: /^POST \/api\/ops\/magic$/, label: '生成免密登录链接' },
  /* 敏感词库不算高危：它可逆、且日常维护脚本（管控违法内容.js）要反复调用，不设卡 */
];
/* 开了双人复核以后，这些「做完就回不了头」的操作必须别人点头 */
const DUAL_REVIEW_LABELS = [
  '封禁 / 解封账号', '撤销交易', '处理提现申请', '解散群聊', '清空会话记录',
  '删除朋友圈动态', '删除视频号作品', '解除好友关系', '新增后台账号', '停用 / 启用后台账号'
];
function dangerousOpOf(method, pathStr) {
  const key = method + ' ' + pathStr;
  for (let i = 0; i < DANGEROUS_OPS.length; i += 1) {
    if (DANGEROUS_OPS[i].re.test(key)) return DANGEROUS_OPS[i];
  }
  return null;
}
/** 二次确认：必须是「当前这个管理员自己的密码」，不是别人的、也不是链接里的暗号 */
function opsConfirmOk(admin, body) {
  const pw = String((body && body.confirmPassword) || '').trim();
  if (!pw) return false;
  try { return verifySecretRecord({ salt: admin.salt, hash: admin.hash }, pw); } catch (e) { return false; }
}
function canSeeApprovals(admin) {
  return admin.role === 'super' || can(admin, 'risk') || can(admin, 'ops') || can(admin, 'admins');
}
/* 复核工单的「原始参数」只放在内存里：重置密码这种操作，明文密码不进磁盘。
   落盘的只有脱敏版本（给后台列表看）。服务器重启后旧单子要重新提交，这是故意的。 */
const pendingOpBodies = new Map();
function sanitizeApprovalBody(body) {
  const out = {};
  Object.keys(body || {}).forEach((k) => {
    out[k] = /password|secret|token|passwd/i.test(k) ? '******' : body[k];
  });
  return out;
}
/* 复核工单只留最近 7 天 / 最多 200 条，别把 json 撑大 */
function pruneApprovals() {
  const cut = Date.now() - 7 * 86400000;
  opsStore.approvals = opsStore.approvals
    .filter((x) => x && ((x.status === 'pending') || (new Date(x.at).getTime() > cut)))
    .slice(0, 200);
  if (pendingOpBodies.size > 400) {
    const keep = {};
    opsStore.approvals.forEach((x) => { keep[x.id] = 1; });
    Array.from(pendingOpBodies.keys()).forEach((id) => { if (!keep[id]) pendingOpBodies.delete(id); });
  }
}

/* ---------------------------------------------------------- 统计 */

const msgTimes = [];               // 最近一分钟的消息时间戳（算 QPS）
let totalMessages = 0;
const STATS_FILE = 'stats.json';
const dailyStats = readJson(path.join(DATA_DIR, STATS_FILE), { day: '', messages: 0 });

function dayKey(ts) {
  const d = ts ? new Date(ts) : new Date();
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}
function localDayStart() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}
function saveDailyStats() { writeJson(path.join(DATA_DIR, STATS_FILE), dailyStats); }

function noteMessage() {
  totalMessages += 1;
  msgTimes.push(Date.now());
  const cut = Date.now() - 60000;
  while (msgTimes.length && msgTimes[0] < cut) msgTimes.shift();
  const key = dayKey();
  if (dailyStats.day !== key) { dailyStats.day = key; dailyStats.messages = 0; }
  dailyStats.messages += 1;
  if (dailyStats.messages % 10 === 0) saveDailyStats();
}
function messagesPerMinute() { return msgTimes.length; }

/* ---------------------------------------------------------- 路由 */

async function handleOps(req, res, parts, query) {
  const method = req.method.toUpperCase();
  const sub = parts[1] || '';

  if (sub === 'login' && method === 'POST') {
    const body = await readBody(req);
    const username = str(body.username, 24).toLowerCase();
    const password = String(body.password || '');
    /* 后台密码不允许走明文 http（同网段抓包就拿到），本机除外 */
    if (!req.socket.encrypted && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      strikeIp(clientInfo(req).ip, '明文 HTTP 登录后台');
      audit(req, { username: username || '-', name: '未知', role: '-' }, '明文登录被拒', '', '要求改用 HTTPS');
      return fail(res, 403, httpsHint(req));
    }
    const kIp = 'ip:' + clientInfo(req).ip;
    const kUser = 'ops:' + username;
    /* 后台比普通登录更严：5 次错密码锁 30 分钟（账号和 IP 各算一遍） */
    const wait = Math.max(opsLoginBlocked(kUser), opsLoginBlocked(kIp), loginBlocked(kIp));
    if (wait) return fail(res, 429, '密码错误次数太多，请 ' + Math.ceil(wait / 60) + ' 分钟后再试');
    const admin = opsStore.admins.find((a) => a.username === username && !a.disabled);
    if (!admin || !verifySecretRecord({ salt: admin.salt, hash: admin.hash }, password)) {
      audit(req, { username: username || '-', name: '未知', role: '-' }, '登录失败', '', '账号或密码不对');
      noteLoginFail(kUser);
      noteLoginFail(kIp);
      noteOpsFail(kUser);
      noteOpsFail(kIp);
      return fail(res, 401, '账号或密码不正确');
    }
    clearLoginFails([kUser, kIp]);
    clearOpsFails([kUser, kIp]);
    admin.lastLoginAt = now();
    admin.lastIp = clientInfo(req).ip;
    saveOpsAdmins();
    audit(req, admin, '登录', '', 'IP ' + admin.lastIp);
    ok(res, { admin: opsMe(admin) }, {
      'Set-Cookie': OPS_COOKIE + '=' + encodeURIComponent(signOpsToken(admin, clientInfo(req).ip))
        + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + Math.floor(OPS_SESSION_TTL_MS / 1000)
    });
    return;
  }

  if (sub === 'session' && method === 'GET') {
    const admin = currentOps(req);
    ok(res, { authenticated: !!admin, admin: admin ? opsMe(admin) : null });
    return;
  }

  if (sub === 'logout' && method === 'POST') {
    const admin = currentOps(req);
    if (admin) audit(req, admin, '退出登录', '', '');
    ok(res, { loggedOut: true }, { 'Set-Cookie': OPS_COOKIE + '=; Path=/; HttpOnly; Max-Age=0' });
    return;
  }

  const admin = currentOps(req);
  if (!admin) return fail(res, 401, '请先登录管理后台');

  /* 界面配置类（UI 图标 / 发现页 / 我的页 / 界面文字 / 状态面板 / 表情 / 礼物 / +面板 / 应用名 / 图标上传）
     只有「超级管理员」能看能改 —— 客服、审核员、运维这些角色连读都读不到。 */
  const UI_SUBS = ['icons', 'discover', 'mepage', 'service', 'wallet', 'balance-page', 'bills-page', 'uiconfig', 'statuses', 'stickers', 'gifts', 'plus-panel', 'branding', 'upload', 'loginpage', 'badges'];
  if (UI_SUBS.indexOf(sub) >= 0 && admin.role !== 'super') {
    return fail(res, 403, '界面配置只有超级管理员能看和改');
  }

  /* ---------------- 风控面板：评分榜 + 证据流 + 待复核 ---------------- */
  if (sub === 'risk' && method === 'GET') {
    if (!can(admin, 'risk')) return fail(res, 403, '你的角色没有查看风控的权限');
    ok(res, {
      board: riskBoard(100),
      events: riskEventsTail(120),
      approvals: opsStore.approvals.slice(0, 50),
      dualReview: !!opsStore.dualReview,
      scores: RISK_DELTA,
      levels: { watch: 30, restrict30m: 60, restrict24h: 80 }
    });
    return;
  }

  /* 人工解除临时限制（评分清零 + 撤掉限功能）——身份不对造成的误伤，管理员可以放行 */
  if (sub === 'risk' && parts[2] === 'release' && method === 'POST') {
    if (!can(admin, 'risk.write')) return fail(res, 403, '你的角色没有处置风控的权限');
    const body = await readBody(req);
    const targetId = str(body.userId, 40);
    const rec = loadRiskStore().users[targetId];
    if (!rec) return fail(res, 404, '这个账号没有风控记录');
    const before = Math.round(rec.score || 0);
    rec.score = Math.max(0, Number(body.score) || 0);   // 不传就是直接清零
    rec.restrictUntil = 0;
    if (rec.score === 0) rec.kinds = {};
    rec.updatedAt = Date.now();
    saveRiskStore();
    const u = findUser(targetId);
    audit(req, admin, '解除风控限制', (u && u.username) || targetId, '原评分 ' + before + ' → ' + rec.score);
    ok(res, { released: true, score: rec.score });
    return;
  }

  /* ---------------- 高危操作闸门：二次确认（+ 双人复核） ---------------- */
  const opPath = '/api/' + parts.join('/');
  const danger = req.__opsApproved ? null : dangerousOpOf(method, opPath);
  if (danger) {
    let dangerBody = {};
    try { dangerBody = await readBody(req); } catch (e) { dangerBody = {}; }
    if (!opsConfirmOk(admin, dangerBody)) {
      audit(req, admin, '高危操作被拦（密码没对上）', danger.label, opPath);
      return fail(res, 428, '这是高危操作「' + danger.label + '」，请再输入一次你自己的后台密码确认');
    }
    if (opsStore.dualReview && DUAL_REVIEW_LABELS.indexOf(danger.label) >= 0) {
      const pend = {
        id: uid('apv'), at: now(),
        byId: admin.id, by: admin.username, byName: admin.name, role: admin.role,
        label: danger.label, method, path: opPath, parts: parts.slice(),
        body: sanitizeApprovalBody(dangerBody),   // 落盘的只有脱敏参数，明文密码不留档
        ip: clientInfo(req).ip, status: 'pending',
        decidedBy: '', decidedAt: 0, note: ''
      };
      pendingOpBodies.set(pend.id, Object.assign({}, dangerBody, { confirmPassword: '' }));
      opsStore.approvals.unshift(pend);
      pruneApprovals();
      saveApprovals();
      audit(req, admin, '提交高危操作待复核', danger.label, pend.id + ' · ' + opPath);
      return ok(res, {
        pendingApproval: pend.id,
        needSecondAdmin: true,
        label: danger.label,
        hint: '已经提交复核：需要另一个管理员在「风控引擎 → 双人复核」里用他自己的密码批准后才执行'
      });
    }
    audit(req, admin, '高危操作二次确认通过', danger.label, opPath);
  }

  /* ---------------- 双人复核工单 ---------------- */
  if (sub === 'approvals' && method === 'GET') {
    if (!canSeeApprovals(admin)) return fail(res, 403, '你的角色没有查看复核工单的权限');
    const others = opsStore.admins.filter((a) => !a.disabled && a.id !== admin.id).length;
    ok(res, {
      enabled: !!opsStore.dualReview,
      others,
      approvals: opsStore.approvals.slice(0, 100),
      labels: DUAL_REVIEW_LABELS
    });
    return;
  }

  /* 开关本身也是敏感动作：只有超管能改，开启时必须先有两个后台账号 */
  if (sub === 'approvals' && parts[2] === 'settings' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能改双人复核开关');
    const body = await readBody(req);
    if (body.enabled) {
      const others = opsStore.admins.filter((a) => !a.disabled && a.id !== admin.id).length;
      if (others < 1) return fail(res, 422, '至少要有两个后台账号才能开启双人复核（现在只有你一个，开了谁都批不了）');
      if (!opsConfirmOk(admin, body)) return fail(res, 428, '开启双人复核需要再输入一次你的后台密码');
    }
    opsStore.dualReview = !!body.enabled;
    saveOpsAdmins();
    audit(req, admin, opsStore.dualReview ? '开启双人复核' : '关闭双人复核', '', '');
    ok(res, { enabled: !!opsStore.dualReview });
    return;
  }

  if (sub === 'approvals' && parts[2] && (parts[3] === 'approve' || parts[3] === 'reject') && method === 'POST') {
    if (!canSeeApprovals(admin)) return fail(res, 403, '你的角色没有复核权限');
    const pend = opsStore.approvals.find((x) => x.id === parts[2]);
    if (!pend) return fail(res, 404, '复核单不存在');
    if (pend.status !== 'pending') return fail(res, 409, '这张复核单已经处理过了');
    const body = await readBody(req);
    if (!opsConfirmOk(admin, body)) return fail(res, 428, '复核需要再输入一次你自己的后台密码');
    if (pend.byId === admin.id) return fail(res, 403, '不能自己批准自己提交的高危操作，请让另一个管理员来批');
    if (parts[3] === 'reject') {
      pend.status = 'rejected';
      pend.decidedBy = admin.username;
      pend.decidedAt = now();
      pend.note = str(body.note, 120) || '复核驳回';
      saveApprovals();
      audit(req, admin, '驳回高危操作', pend.label, pend.id + ' · 申请人 ' + pend.by);
      ok(res, { approved: false, label: pend.label });
      return;
    }
    /* 批准：把原请求原样重放一次，这次带上「已复核」标记，闸门直接放行 */
    const rawBody = pendingOpBodies.get(pend.id);
    if (!rawBody) {
      return fail(res, 409, '这一单的原始参数已经不在了（服务器重启过），请让申请人重新提交一次');
    }
    pend.status = 'approved';
    pend.decidedBy = admin.username;
    pend.decidedAt = now();
    saveApprovals();
    audit(req, admin, '复核通过高危操作', pend.label, pend.id + ' · 申请人 ' + pend.by);
    const replay = {
      method: pend.method,
      headers: req.headers,
      socket: req.socket,
      __bodyPromise: Promise.resolve(rawBody),
      __opsApproved: pend.id,
      __opsApprover: admin.username
    };
    try {
      await handleOps(replay, res, pend.parts, new URLSearchParams());
    } catch (e) {
      if (!res.headersSent) return fail(res, 500, '复核通过了，但执行时报错：' + ((e && e.message) || e));
    }
    pendingOpBodies.delete(pend.id);
    return;
  }

  /* ---------------- 仪表盘 ---------------- */
  if (sub === 'dashboard' && method === 'GET') {
    if (!can(admin, 'dashboard')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const nowMs = Date.now();
    const day0 = localDayStart();
    const today = db.security.logins.filter((l) => nowMs - new Date(l.time).getTime() < 86400000);
    const newUsersToday = db.users.filter((u) => new Date(u.createdAt).getTime() >= day0).length;
    const transfersToday = db.transfers.filter((t) => new Date(t.createdAt).getTime() >= day0);
    const todayAmount = Math.round(transfersToday.reduce((a, t) => a + (Number(t.amount) || 0), 0) * 100) / 100;
    const todayMsgs = dailyStats.day === dayKey() ? dailyStats.messages : 0;
    // 异常交易：单笔 ≥2000、或者同一对人今天来回转账 ≥3 笔
    const pairCount = {};
    transfersToday.forEach((t) => {
      const k = [t.fromId, t.toId].sort().join('|');
      pairCount[k] = (pairCount[k] || 0) + 1;
    });
    const abnormal = transfersToday.filter((t) => Number(t.amount) >= 2000
      || (pairCount[[t.fromId, t.toId].sort().join('|')] || 0) >= 3).slice(0, 8).map((t) => ({
      id: t.id,
      amount: t.amount,
      at: t.createdAt,
      status: t.status,
      from: (findUser(t.fromId) || {}).nickname || '—',
      to: (findUser(t.toId) || {}).nickname || '—',
      reason: Number(t.amount) >= 2000 ? '单笔大额' : '短时间多次转账'
    }));
    const unhandledVio = opsStore.violations.filter((v) => !v.handled).length;
    const openReports = opsStore.reports.filter((r) => r.status === 'open').length;
    /* 客服工单：没处理的有几条（后台菜单上挂个小数字） */
    const pendingSupport = readSupportTickets(500).filter((t) => (t.status || 'pending') === 'pending').length;
    const mem = process.memoryUsage();
    ok(res, {
      stats: {
        users: db.users.length,
        online: onlineUserIds().length,
        bots: db.users.filter((u) => u.bot).length,
        banned: db.users.filter((u) => u.banned).length,
        chats: db.chats.length,
        messages: totalMessages,
        msgPerMin: messagesPerMinute(),
        friends: db.friendships.filter((f) => f.status === 'accepted').length,
        pendingFriends: db.friendships.filter((f) => f.status === 'pending').length,
        moments: db.moments.length,
        transfers: db.transfers.length,
        logins24h: today.length,
        violations: unhandledVio,
        reports: openReports,
        newUsersToday,
        messagesToday: todayMsgs,
        transfersToday: transfersToday.length,
        amountToday: todayAmount,
        abnormal: abnormal.length,
        support: pendingSupport
      },
      health: {
        uptime: Math.round(process.uptime()),
        memoryMB: Math.round(mem.rss / 1024 / 1024),
        heapMB: Math.round(mem.heapUsed / 1024 / 1024),
        node: process.version,
        dataDir: DATA_DIR
      },
      alerts: opsStore.violations.filter((v) => !v.handled).slice(0, 8).map((v) => ({
        at: v.at, who: v.nickname || v.username, word: v.word, content: v.content
      })),
      abnormal,
      recentLogins: today.slice(0, 8).map((l) => ({
        time: l.time, ip: l.ip, device: l.device, user: (findUser(l.userId) || {}).nickname || l.userId
      }))
    });
    return;
  }

  /* ---------------- 用户管理 ---------------- */
  /* ---------------- 登录页外观（颜色 / 背景图 / 图标 / 文案）---------------- */
  const LOGIN_DEFAULT = {
    accent: '#07C160', bg: '#f2f3f5', card: '#ffffff', text: '#181818', sub: '#8a8f99',
    bgImage: '', logo: '', appName: '', subTitle: '', darkAccent: '#07C160', darkBg: '#111214', darkCard: '#1c1c1e', darkText: '#eceff3',
    /* App 登录页用的（手机号登录那条蓝色、禁用色） */
    accent2: '#007AFF', disabledAccent: '#B2E4C8', disabledGray: '#C7C7CC', pageBg: '',
    /* 用户协议 / 隐私政策全文（后台可编辑） */
    terms: ['1. 本应用是自建的即时通讯软件，账号与数据都保存在你自己的服务器上。',
      '2. 请勿使用本应用传播违法违规内容；一经发现，管理员有权封禁账号。',
      '3. 你的昵称、头像、朋友圈等资料仅用于本应用内的展示，不会提供给第三方。',
      '4. 聊天内容保存在你自己的服务器数据库中，用于在登录设备之间同步。',
      '5. 修改密码后，之前的登录令牌会立即失效，需要重新登录。',
      '6. 如不同意以上条款，请不要使用本应用。'].join('\n'),
    privacy: ['1. 我们收集的信息：昵称、头像、地区、个性签名，以及你主动发送的消息与图片。',
      '2. 信息用途：仅用于在本应用内展示和在你的登录设备之间同步。',
      '3. 存储位置：全部保存在你自己的服务器上，不会上传到任何第三方服务。',
      '4. 分享范围：你的朋友圈对好友可见；聊天内容仅你与对方可见。',
      '5. 你的权利：可以随时修改资料、换头像、清空聊天记录，或要求管理员删除账号。',
      '6. 安全措施：账号密码加密存储、登录令牌加密签名、后台操作全程审计。'].join('\n')
  };
  /* 红点提醒：后台逐个位置设置 */
  if (sub === 'badges' && method === 'GET') {
    ok(res, { badges: Object.assign({}, BADGE_DEFAULT, db.badges || {}), defaults: BADGE_DEFAULT, keys: BADGE_KEYS, values: BADGE_VALUES });
    return;
  }
  if (sub === 'badges' && method === 'POST') {
    const body = await readBody(req);
    const next = Object.assign({}, BADGE_DEFAULT, db.badges || {});
    BADGE_KEYS.forEach((k) => {
      const v = str(body[k], 8);
      if (BADGE_VALUES.indexOf(v) >= 0) next[k] = v;
    });
    db.badges = next;
    saveBadges();
    audit(req, admin, '修改红点提醒', '-', JSON.stringify(next));
    ok(res, { badges: next });
    return;
  }

  if (sub === 'loginpage' && method === 'GET') {
    const cur = (db.branding && db.branding.login) || {};
    ok(res, { login: Object.assign({}, LOGIN_DEFAULT, cur), defaults: LOGIN_DEFAULT });
    return;
  }
  if (sub === 'loginpage' && method === 'POST') {
    const body = await readBody(req);
    const cur = (db.branding && db.branding.login) || {};
    const hex = (v, dft) => {
      const s = str(v, 9).trim();
      return /^#[0-9a-fA-F]{6}$/.test(s) ? s.toUpperCase() : dft;
    };
    const imgRef = (v, dft) => {
      const s = str(v, 2000).trim();
      if (!s) return '';
      const safe = safeImageRef(s);
      return safe === null ? dft : safe;
    };
    const next = {
      accent: hex(body.accent, LOGIN_DEFAULT.accent),
      bg: hex(body.bg, LOGIN_DEFAULT.bg),
      card: hex(body.card, LOGIN_DEFAULT.card),
      text: hex(body.text, LOGIN_DEFAULT.text),
      sub: hex(body.sub, LOGIN_DEFAULT.sub),
      darkAccent: hex(body.darkAccent, LOGIN_DEFAULT.darkAccent),
      darkBg: hex(body.darkBg, LOGIN_DEFAULT.darkBg),
      darkCard: hex(body.darkCard, LOGIN_DEFAULT.darkCard),
      darkText: hex(body.darkText, LOGIN_DEFAULT.darkText),
      /* 这几个字段「没传」就保留原来的值 —— 否则每次保存都会把背景图/图标/名字清空 */
      bgImage: body.bgImage === undefined ? String(cur.bgImage || '') : imgRef(body.bgImage, ''),
      logo: body.logo === undefined ? String(cur.logo || '') : imgRef(body.logo, ''),
      appName: body.appName === undefined ? String(cur.appName || '') : str(body.appName, 20),
      subTitle: body.subTitle === undefined ? String(cur.subTitle || '') : str(body.subTitle, 30),
      accent2: hex(body.accent2, LOGIN_DEFAULT.accent2),
      disabledAccent: hex(body.disabledAccent, LOGIN_DEFAULT.disabledAccent),
      disabledGray: hex(body.disabledGray, LOGIN_DEFAULT.disabledGray),
      pageBg: body.pageBg ? hex(body.pageBg, '') : '',
      terms: body.terms === undefined ? (cur && cur.terms) || LOGIN_DEFAULT.terms : str(body.terms, 20000),
      privacy: body.privacy === undefined ? (cur && cur.privacy) || LOGIN_DEFAULT.privacy : str(body.privacy, 20000)
    };
    db.branding.login = next;
    /* 应用名一处改、全站生效：登录页的名字也同步成全局应用名 */
    if (next.appName) db.branding.appName = next.appName;
    db.branding.updatedAt = now();
    saveBranding();
    audit(req, admin, '修改登录页外观', 'loginpage', '主色 ' + next.accent + (next.bgImage ? ' · 带背景图' : ''));
    ok(res, { login: next });
    return;
  }

  if (sub === 'users' && method === 'GET' && parts.length === 2) {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40).toLowerCase();
    let list = db.users.slice();
    if (q) {
      list = list.filter((u) => String(u.username).toLowerCase().indexOf(q) >= 0
        || String(u.nickname || '').toLowerCase().indexOf(q) >= 0
        || String(u.phone || '').indexOf(q) >= 0
        || String(u.id) === q);
    }
    list.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    const limit = Math.min(200, Math.max(1, Number(query.get('limit')) || 50));
    const online = onlineUserIds();
    ok(res, {
      total: list.length,
      users: list.slice(0, limit).map((u) => Object.assign(publicUser(u), {
        phone: u.phone || '',
        balance: Number(u.balance) || 0,
        banned: !!u.banned,
        banReason: u.banReason || '',
        online: online.indexOf(u.id) >= 0,
        friendCount: db.friendships.filter((f) => f.status === 'accepted'
          && (f.fromId === u.id || f.toId === u.id)).length,
        chatCount: db.chats.filter((c) => c.memberIds.indexOf(u.id) >= 0).length
      }))
    });
    return;
  }

  if (sub === 'users' && parts.length === 3 && method === 'GET') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const u = findUser(parts[2]);
    if (!u) return fail(res, 404, '用户不存在');
    audit(req, admin, '查看用户详情', u.username, u.id);
    const logins = db.security.logins.filter((l) => l.userId === u.id).slice(0, 20);
    const friends = db.friendships.filter((f) => f.status === 'accepted'
      && (f.fromId === u.id || f.toId === u.id)).map((f) => {
      const other = findUser(f.fromId === u.id ? f.toId : f.fromId);
      return other ? { id: other.id, username: other.username, nickname: other.nickname, avatar: other.avatar || '' } : null;
    }).filter(Boolean);
    const chats = db.chats.filter((c) => c.memberIds.indexOf(u.id) >= 0).map((c) => chatSummary(c, u.id));
    ok(res, {
      user: Object.assign(publicUser(u), {
        phone: u.phone || '', balance: Number(u.balance) || 0,
        banned: !!u.banned, banReason: u.banReason || '',
        online: onlineUserIds().indexOf(u.id) >= 0,
        favorites: Array.isArray(u.favorites) ? u.favorites.length : 0
      }),
      logins, friends, chats
    });
    return;
  }

  if (sub === 'users' && parts[3] === 'ban' && method === 'POST') {
    if (!can(admin, 'users.ban')) return fail(res, 403, '你的角色没有封禁权限');
    const u = findUser(parts[2]);
    if (!u) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    setUserBanned(u, body.banned, body.reason, admin.username);
    audit(req, admin, u.banned ? '封禁账号' : '解封账号', u.username,
      u.banReason || ('踢掉 ' + '所有设备的登录态'));
    ok(res, { banned: !!u.banned, banReason: u.banReason || '', kicked: !!u.banned });
    return;
  }

  if (sub === 'users' && parts[3] === 'reset' && method === 'POST') {
    if (!can(admin, 'users.reset')) return fail(res, 403, '你的角色没有重置密码权限');
    const u = findUser(parts[2]);
    if (!u) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    const pwd = String(body.password || '').trim();
    if (pwd.length < 6) return fail(res, 422, '新密码至少 6 位');
    u.salt = crypto.randomBytes(16).toString('hex');
    u.passwordHash = hashPassword(pwd, u.salt);
    u.tokenVersion = (u.tokenVersion || 0) + 1;      // 旧登录立刻失效
    saveUsers();
    audit(req, admin, '重置密码', u.username, '');
    ok(res, { reset: true });
    return;
  }

  /* ---------------- 消息 & 会话检索 ---------------- */
  if (sub === 'messages' && method === 'GET') {
    if (!can(admin, 'messages')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40);
    const kind = str(query.get('kind'), 20);
    const userQ = str(query.get('user'), 40).toLowerCase();
    const from = Number(query.get('from')) || 0;
    const to = Number(query.get('to')) || 0;
    const limit = Math.min(200, Math.max(1, Number(query.get('limit')) || 50));
    const out = [];
    db.chats.forEach((c) => {
      const msgs = loadMessages(c.id);
      for (let i = msgs.length - 1; i >= 0 && out.length < limit; i -= 1) {
        const m = msgs[i];
        if (kind && m.kind !== kind) continue;
        const ts = new Date(m.createdAt).getTime();
        if (from && ts < from) continue;
        if (to && ts > to) continue;
        const sender = findUser(m.senderId);
        if (userQ) {
          const hay = ((sender && (sender.nickname + ' ' + sender.username)) || '') + ' ' + c.id;
          if (hay.toLowerCase().indexOf(userQ) < 0) continue;
        }
        if (q && String(m.content || '').indexOf(q) < 0) continue;
        out.push({
          id: m.id, chatId: c.id, chatTitle: chatSummary(c, m.senderId).title,
          senderId: m.senderId, senderName: sender ? (sender.nickname || sender.username) : '未知',
          kind: m.kind, content: String(m.content || '').slice(0, 500),
          createdAt: m.createdAt, recalled: !!m.recalled, seq: m.seq
        });
      }
    });
    audit(req, admin, '检索消息', q || kind || userQ || '(全部)', '返回 ' + out.length + ' 条');
    ok(res, { messages: out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt))) });
    return;
  }

  if (sub === 'messages' && parts[3] === 'recall' && method === 'POST') {
    if (!can(admin, 'messages.write')) return fail(res, 403, '你的角色没有强制撤回权限');
    const body = await readBody(req);
    const chatId = str(body.chatId, 60);
    const chat = db.chats.find((c) => c.id === chatId);
    if (!chat) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const msg = messages.find((m) => m.id === parts[2]);
    if (!msg) return fail(res, 404, '消息不存在');
    msg.recalled = true;
    try {
      saveMessagesFile(chat.id, messages);
    } catch (err) { return fail(res, 500, '写入失败'); }
    sendToChat(chat, { type: 'recall', chatId: chat.id, messageId: msg.id });
    audit(req, admin, '强制撤回消息', parts[2], '会话 ' + chatId);
    ok(res, { message: msg });
    return;
  }

  if (sub === 'chats' && parts[3] === 'clear' && method === 'POST') {
    if (!can(admin, 'messages.write')) return fail(res, 403, '你的角色没有清空会话权限');
    const chat = db.chats.find((c) => c.id === parts[2]);
    if (!chat) return fail(res, 404, '会话不存在');
    const file = path.join(DATA_DIR, 'messages', chat.id + '.jsonl');
    try { fs.writeFileSync(file, ''); } catch (err) { /* 忽略 */ }
    messageCache.delete(chat.id);
    audit(req, admin, '清空会话', chat.id, '');
    ok(res, { cleared: true });
    return;
  }

  /* 后台：以某个用户的名义建一个群（联调 / 测试用，不受「只能是好友」限制）
     POST /api/ops/group/create { username, name, members: [用户名...] } */
  if (sub === 'group' && parts[2] === 'create' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能建群');
    const body = await readBody(req);
    const owner = findUserByName(str(body.username, 24));
    if (!owner) return fail(res, 404, '没有这个用户');
    const name = str(body.name, 30) || '群聊测试';
    const members = [owner.id];
    (Array.isArray(body.members) ? body.members : []).forEach((x) => {
      const t = findUserByName(str(x, 24));
      if (t && members.indexOf(t.id) < 0) members.push(t.id);
    });
    if (members.length < 2) return fail(res, 422, '至少再加一个人');
    const chat = {
      id: uid('c'), type: 'group', name: name, avatar: '',
      memberIds: members, ownerId: owner.id, seq: 0, createdAt: now()
    };
    db.chats.push(chat);
    buildGroupAvatar(chat);            // 九宫格群头像
    chat.seq = 1;
    const others = members.slice(1).map((id) => (findUser(id) || {}).nickname || '').filter(Boolean);
    const sysMsg = {
      id: uid('m'), chatId: chat.id, seq: 1, senderId: 'system', kind: 'system',
      content: '你邀请 ' + others.join('、') + ' 加入了群聊',
      createdAt: now(), recalled: false
    };
    appendMessage(chat.id, sysMsg);
    saveChats();
    members.forEach((id) => {
      sendTo(id, { type: 'chat', action: 'created', chat: chatSummary(chat, id) });
      sendTo(id, { type: 'message', message: sysMsg, chat: chatSummary(chat, id), clientId: null });
    });
    audit(req, admin, '后台建群', chat.id, name + ' · ' + members.length + ' 人');
    ok(res, {
      chat: { id: chat.id, name: chat.name, avatar: chat.avatar, memberCount: members.length }
    });
    return;
  }

  /* 群组管理：后台解散一个群（对应 PC 后台清单里的「群组管理 / 群组设置」） */
  if (sub === 'groups' && method === 'GET') {
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(50, Number(query.get('pageSize')) || 20);
    const kw = str(query.get('q'), 30).toLowerCase();
    let list = db.chats.filter((c) => c.type === 'group');
    if (kw) list = list.filter((c) => String(c.name || '').toLowerCase().indexOf(kw) >= 0);
    list = list.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    ok(res, {
      total: list.length, page: page, pageSize: pageSize,
      groups: list.slice((page - 1) * pageSize, page * pageSize).map((c) => {
        const messages = loadMessages(c.id);
        const last = messages.length ? messages[messages.length - 1] : null;
        const pv = lastPreviewMessage(messages);
        return {
          id: c.id, name: c.name || '', avatar: c.avatar || '',
          owner: (findUser(c.ownerId) || {}).nickname || '',
          memberCount: c.memberIds.length,
          members: c.memberIds.slice(0, 12).map((id) => publicUser(findUser(id))).filter(Boolean),
          messageCount: messages.length,
          lastPreview: pv ? previewTextOf(pv) : '',
          createdAt: c.createdAt,
          muteAll: !!c.muteAll
        };
      })
    });
    return;
  }

  if (sub === 'groups' && parts[2] === 'dismiss' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能解散群聊');
    const chat = db.chats.find((c) => c.id === parts[1] && c.type === 'group');
    if (!chat) return fail(res, 404, '群不存在');
    const members = chat.memberIds.slice();
    const sys = pushSystemMessage(chat, '管理员解散了该群聊');
    members.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    chat.memberIds = [];
    chat.dismissed = true;
    saveChats();
    members.forEach((id) => sendTo(id, { type: 'chat', action: 'removed', chatId: chat.id }));
    audit(req, admin, '后台解散群聊', chat.id, chat.name + ' · 原 ' + members.length + ' 人');
    ok(res, { dismissed: true });
    return;
  }

  /* ---------------- 用户反馈（App「设置 → 意见反馈」提交的那些） ---------------- */
  if (sub === 'feedback' && method === 'GET') {
    const rows = [];
    try {
      const raw = fs.readFileSync(path.join(DATA_DIR, 'feedback.jsonl'), 'utf8');
      raw.split('\n').forEach((line) => {
        const t = line.trim();
        if (!t) return;
        try { rows.push(JSON.parse(t)); } catch (err) { /* 坏行跳过 */ }
      });
    } catch (err) { /* 还没人反馈过 */ }
    const limit = Math.min(500, Math.max(1, Number(query.get('limit')) || 200));
    ok(res, { items: rows.slice(-limit).reverse(), total: rows.length });
    return;
  }

  /* ---------------- 好友关系 ---------------- */
  if (sub === 'friendships' && method === 'GET') {
    if (!can(admin, 'friends')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const status = str(query.get('status'), 20);
    let list = db.friendships.slice();
    if (status) list = list.filter((f) => f.status === status);
    list = list.slice(-300).reverse();
    ok(res, {
      friendships: list.map((f) => {
        const a = findUser(f.fromId), b = findUser(f.toId);
        return {
          id: f.id, status: f.status, createdAt: f.createdAt,
          from: a ? { id: a.id, username: a.username, nickname: a.nickname, banned: !!a.banned } : null,
          to: b ? { id: b.id, username: b.username, nickname: b.nickname, banned: !!b.banned } : null
        };
      })
    });
    return;
  }

  if (sub === 'friendships' && parts[3] === 'remove' && method === 'POST') {
    if (!can(admin, 'friends.write')) return fail(res, 403, '你的角色没有解除好友权限');
    const f = db.friendships.find((x) => x.id === parts[2]);
    if (!f) return fail(res, 404, '这条好友关系不存在');
    db.friendships = db.friendships.filter((x) => x.id !== f.id);
    saveFriendships();
    audit(req, admin, '解除好友关系', f.id, f.fromId + ' ↔ ' + f.toId);
    ok(res, { removed: true });
    return;
  }

  /* ---------------- 风控 / 敏感词 ---------------- */
  if (sub === 'sensitive' && method === 'GET') {
    if (!can(admin, 'risk')) return fail(res, 403, '你的角色没有查看风控的权限');
    ok(res, { words: opsStore.sensitive, violations: opsStore.violations.slice(0, 100) });
    return;
  }

  if (sub === 'sensitive' && method === 'POST') {
    if (!can(admin, 'risk.write')) return fail(res, 403, '你的角色没有改敏感词的权限');
    const body = await readBody(req);
    const add = str(body.add, 40);
    const del = str(body.remove, 40);
    if (add && opsStore.sensitive.indexOf(add) < 0) opsStore.sensitive.push(add);
    if (del) opsStore.sensitive = opsStore.sensitive.filter((w) => w !== del);
    saveSensitive();
    audit(req, admin, add ? '新增敏感词' : '删除敏感词', add || del, '');
    ok(res, { words: opsStore.sensitive });
    return;
  }

  if (sub === 'violations' && parts[3] === 'handle' && method === 'POST') {
    if (!can(admin, 'risk.write')) return fail(res, 403, '没有权限');
    const v = opsStore.violations.find((x) => x.id === parts[2]);
    if (!v) return fail(res, 404, '这条告警不存在');
    v.handled = true;
    v.handledBy = admin.username;
    v.handledAt = now();
    saveViolations();
    audit(req, admin, '处理违规告警', v.id, v.word);
    ok(res, { handled: true });
    return;
  }

  /* ---------------- 举报 ---------------- */
  if (sub === 'reports' && method === 'GET') {
    if (!can(admin, 'reports')) return fail(res, 403, '你的角色没有处理举报的权限');
    ok(res, { reports: opsStore.reports.slice(0, 200) });
    return;
  }

  if (sub === 'reports' && parts[3] === 'handle' && method === 'POST') {
    if (!can(admin, 'reports')) return fail(res, 403, '没有权限');
    const r = opsStore.reports.find((x) => x.id === parts[2]);
    if (!r) return fail(res, 404, '举报不存在');
    const body = await readBody(req);
    r.status = body.ban ? 'banned' : 'done';
    r.note = str(body.note, 200);
    r.handledBy = admin.username;
    r.handledAt = now();
    if (body.ban) {
      const u = findUser(r.targetUserId);
      if (u) setUserBanned(u, true, '举报核实：' + (r.reason || ''), admin.username);
    }
    saveReports();
    audit(req, admin, body.ban ? '举报处理-封号' : '举报处理', r.id, r.reason || '');
    ok(res, { handled: true });
    return;
  }

  /* ---------------- 朋友圈 ---------------- */
  if (sub === 'moments' && method === 'GET') {
    if (!can(admin, 'moments')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40);
    let list = db.moments.slice();
    if (q) list = list.filter((m) => String(m.content || '').indexOf(q) >= 0);
    ok(res, {
      moments: list.slice(0, 100).map((m) => {
        const a = findUser(m.authorId);
        return {
          id: m.id, content: m.content || '', images: m.images || [], createdAt: m.createdAt,
          author: a ? { id: a.id, username: a.username, nickname: a.nickname } : null,
          likes: (m.likes || []).length, comments: (m.comments || []).length
        };
      })
    });
    return;
  }

  if (sub === 'moments' && parts.length === 3 && method === 'DELETE') {
    if (!can(admin, 'moments.write')) return fail(res, 403, '你的角色没有删动态权限');
    const idx = db.moments.findIndex((m) => m.id === parts[2]);
    if (idx === -1) return fail(res, 404, '动态不存在');
    const [removed] = db.moments.splice(idx, 1);
    saveMoments();
    audit(req, admin, '删除朋友圈动态', removed.id, String(removed.content || '').slice(0, 60));
    ok(res, { deleted: true });
    return;
  }

  /* ---------------- 支付风控 ---------------- */
  if (sub === 'payments' && method === 'GET' && parts.length === 2) {
    if (!can(admin, 'payments')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40).toLowerCase();
    const status = str(query.get('status'), 20);
    const from = Number(query.get('from')) || 0;
    const to = Number(query.get('to')) || 0;
    const min = Number(query.get('min')) || 0;
    const max = Number(query.get('max')) || 0;
    let list = db.transfers.slice();
    if (status) list = list.filter((t) => t.status === status);
    if (from) list = list.filter((t) => new Date(t.createdAt).getTime() >= from);
    if (to) list = list.filter((t) => new Date(t.createdAt).getTime() <= to);
    if (min) list = list.filter((t) => Number(t.amount) >= min);
    if (max) list = list.filter((t) => Number(t.amount) <= max);
    if (q) {
      list = list.filter((t) => {
        const a = findUser(t.fromId), b = findUser(t.toId);
        const hay = [a && a.username, a && a.nickname, b && b.username, b && b.nickname, t.note, t.id]
          .join(' ').toLowerCase();
        return hay.indexOf(q) >= 0;
      });
    }
    const allToday = db.transfers.filter((t) => new Date(t.createdAt).getTime() >= localDayStart());
    ok(res, {
      transfers: list.slice(0, 300).map((t) => {
        const from = findUser(t.fromId), to = findUser(t.toId);
        return {
          id: t.id, amount: t.amount, note: t.note || '', status: t.status, method: t.method,
          createdAt: t.createdAt, receivedAt: t.receivedAt || '', refundedAt: t.refundedAt || '',
          from: from ? { id: from.id, username: from.username, nickname: from.nickname, banned: !!from.banned } : null,
          to: to ? { id: to.id, username: to.username, nickname: to.nickname, banned: !!to.banned } : null
        };
      }),
      total: db.transfers.length,
      filtered: list.length,
      pending: db.transfers.filter((t) => t.status === 'pending').length,
      volume: Math.round(db.transfers.reduce((a, t) => a + (Number(t.amount) || 0), 0) * 100) / 100,
      today: allToday.length,
      todayVolume: Math.round(allToday.reduce((a, t) => a + (Number(t.amount) || 0), 0) * 100) / 100
    });
    return;
  }

  /* 某一笔的详情：完整流水 + 发起设备 IP + 相关审计 */
  if (sub === 'payments' && parts.length === 3 && method === 'GET') {
    if (!can(admin, 'payments')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const t = db.transfers.find((x) => x.id === parts[2]);
    if (!t) return fail(res, 404, '这笔转账不存在');
    audit(req, admin, '查看交易详情', t.id, '金额 ' + t.amount);
    const payer = findUser(t.fromId), payee = findUser(t.toId);
    const logins = db.security.logins.filter((l) => l.userId === t.fromId).slice(0, 5);
    const related = readAudit(400).filter((a) => String(a.target).indexOf(t.id) >= 0
      || String(a.detail).indexOf(t.id) >= 0
      || (a.action.indexOf('转账') >= 0 && String(a.target).indexOf(t.id) >= 0));
    const chat = db.chats.find((c) => c.id === t.chatId);
    ok(res, {
      transfer: {
        id: t.id, amount: t.amount, note: t.note || '', status: t.status, method: t.method,
        createdAt: t.createdAt, expiresAt: t.expiresAt, receivedAt: t.receivedAt || '',
        refundedAt: t.refundedAt || '', chatId: t.chatId,
        chatTitle: chat ? chatSummary(chat, t.fromId).title : '',
        messageId: t.messageId || ''
      },
      payer: payer ? Object.assign(publicUser(payer), {
        phone: payer.phone || '', banned: !!payer.banned, balance: Number(payer.balance) || 0
      }) : null,
      payee: payee ? Object.assign(publicUser(payee), {
        phone: payee.phone || '', banned: !!payee.banned, balance: Number(payee.balance) || 0
      }) : null,
      logins,
      related
    });
    return;
  }

  /* 撤销/退回一笔待收款的转账（只有超级管理员） */
  if (sub === 'payments' && parts[3] === 'revoke' && method === 'POST') {
    if (!can(admin, 'payments.write')) return fail(res, 403, '你的角色没有查看这一项的权限');
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能撤销交易');
    const t = db.transfers.find((x) => x.id === parts[2]);
    if (!t) return fail(res, 404, '这笔转账不存在');
    if (t.status !== 'pending') return fail(res, 422, '只有「待收款」的交易能撤销');
    const body = await readBody(req);
    const payer = findUser(t.fromId);
    t.status = 'refunded';
    t.refundedAt = now();
    if (payer) {
      payer.balance = Math.round(((Number(payer.balance) || 0) + Number(t.amount)) * 100) / 100;
      saveUsers();
      sendTo(payer.id, { type: 'balance', balance: payer.balance });
    }
    saveTransfers();
    broadcastTransfer(t, 'refunded');
    audit(req, admin, '撤销交易', t.id, '退回 ¥' + t.amount + ' 给 ' + (payer ? payer.username : t.fromId)
      + '（' + str(body.reason, 60) + '）');
    ok(res, { revoked: true });
    return;
  }

  /* 冻结 / 解冻账号（只有超级管理员） */
  if (sub === 'payments' && parts[2] === 'freeze' && method === 'POST') {
    if (!can(admin, 'payments.write')) return fail(res, 403, '你的角色没有查看这一项的权限');
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能冻结账号');
    const body = await readBody(req);
    const u = findUser(str(body.userId, 40));
    if (!u) return fail(res, 404, '用户不存在');
    setUserBanned(u, body.frozen, str(body.reason, 100) || '支付风控冻结', admin.username);
    audit(req, admin, u.banned ? '冻结账号（支付风控）' : '解冻账号（支付风控）', u.username, u.banReason);
    ok(res, { banned: !!u.banned });
    return;
  }

  /* ---------------- 运维 ---------------- */
  if (sub === 'system' && method === 'GET') {
    if (!can(admin, 'system')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const mem = process.memoryUsage();
    let dbBytes = 0;
    try {
      fs.readdirSync(DATA_DIR).forEach((f) => {
        try { dbBytes += fs.statSync(path.join(DATA_DIR, f)).size; } catch (err) { /* 忽略 */ }
      });
    } catch (err) { /* 忽略 */ }
    ok(res, {
      system: {
        uptime: Math.round(process.uptime()),
        node: process.version,
        platform: process.platform,
        memoryMB: Math.round(mem.rss / 1024 / 1024),
        heapMB: Math.round(mem.heapUsed / 1024 / 1024),
        dataDir: DATA_DIR,
        dataMB: Math.round(dbBytes / 1024 / 1024 * 10) / 10,
        port: PORT,
        httpsPort: HTTPS_PORT
      },
      announce: db.branding && db.branding.announce ? db.branding.announce : ''
    });
    return;
  }

  if (sub === 'system' && parts[2] === 'announce' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有发公告权限');
    const body = await readBody(req);
    const text = str(body.text, 200);
    db.branding.announce = text;
    db.branding.updatedAt = now();
    saveBranding();
    db.users.forEach((u) => sendTo(u.id, { type: 'announce', text }));
    audit(req, admin, '发布系统公告', '', text);
    ok(res, { announce: text });
    return;
  }

  /* ---------------- 审计日志 ---------------- */
  if (sub === 'audit' && method === 'GET') {
    if (!can(admin, 'audit')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const r = readAuditQuery({
      limit: Number(query.get('limit')) || 200,
      from: Number(query.get('from')) || 0,
      to: Number(query.get('to')) || 0,
      q: query.get('q') || ''
    });
    ok(res, { audit: r.rows, total: r.total, days: r.days, truncated: r.truncated });
    return;
  }

  /* ---------------- 发现页（后台自由增删改）---------------- */
  if (sub === 'discover' && method === 'GET') {
    ok(res, {
      items: db.discover || [],
      defaults: DEFAULT_DISCOVER,
      actions: DISCOVER_ACTIONS
    });
    return;
  }

  if (sub === 'discover' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改发现页');
    const body = await readBody(req);
    const items = normalizeDiscover(body.items);
    db.discover = items;
    saveDiscover();
    audit(req, admin, 'discover.save', '发现页', items.length + ' 行');
    // 让在线的客户端知道配置变了（App 收到会重拉一份界面配置）
    sendToAll({ type: 'ui' });
   ok(res, { items: db.discover });
   return;
 }

  /* ---------------- 视频号（后台管控：内容 + 样式 + 开关）---------------- */
  if (sub === 'feed' && method === 'GET') {
    const f = readJson(path.join(DATA_DIR, 'feed.json'), {});
    ok(res, {
      items: f.items || [],
      posts: f.posts || [],
      style: Object.assign({}, FEED_STYLE_DEFAULT, f.style || {}),
      flags: Object.assign({}, FEED_FLAGS_DEFAULT, f.flags || {}),
      defaults: { style: FEED_STYLE_DEFAULT, flags: FEED_FLAGS_DEFAULT }
    });
    return;
  }

  if (sub === 'feed' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改视频号');
    const body = await readBody(req);
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    if (Array.isArray(body.items)) {
      const oldItems = Array.isArray(f.items) ? f.items : [];
      f.items = body.items.map((x, i) => {
        const id = str(x.id, 40) || ('v' + (i + 1));
        const prev = oldItems.find((y) => y && y.id === id);
        return {
          id,
          video: str(x.video, 300),
          cover: str(x.cover, 300),
          desc: str(x.desc, 200),
          music: str(x.music, 80),
          tag: str(x.tag, 20),
          author: str(x.author, 40),
          /* 内置条目的作者头像：不带上它，客户端只能显示名字首字 */
          authorAvatar: str(x.authorAvatar, 300),
          /* 短剧用：集数标签 / 总集数 / 剧集 id / 剧名（客户端左上角显示集数 + 选集） */
          ep: str(x.ep, 20),
          epTotal: Number(x.epTotal) || 0,
          series: str(x.series, 60),
          seriesName: str(x.seriesName, 60),
          baseLikes: Number(x.baseLikes) || 0,
          /* 发布时间：新条目必须带上，否则会被当成"24 小时前"的老视频，推荐排不上去 */
          createdAt: str(x.createdAt, 40) || (prev && prev.createdAt) || now()
        };
      });
    }
    if (body.style && typeof body.style === 'object') f.style = normalizeFeedStyle(body.style);
    if (body.flags && typeof body.flags === 'object') f.flags = normalizeFeedFlags(body.flags);
    writeJson(file, f);
    audit(req, admin, 'feed.save', '视频号', (f.items || []).length + ' 条内置 / ' + (f.posts || []).length + ' 条用户作品');
    sendToAll({ type: 'ui' });
    ok(res, { items: f.items || [], style: f.style, flags: f.flags });
    return;
  }

  /* 后台删掉某个用户发的视频 */
  if (sub === 'feed' && parts[2] === 'posts' && method === 'DELETE') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能删作品');
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const id = str(parts[3], 40);
    const before = (f.posts || []).length;
    f.posts = (f.posts || []).filter((x) => x.id !== id);
    writeJson(file, f);
    audit(req, admin, 'feed.deletePost', '视频号作品', id);
    ok(res, { removed: before - f.posts.length });
    return;
  }

  /* ---------------- 我页（后台自由增删改）---------------- */
  /* ---------------- 界面文字（ui.json：字号 / 颜色，App 和网页版都读它） ---------------- */
  if (sub === 'uiconfig' && method === 'GET') {
    ok(res, { ui: readJson(path.join(DATA_DIR, 'ui.json'), {}) });
    return;
  }

  /* ---------------- IM 模块（聊天开关 / 各类消息 / 撤回时限 / 群人数…） ---------------- */
  /* ---------------- 短信通道（登录验证码 / 找回密码） ---------------- */
  if (sub === 'sms' && method === 'GET') {
    const c = readSmsCfg();
    ok(res, {
      sms: {
        enabled: c.enabled, provider: c.provider, signName: c.signName, templateCode: c.templateCode,
        accessKeyId: c.accessKeyId,
        hasSecret: !!c.accessKeySecret,          // 密钥不回传，只告诉有没有填过
        twilioSid: c.twilioSid, twilioFrom: c.twilioFrom, hasTwilioToken: !!c.twilioToken,
        customUrl: c.customUrl, customHeader: c.customHeader, note: c.note
      },
      ready: smsReady(c),
      defaults: { provider: DEFAULT_SMS.provider, note: DEFAULT_SMS.note }
    });
    return;
  }

  if (sub === 'sms' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能改短信设置');
    const body = await readBody(req);
    const src = body.sms && typeof body.sms === 'object' ? body.sms : (body || {});
    const cur = readSmsCfg();
    const next = Object.assign({}, cur);
    ['enabled', 'provider', 'signName', 'templateCode', 'accessKeyId', 'twilioSid', 'twilioFrom', 'customUrl', 'customHeader']
      .forEach((k) => { if (src[k] !== undefined) next[k] = typeof DEFAULT_SMS[k] === 'boolean' ? !!src[k] : String(src[k] || '').slice(0, 400); });
    ['accessKeySecret', 'twilioToken'].forEach((k) => {
      if (src[k] !== undefined && String(src[k] || '').trim() !== '') next[k] = String(src[k]).trim().slice(0, 200);
    });
    saveSmsCfg(next);
    audit(req, admin, 'sms.save', '短信设置', next.provider + (next.enabled ? ' 已开启' : ' 已关闭'));
    ok(res, { sms: { enabled: next.enabled, provider: next.provider }, ready: smsReady(next) });
    return;
  }

  /* 测试发一条（填完 Key 先试一发，不用等真用户登录） */
  if (sub === 'sms' && parts[2] === 'test' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能发测试短信');
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    if (!/^1[3-9]\d{9}$/.test(phone)) return fail(res, 422, '手机号格式不对');
    const code = String(Math.floor(100000 + Math.random() * 900000));
    const r = await sendSmsCode(phone, code, readSmsCfg());
    audit(req, admin, 'sms.test', phone, r.ok ? ('验证码 ' + code + ' 已发出') : ('失败：' + r.error));
    if (!r.ok) return fail(res, 502, r.error);
    ok(res, { sent: true, phone });
    return;
  }

  if (sub === 'im' && method === 'GET') {
    ok(res, { im: readIm(), defaults: DEFAULT_IM });
    return;
  }

  /* ---------------- 经营账户查账（后台）：每个人的收款、提现、开票一眼看全 ---------------- */
  if (sub === 'biz' && method === 'GET') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查账权限');
    const all = readBizAll();
    const day0 = localDayStart();
    const monthPrefix = new Date().toISOString().slice(0, 7);
    const sum = (list) => Math.round(list.reduce((a, r) => a + (Number(r.amount) || 0), 0) * 100) / 100;
    const rows = Object.keys(all.accounts).map((uid) => {
      const acc = all.accounts[uid] || {};
      const records = Array.isArray(acc.records) ? acc.records : [];
      const collects = records.filter((r) => r.kind === 'collect');
      const u = findUser(uid) || {};
      return {
        userId: uid,
        username: u.username || '',
        nickname: u.nickname || '',
        avatar: u.avatar || '',
        enabled: !!acc.enabled,
        arrival: (acc.settings && acc.settings.arrival) || 'balance',
        shopName: (acc.settings && acc.settings.shopName) || '',
        balance: Number(acc.balance) || 0,
        collectAll: sum(collects),
        collectToday: sum(collects.filter((r) => new Date(r.createdAt).getTime() >= day0)),
        collectMonth: sum(collects.filter((r) => String(r.createdAt).slice(0, 7) === monthPrefix)),
        withdraw: sum(records.filter((r) => r.kind === 'withdraw')),
        invoiceDone: sum((acc.invoices || []).filter((i) => i.status === 'done')),
        pendingInvoices: (acc.invoices || []).filter((i) => (i.status || 'pending') === 'pending'),
        invoice: acc.invoice || {},
        lastAt: records.length ? records[0].createdAt : '',
        count: collects.length
      };
    }).filter((r) => r.count || r.balance || r.pendingInvoices.length)
      .sort((a, b) => String(b.lastAt).localeCompare(String(a.lastAt)));
    /* 明细：最近 200 条（可按用户过滤） */
    const wantUser = str(query.get('user'), 40);
    const detail = [];
    Object.keys(all.accounts).forEach((uid) => {
      if (wantUser && uid !== wantUser) return;
      const u = findUser(uid) || {};
      (all.accounts[uid].records || []).forEach((r) => {
        detail.push(Object.assign({}, r, {
          userId: uid, nickname: u.nickname || '', username: u.username || ''
        }));
      });
    });
    detail.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    ok(res, {
      accounts: rows,
      records: detail.slice(0, 200),
      totals: {
        collect: sum(rows.map((r) => ({ amount: r.collectAll }))),
        today: sum(rows.map((r) => ({ amount: r.collectToday }))),
        month: sum(rows.map((r) => ({ amount: r.collectMonth }))),
        withdraw: sum(rows.map((r) => ({ amount: r.withdraw }))),
        balance: sum(rows.map((r) => ({ amount: r.balance }))),
        accounts: rows.length,
        pendingInvoices: rows.reduce((a, r) => a + r.pendingInvoices.length, 0)
      }
    });
    return;
  }

  /* 后台处理开票申请：开好票标记「已开」/「驳回」 */
  if (sub === 'biz' && parts[2] === 'invoice' && method === 'POST') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查账权限');
    const body = await readBody(req);
    const userId = str(body.userId, 40);
    const id = str(body.id, 40);
    const action = str(body.action, 12) || 'done';
    const acc = bizOf(userId, false);
    const inv = (acc.invoices || []).find((i) => i.id === id);
    if (!inv) return fail(res, 404, '这张开票申请不在了');
    inv.status = action === 'reject' ? 'rejected' : 'done';
    inv.handledAt = now();
    inv.adminNote = str(body.note, 60);
    saveBizAll();
    audit(req, admin, 'biz.invoice.' + inv.status, userId, '¥' + inv.amount + ' ' + inv.title);
    ok(res, { invoice: inv });
    return;
  }

  /* ---------------- 关键词自动回复（微信后台「自动回复」那套） ---------------- */
  if (sub === 'autoreply' && method === 'GET') {
    if (!can(admin, 'support')) return fail(res, 403, '你的角色没有自动回复权限');
    ok(res, { autoreply: readAutoReply(), defaults: DEFAULT_AUTOREPLY });
    return;
  }
  if (sub === 'autoreply' && method === 'POST') {
    if (!can(admin, 'support.write')) return fail(res, 403, '你的角色不能改自动回复');
    const body = await readBody(req);
    const src = body.autoreply && typeof body.autoreply === 'object' ? body.autoreply : (body || {});
    const next = Object.assign({}, readAutoReply());
    if (src.enabled !== undefined) next.enabled = src.enabled ? 1 : 0;
    if (src.scope !== undefined) next.scope = src.scope === 'all' ? 'all' : 'kefu';
    if (src.fallback !== undefined) next.fallback = str(src.fallback, 500);
    if (Array.isArray(src.rules)) {
      next.rules = src.rules.slice(0, 200).map((r, i) => ({
        id: str(r && r.id, 30) || ('ar' + Date.now().toString().slice(-5) + i),
        keyword: str(r && r.keyword, 60),
        match: (r && r.match === 'exact') ? 'exact' : 'contains',
        reply: str(r && r.reply, 2000),
        enabled: !(r && r.enabled === false)
      })).filter((r) => r.keyword && r.reply);
    }
    const saved = saveAutoReply(next);
    audit(req, admin, 'autoreply.save', '关键词自动回复', saved.rules.length + ' 条规则，' + (saved.enabled ? '已开启' : '未开启'));
    ok(res, { autoreply: saved });
    return;
  }

  /* ---------------- 红包封面：封面库（名字 / 封面图 / 缩略图 / 主题色 / 启用 / 默认） ---------------- */
  if (sub === 'rpcovers' && method === 'GET') {
    if (!can(admin, 'icons')) return fail(res, 403, '只有超级管理员能看红包封面');
    ok(res, { covers: readRpCovers(), defaults: DEFAULT_RP_COVERS });
    return;
  }

  if (sub === 'rpcovers' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改红包封面');
    const body = await readBody(req);
    const src = body.covers && typeof body.covers === 'object' ? body.covers : (body || {});
    const next = {};
    if (Array.isArray(src.covers)) {
      next.covers = src.covers.slice(0, 40).map((c, i) => ({
        id: str(c && c.id, 30) || ('cv' + Date.now().toString().slice(-5) + i),
        name: str(c && c.name, 20) || ('封面 ' + (i + 1)),
        image: str(c && c.image, 300),
        thumb: str(c && (c.thumb || c.image), 300),
        color: /^#[0-9a-fA-F]{6}$/.test(String((c && c.color) || '')) ? String(c.color) : '#B3241C',
        enabled: !(c && c.enabled === false)
      })).filter((c) => c.image);
      if (!next.covers.length) next.covers = DEFAULT_RP_COVERS.covers;
    }
    if (src.defaultId !== undefined) next.defaultId = str(src.defaultId, 30);
    const saved = saveRpCovers(next);
    audit(req, admin, 'rpcovers.save', '红包封面', saved.covers.length + ' 张，默认 ' + saved.defaultId);
    ok(res, { covers: saved });
    return;
  }

  /* ---------------- 客服中心：常见问题 + 在线客服 + 工单 ---------------- */
  if (sub === 'support' && method === 'GET') {
    if (!can(admin, 'support')) return fail(res, 403, '你的角色没有客服中心的权限');
    const cfg = readSupport();
    const online = onlineUserIds();
    const tickets = readSupportTickets(200).map((t) => {
      const u = findUser(t.userId) || {};
      return Object.assign({}, t, {
        nickname: u.nickname || t.nickname || '',
        username: u.username || t.username || '',
        avatar: u.avatar || '',
        online: online.indexOf(t.userId) >= 0
      });
    });
    ok(res, {
      support: cfg,
      defaults: DEFAULT_SUPPORT,
      tickets,
      pending: tickets.filter((t) => (t.status || 'pending') === 'pending').length,
      agent: (function () { const a = supportAgent(); return { id: a.id, nickname: a.nickname, avatar: a.avatar || '' }; })()
    });
    return;
  }

  if (sub === 'support' && parts.length === 2 && method === 'POST') {
    if (!can(admin, 'support.write')) return fail(res, 403, '你的角色不能改客服中心');
    const body = await readBody(req);
    const src = body.support && typeof body.support === 'object' ? body.support : (body || {});
    const next = Object.assign({}, readSupport());
    ['title', 'searchHint', 'phone', 'email', 'workTime', 'greet', 'ticketHint']
      .forEach((k) => { if (src[k] !== undefined) next[k] = String(src[k] || '').slice(0, 300); });
    ['human', 'autoReply', 'ticketOn'].forEach((k) => { if (src[k] !== undefined) next[k] = src[k] ? 1 : 0; });
    if (Array.isArray(src.categories)) {
      next.categories = src.categories.slice(0, 30).map((c, i) => ({
        id: str(c && c.id, 20) || ('sp' + (i + 1)),
        title: str(c && c.title, 30) || '未命名',
        icon: str(c && c.icon, 8) || '',
        items: (c && Array.isArray(c.items) ? c.items : []).slice(0, 80).map((it) => ({
          q: str(it && it.q, 120),
          a: str(it && it.a, 3000)
        })).filter((it) => it.q)
      })).filter((c) => c.items.length);
      if (!next.categories.length) next.categories = DEFAULT_SUPPORT.categories;
    }
    const saved = saveSupport(next);
    audit(req, admin, 'support.save', '客服中心', saved.categories.length + ' 个分类');
    ok(res, { support: saved });
    return;
  }

  /* 工单：回复（同时发进用户和「在线客服」的会话）/ 结单 / 重新打开 */
  if (sub === 'support' && parts[2] === 'ticket' && method === 'POST') {
    if (!can(admin, 'support.write')) return fail(res, 403, '你的角色不能处理工单');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const action = str(body.action, 12) || 'reply';
    const t = readSupportTickets(500).find((x) => x.id === id);
    if (!t) return fail(res, 404, '这张工单不在了');
    const u = findUser(t.userId);
    const reply = str(body.reply, 1000);
    let chatId = '';
    if (action === 'reply' && reply) {
      if (!u) return fail(res, 404, '提工单的用户不在了');
      const chat = supportChatFor(u.id);
      chatId = chat.id;
      const r = deliverMessage(supportAgent(), chat.id, 'text', reply, null);
      if (r && r.error) return fail(res, 422, r.error);
    }
    const patch = {};
    if (reply) patch.reply = reply;
    if (action === 'reply') { patch.status = 'replied'; patch.repliedAt = now(); }
    if (action === 'close') { patch.status = 'done'; patch.doneAt = now(); }
    if (action === 'reopen') { patch.status = 'pending'; patch.doneAt = ''; }
    const savedTicket = updateSupportTicket(id, patch);
    audit(req, admin, 'support.ticket.' + action, t.userId, (reply || '').slice(0, 80));
    ok(res, { ticket: savedTicket, chatId });
    return;
  }


  /* ---------------- 零钱：充值 / 提现（规则 + 记录 + 审核） ---------------- */
  if (sub === 'wallet' && method === 'GET') {
    const rules = readWalletRules();
    const ops = readWalletOps().ops.slice(0, 300).map((o) => {
      const u = findUser(o.userId) || {};
      return Object.assign({}, o, { username: u.username || '', nickname: u.nickname || '' });
    });
    ok(res, { rules, ops, defaults: DEFAULT_WALLET_RULES });
    return;
  }

  if (sub === 'wallet' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能改零钱规则');
    const body = await readBody(req);
    const src = body.rules && typeof body.rules === 'object' ? body.rules : (body || {});
    const next = Object.assign({}, readWalletRules());
    ['allowRecharge', 'withdrawReview'].forEach((k) => { if (src[k] !== undefined) next[k] = src[k] ? 1 : 0; });
    ['rechargeMax', 'withdrawMin', 'withdrawMax', 'feeMin'].forEach((k) => {
      if (src[k] !== undefined) { const v = Number(src[k]); if (isFinite(v) && v >= 0) next[k] = v; }
    });
    if (src.feeRate !== undefined) {
      const v = Number(src.feeRate);
      if (isFinite(v) && v >= 0 && v <= 0.1) next.feeRate = v;
    }
    if (src.note !== undefined) next.note = String(src.note || '').slice(0, 200);
    const saved = saveWalletRules(next);
    /* 兼容老开关：security.json 里的 allowRecharge 也一起跟着开/关 */
    try {
      const sp = path.join(DATA_DIR, 'security.json');
      const sec = readJson(sp, {});
      sec.allowRecharge = saved.allowRecharge ? 1 : 0;
      writeJson(sp, sec);
      secCache = { at: 0, cfg: null };
    } catch (e) { }
    audit(req, admin, 'wallet.rules', '零钱规则', JSON.stringify(saved).slice(0, 160));
    ok(res, { rules: saved });
    return;
  }

  /* 提现审核：标记「已到账」或者「退回零钱」 */
  if (sub === 'wallet' && parts[2] === 'op' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能处理提现');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const action = str(body.action, 12) || 'done';
    const d = readWalletOps();
    const op = d.ops.find((o) => o.id === id);
    if (!op) return fail(res, 404, '这条记录不在了');
    if (op.kind !== 'withdraw') return fail(res, 422, '只有提现需要处理');
    const u = findUser(op.userId);
    if (action === 'done') {
      op.status = 'done';
      op.doneAt = now();
      saveWalletOps();
      audit(req, admin, 'wallet.withdraw.done', op.userId, '¥' + op.amount);
      ok(res, { op });
      return;
    }
    if (action === 'fail') {
      /* 退回：本金 + 手续费一起还给用户 */
      if (u) {
        u.balance = Math.round(((Number(u.balance) || 0) + Number(op.amount || 0) + Number(op.fee || 0)) * 100) / 100;
        saveUsers();
        sendTo(u.id, { type: 'balance', balance: u.balance });
      }
      op.status = 'failed';
      op.doneAt = now();
      saveWalletOps();
      audit(req, admin, 'wallet.withdraw.fail', op.userId, '退回 ¥' + op.amount);
      ok(res, { op, refunded: true });
      return;
    }
    return fail(res, 422, '不认识的操作');
  }

  /* ---------------- 推送通知（APNs）：密钥配置 + 自检 + 试推一条 ---------------- */
  if (sub === 'push' && method === 'GET') {
    const p = readPush();
    const c = p.config;
    let devices = 0;
    Object.keys(p.tokens).forEach((uid) => { devices += (p.tokens[uid] || []).length; });
    let log = [];
    try {
      log = fs.readFileSync(path.join(DATA_DIR, 'push-log.jsonl'), 'utf8').trim().split('\n')
        .slice(-20).map((l) => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean).reverse();
    } catch (e) { log = []; }
    ok(res, {
      push: {
        enabled: !!c.enabled, bundleId: c.bundleId, teamId: c.teamId, keyId: c.keyId,
        keyPath: c.keyPath, sandbox: !!c.sandbox,
        hasKeyText: !!c.keyText,
        onMessage: c.onMessage !== false, onFriend: c.onFriend !== false, onCall: c.onCall !== false
      },
      ready: pushReady(),
      devices, users: Object.keys(p.tokens).length,
      settings: p.settings || {},
      log
    });
    return;
  }

  /* 注意：这一条只管 /api/ops/push 本身；/api/ops/push/test 要排在后面单独处理 */
  if (sub === 'push' && method === 'POST' && parts.length === 2) {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能改推送设置');
    const body = await readBody(req);
    const src = body.push && typeof body.push === 'object' ? body.push : (body || {});
    const p = readPush();
    const c = p.config;
    const STR = ['bundleId', 'teamId', 'keyId', 'keyPath'];
    STR.forEach((k) => { if (src[k] !== undefined) c[k] = String(src[k] || '').trim().slice(0, 200); });
    ['enabled', 'sandbox', 'onMessage', 'onFriend', 'onCall']
      .forEach((k) => { if (src[k] !== undefined) c[k] = !!src[k]; });
    if (src.keyText !== undefined && String(src.keyText).trim() !== '') c.keyText = String(src.keyText).trim().slice(0, 4000);
    savePush();
    jwtCache = { at: 0, token: '', key: '' };        // 换了密钥，JWT 必须重新签
    pushCache = null;
    audit(req, admin, 'push.save', '推送设置', c.enabled ? '已开启' : '已关闭');
    ok(res, { push: { enabled: c.enabled, bundleId: c.bundleId }, ready: pushReady() });
    return;
  }

  /* 试推一条：给自己（管理员账号）或者指定用户名推 */
  if (sub === 'push' && parts[2] === 'test' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能试推');
    const body = await readBody(req);
    let target = str(body.username, 24) ? findUserByName(body.username) : null;
    if (!target) {
      /* 没填用户名就挑一个「最近登记过推送」的手机 */
      const keys = Object.keys(readPush().tokens);
      if (keys.length) target = findUser(keys[keys.length - 1]);
    }
    if (!target) return fail(res, 404, '还没有手机登记过推送（先用 App 登录一次，或者填一个用户名）');
    const r = await pushToUser(target.id, {
      kind: 'message', title: 'Luchat 测试推送', body: '看到这条就说明推送通道通了 🎉', chatId: 'test'
    });
    audit(req, admin, 'push.test', target.username || target.id, JSON.stringify(r));
    if (!r.sent) return fail(res, 502, '没发出去：' + r.reason + (pushReady() ? '' : '（密钥还没配好）'));
    ok(res, { sent: true, to: target.username || target.id });
    return;
  }

  if (sub === 'im' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改 IM 模块');
    const body = await readBody(req);
    const patch = body.im && typeof body.im === 'object' ? body.im : (body || {});
    const saved = saveIm(patch);
    audit(req, admin, 'im.save', 'IM 模块', Object.keys(patch).join(','));
    sendToAll({ type: 'ui' });                    // 在线客户端立刻生效
    ok(res, { im: saved });
    return;
  }

  if (sub === 'uiconfig' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改界面文字');
    const body = await readBody(req);
    const patch = body.ui && typeof body.ui === 'object' ? body.ui : {};
    const cur = readJson(path.join(DATA_DIR, 'ui.json'), {});
    const touched = [];
    Object.keys(patch).forEach((k) => {
      if (k.charAt(0) === '_') return;                      // 不动注释
      const v = patch[k];
      if (v === null || v === '') { delete cur[k]; }
      else if (typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') { cur[k] = v; touched.push(k); }
    });
    writeJson(path.join(DATA_DIR, 'ui.json'), cur);
    audit(req, admin, 'uiconfig.save', '界面文字', touched.join(','));
    sendToAll({ type: 'ui' });                            // 在线客户端立刻重拉一份
    ok(res, { ui: cur });
    return;
  }

  if (sub === 'mepage' && method === 'GET') {
    ok(res, { items: db.mePage || [], defaults: DEFAULT_ME_PAGE, actions: ME_ACTIONS });
    return;
  }

  if (sub === 'mepage' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改我页');
    const body = await readBody(req);
    const items = normalizeMePage(body.items);
    db.mePage = items;
    saveMePage();
    audit(req, admin, 'mepage.save', '我页', items.length + ' 行');
    sendToAll({ type: 'ui' });
    ok(res, { items: db.mePage });
    return;
  }

  /* ---------------- 服务页（绿卡 + 分类 + 格子，全都能改）---------------- */
  if (sub === 'service' && method === 'GET') {
    ok(res, {
      service: db.service || normalizeService(null),
      defaults: DEFAULT_SERVICE,
      actions: SERVICE_ACTIONS
    });
    return;
  }

  if (sub === 'service' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改服务页');
    const body = await readBody(req);
    const cfg = normalizeService(body.service || body);
    db.service = cfg;
    saveService();
    const cells = (cfg.groups || []).reduce((n, g) => n + (g.items || []).length, 0);
    audit(req, admin, 'service.save', '服务页', (cfg.groups || []).length + ' 组 / ' + cells + ' 格');
    sendToAll({ type: 'ui' });
    ok(res, { service: db.service });
    return;
  }

  /* ---------------- 钱包页（两张白卡 + 底部链接，全都能改）---------------- */
  if (sub === 'wallet' && method === 'GET') {
    ok(res, {
      wallet: db.wallet || normalizeWallet(null),
      defaults: DEFAULT_WALLET,
      actions: WALLET_ACTIONS
    });
    return;
  }

  if (sub === 'wallet' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改钱包页');
    const body = await readBody(req);
    const cfg = normalizeWallet(body.wallet || body);
    db.wallet = cfg;
    saveWallet();
    const cells = (cfg.groups || []).reduce((n, g) => n + (g.items || []).length, 0);
    audit(req, admin, 'wallet.save', '钱包页',
      (cfg.groups || []).length + ' 组 / ' + cells + ' 行 / 底部 ' + (cfg.footer || []).length + ' 个链接');
    sendToAll({ type: 'ui' });
    ok(res, { wallet: db.wallet });
    return;
  }

  /* ---------------- 零钱页（文案 / 按钮 / 链接 / 样式）---------------- */
  if (sub === 'balance-page' && method === 'GET') {
    ok(res, {
      page: db.balancePage || normalizeBalancePage(null),
      defaults: DEFAULT_BALANCE_PAGE,
      actions: BALANCE_ACTIONS
    });
    return;
  }

  if (sub === 'balance-page' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改零钱页');
    const body = await readBody(req);
    const cfg = normalizeBalancePage(body.page || body);
    db.balancePage = cfg;
    saveBalancePage();
    audit(req, admin, 'balance.save', '零钱页', cfg.title + ' / ' + (cfg.links || []).length + ' 个链接');
    sendToAll({ type: 'ui' });
    ok(res, { page: db.balancePage });
    return;
  }

  /* ---------------- 账单页样式（图标大小 / 字号 / 行高）---------------- */
  if (sub === 'bills-page' && method === 'GET') {
    ok(res, {
      page: db.billsPage || normalizeBillsPage(null),
      defaults: DEFAULT_BILLS_PAGE
    });
    return;
  }

  if (sub === 'bills-page' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改账单页');
    const body = await readBody(req);
    const cfg = normalizeBillsPage(body.page || body);
    db.billsPage = cfg;
    saveBillsPage();
    audit(req, admin, 'bills.save', '账单页样式', JSON.stringify(cfg.style));
    sendToAll({ type: 'ui' });
    ok(res, { page: db.billsPage });
    return;
  }

  /* ---------------- UI 图标（换成自定义的）---------------- */
  if (sub === 'icons' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] });
    ok(res, {
      defaults: defs.items || [],
      overrides: readJson(path.join(DATA_DIR, ICONS_FILE), {})
    });
    return;
  }

  if (sub === 'icons' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改 UI 图标');
    const body = await readBody(req);
    const key = str(body.key, 40);
    if (!key) return fail(res, 422, '缺少图标标识');
    const value = String(body.value == null ? '' : body.value).slice(0, 300000).trim();
    const all = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const old = all[key] || '';
    if (value) all[key] = value; else delete all[key];
    writeJson(path.join(DATA_DIR, ICONS_FILE), all);
    callTrace('换图标 ' + key + ' → ' + (value ? value.slice(0, 70) : '（还原内置）'));
    audit(req, admin, value ? '更换 UI 图标' : '恢复默认图标', str(body.name, 40) || key,
      value ? (value.indexOf('<svg') === 0 ? '自定义 SVG' : value.slice(0, 60)) : '恢复内置图标');
    /* 立刻告诉所有在线客户端「界面配置变了」：App 收到就重新拉一次，
       不用让用户划掉重开才看到新图标。 */
    sendToAll({ type: 'ui' });
    ok(res, { saved: true, before: old, now: value });
    return;
  }

  /* 后台里上传图标文件（存到同一个 uploads 目录） */
  if (sub === 'upload' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能上传图标');
    const body = await readBody(req);
    callTrace('图标上传：' + str(body.filename, 60) + ' 大小=' + String(body.dataUrl || '').length
      + ' 类型=' + String(body.dataUrl || '').slice(0, 24));
    const saved = saveUploadedFile(body);
    if (saved.error) { callTrace('图标上传失败：' + saved.error); return fail(res, saved.status, saved.error); }
    callTrace('图标上传成功：' + saved.url);
    audit(req, admin, '上传图标文件', saved.url, saved.name || '');
    ok(res, saved);
    return;
  }

  /* ---------------- 后台账号管理 ---------------- */
  if (sub === 'admins' && method === 'GET') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能看账号列表');
    ok(res, {
      admins: opsStore.admins.map((a) => ({
        id: a.id, username: a.username, name: a.name,
        role: a.role, roleName: OPS_ROLE_NAMES[a.role] || a.role,
        disabled: !!a.disabled, createdAt: a.createdAt,
        lastLoginAt: a.lastLoginAt || '', lastIp: a.lastIp || ''
      })),
      roles: Object.keys(OPS_ROLES).map((r) => ({ key: r, name: OPS_ROLE_NAMES[r] }))
    });
    return;
  }

  if (sub === 'admins' && method === 'POST') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能加账号');
    const body = await readBody(req);
    const username = str(body.username, 24).toLowerCase();
    const password = String(body.password || '').trim();
    if (!/^[a-z0-9_]{3,24}$/.test(username)) return fail(res, 422, '账号要 3-24 位字母/数字/下划线');
    if (password.length < 6) return fail(res, 422, '密码至少 6 位');
    if (opsStore.admins.some((a) => a.username === username)) return fail(res, 409, '这个账号已经存在');
    const role = OPS_ROLES[body.role] ? body.role : 'support';
    const salt = crypto.randomBytes(16).toString('hex');
    const item = {
      id: uid('ops'), username, name: str(body.name, 20) || username, role,
      salt, hash: hashPassword(password, salt), createdAt: now(), disabled: false
    };
    opsStore.admins.push(item);
    saveOpsAdmins();
    audit(req, admin, '新增后台账号', username, OPS_ROLE_NAMES[role]);
    ok(res, { admin: opsMe(item) });
    return;
  }

  /* 改自己的后台密码（要提供原密码）；强密码要求至少 10 位、含字母和数字 */
  if (sub === 'password' && method === 'POST') {
    const body = await readBody(req);
    const cur = String(body.current || '');
    const next = String(body.next || '').trim();
    if (!verifySecretRecord({ salt: admin.salt, hash: admin.hash }, cur)) {
      audit(req, admin, '改密码失败', admin.username, '原密码不对');
      return fail(res, 401, '原密码不正确');
    }
    if (next.length < 10 || !/[A-Za-z]/.test(next) || !/[0-9]/.test(next)) {
      return fail(res, 422, '新密码至少 10 位，且要同时有字母和数字');
    }
    admin.salt = crypto.randomBytes(16).toString('hex');
    admin.hash = hashPassword(next, admin.salt);
    saveOpsAdmins();
    audit(req, admin, '修改后台密码', admin.username, '');
    ok(res, { changed: true });
    return;
  }

  if (sub === 'admins' && parts[3] === 'disable' && method === 'POST') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能改账号');
    const a = opsStore.admins.find((x) => x.id === parts[2]);
    if (!a) return fail(res, 404, '账号不存在');
    if (a.id === admin.id) return fail(res, 422, '不能停用自己');
    const body = await readBody(req);
    a.disabled = !!body.disabled;
    saveOpsAdmins();
    audit(req, admin, a.disabled ? '停用后台账号' : '启用后台账号', a.username, '');
    ok(res, { disabled: a.disabled });
    return;
  }

  /* 生成一次性免密登录链接（只有超管）：POST { username, minutes } → { url }
     用来「点开就进某个角色的后台」，不用输密码。5 分钟过期、用一次就废。 */
  if (sub === 'magic' && method === 'POST') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能生成免密链接');
    const body = await readBody(req);
    const target = opsStore.admins.find((a) => a.username === str(body.username, 24).toLowerCase() && !a.disabled);
    if (!target) return fail(res, 404, '没有这个后台账号');
    const token = newMagicToken(target.id, Number(body.minutes) || 5);
    const key = String(secCfg().adminKey || '');
    const host = str(body.host, 60).replace(/[^0-9A-Za-z\.\-:]/g, '') || String(req.headers.host || '').split(':')[0] || '192.168.2.7';
    audit(req, admin, '生成免密登录链接', target.username, '角色 ' + target.role);
    ok(res, {
      url: 'https://' + host + ':5443/manage.html?k=' + encodeURIComponent(key) + '&m=' + token,
      username: target.username, role: target.role, roleName: OPS_ROLE_NAMES[target.role] || target.role,
      expiresInSeconds: 300
    });
    return;
  }

  fail(res, 404, '接口不存在');
}

loadOps();
