/* 给视频号里的视频做 HLS 分片（3 秒一段）：
   目录 data/hls/<视频文件名>/index.m3u8 + seg_00000.ts，每个文件都加密落盘。
   已经是 H.264 的直接 -c copy 切段（很快），切不动再重编码。 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const D = '/opt/chris/app/data/';
const UP = D + 'uploads/';
const HLS = D + 'hls/';
const secret = fs.readFileSync(D + 'secret.key', 'utf8').trim();
const MAGIC = Buffer.from('LUC1');
const key = (n) => crypto.createHmac('sha256', secret).update('file:' + n).digest();
function openName(name) {
  const raw = fs.readFileSync(UP + name);
  if (raw.length < 20 || !raw.subarray(0, 4).equals(MAGIC)) return raw;
  const d = crypto.createDecipheriv('aes-256-ctr', key(name), raw.subarray(4, 20));
  return Buffer.concat([d.update(raw.subarray(20)), d.final()]);
}
function seal(file, name) {
  const plain = fs.readFileSync(file);
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-ctr', key(name), iv);
  fs.writeFileSync(file, Buffer.concat([MAGIC, iv, c.update(plain), c.final()]));
}
/* 原片的视频码率（bps）。读不出来返回 0，当「不确定」处理。 */
function srcBitrate(file) {
  try {
    const out = execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'stream=bit_rate', '-of', 'default=nw=1:nk=1', file]).toString().trim();
    const n = parseInt(out, 10);
    return isFinite(n) && n > 0 ? n : 0;
  } catch (e) { return 0; }
}
const TMP = '/tmp/hlsbuild/';
fs.mkdirSync(TMP, { recursive: true });
fs.mkdirSync(HLS, { recursive: true });
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const force = process.argv.indexOf('--force') >= 0;

/* 这次是按什么规格切的。每个 HLS 目录里存一份（封存）build.json。
   为什么必须有它：目录名是按视频文件名取的，只判「目录存在就跳过」的话，
   以前用 -c copy 切出来的高码率目录会一直活着 —— 后面任何一次自动切片
   都会把 feed 指回那个旧目录，用户那边视频又变成 3.6Mbps（线上真出过）。
   现在只有「目录存在 且 规格标记和当前 POLICY 一致」才跳过，否则重建。 */
const POLICY = 'v2-800k-1024';
function markerOk(dir) {
  try {
    const raw = fs.readFileSync(dir + 'build.json');
    let txt = raw;
    if (raw.length >= 20 && raw.subarray(0, 4).equals(MAGIC)) {
      const d = crypto.createDecipheriv('aes-256-ctr', key('build.json'), raw.subarray(4, 20));
      txt = Buffer.concat([d.update(raw.subarray(20)), d.final()]);
    }
    return JSON.parse(txt.toString('utf8')).policy === POLICY;
  } catch (e) { return false; }
}

const f = JSON.parse(fs.readFileSync(D + 'feed.json', 'utf8'));
const items = (f.posts || []).concat(f.items || []);
const jobs = [];
const seen = new Set();
items.forEach((it) => {
  const v = String(it.video || '');
  if (v.indexOf('/uploads/') !== 0) return;
  const name = path.basename(v);
  if (!/\.(mp4|mov|m4v)$/i.test(name)) return;
  if (seen.has(name)) return;
  seen.add(name);
  try { if (!fs.existsSync(UP + name)) return; } catch (e) { return; }
  jobs.push(name);
});
log('要分片的视频 ' + jobs.length + ' 个');

const made = new Map();   // 视频文件名 -> /hls/<id>/index.m3u8
let ok = 0, skip = 0, fail = 0;
for (const name of jobs) {
  const id = name.replace(/\.[A-Za-z0-9]+$/, '').replace(/[^A-Za-z0-9._-]/g, '');
  /* 重建时换一个目录名：分片是 immutable 缓存的，同名新内容会让已经缓存过旧分片的
     播放器拿到错的数据（花屏/卡住）。换名字之后新的播放列表指向全新的分片。 */
  const baseDir = HLS + id + '/';
  const canSkip = !force && fs.existsSync(baseDir + 'index.m3u8') && markerOk(baseDir);
  if (canSkip) { made.set(name, '/hls/' + id + '/index.m3u8'); skip += 1; continue; }
  /* 旧目录还在（说明是过时规格）→ 这次用带后缀的新目录名，别复用它的 URL */
  const id2 = fs.existsSync(baseDir) ? (id + '-t' + Date.now().toString(36)) : id;
  const dir = HLS + id2 + '/';
  const play = dir + 'index.m3u8';
  const src = TMP + name;
  try { fs.writeFileSync(src, openName(name)); } catch (e) { log('解密失败', name); fail += 1; continue; }
  fs.rmSync(dir, { recursive: true, force: true });
  fs.mkdirSync(dir, { recursive: true });
  /* 原片码率太高就先压再切：抖音/视频号下载来的原片动不动 3~4Mbps，
     直接 copy 切段虽然快，但手机 4G 或别人家 Wi-Fi 照样卡（一秒要 3Mbits）。
     压到 800k 之后同样时长只有原来约 1/4 的流量；已经够轻的原片才直接 copy。 */
  const br = srcBitrate(src);
  const heavy = br > 1200000;
  if (heavy) log('原片 ' + Math.round(br / 1000) + 'kbps 偏高 → 压到 800k 再切：' + name);
  /* 2 秒一段：首段更小 = 更快出画面（弱网下尤其明显） */
  const copyArgs = ['-y', '-loglevel', 'error', '-i', src, '-c', 'copy', '-bsf:a', 'aac_adtstoasc',
    '-hls_time', '2', '-hls_playlist_type', 'vod', '-hls_segment_type', 'mpegts',
    '-hls_flags', 'independent_segments', '-hls_segment_filename', dir + 'seg_%05d.ts', play];
  let runOk = !heavy;
  if (!heavy) {
    try { execFileSync('nice', ['-n', '15', 'ffmpeg'].concat(copyArgs), { stdio: ['ignore', 'ignore', 'ignore'] }); }
    catch (e) { runOk = false; }
  }
  if (!runOk || !fs.existsSync(play)) {
    /* 切不动（不是 H.264 / 时间戳异常）→ 重编码一遍再切 */
    if (!heavy) log('直接切段不行，改重编码：' + name);
    const encArgs = ['-y', '-loglevel', 'error', '-i', src,
      '-vf', "scale='if(gt(iw,ih),min(1024,iw),-2)':'if(gt(iw,ih),-2,min(1024,ih))'",
      '-c:v', 'libx264', '-preset', 'veryfast', '-threads', '1', '-b:v', '800k', '-maxrate', '1000k', '-bufsize', '1600k',
      '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '64k', '-ac', '1',
      '-hls_time', '2', '-hls_playlist_type', 'vod', '-hls_segment_type', 'mpegts',
      '-hls_flags', 'independent_segments', '-hls_segment_filename', dir + 'seg_%05d.ts', play];
    try { execFileSync('nice', ['-n', '15', 'ffmpeg'].concat(encArgs), { stdio: ['ignore', 'ignore', 'ignore'] }); }
    catch (e) { }
  }
  if (!fs.existsSync(play)) { log('分片失败：' + name); fail += 1; try { fs.unlinkSync(src); } catch (e) { } continue; }
  /* 所有产物加密落盘（播放列表也要，和别的上传一个待遇） */
  let segs = 0, bytes = 0;
  fs.readdirSync(dir).forEach((fn) => {
    const p = dir + fn;
    bytes += fs.statSync(p).size;
    if (/\.ts$/.test(fn)) segs += 1;
    seal(p, fn);
  });
  /* 记下这次的规格（封存）：下次判断「能不能跳过」就靠它，光看目录存在不行 */
  try {
    fs.writeFileSync(dir + 'build.json',
      Buffer.from(JSON.stringify({ policy: POLICY, srcBits: br, at: new Date().toISOString() })));
    seal(dir + 'build.json', 'build.json');
  } catch (e) { }
  /* 过时规格的旧目录留着只会再把 feed 指回去，重建成功后删掉（新目录名已经不同） */
  if (id2 !== id) { try { fs.rmSync(baseDir, { recursive: true, force: true }); } catch (e) { } }
  made.set(name, '/hls/' + id2 + '/index.m3u8');
  ok += 1;
  log('分片 ' + name + ' → ' + segs + ' 段 / ' + (bytes / 1048576).toFixed(1) + 'MB  http://…/hls/' + id2 + '/index.m3u8');
  try { fs.unlinkSync(src); } catch (e) { }
}

/* 回写 feed.json：只补 hls 字段，别把点赞评论盖掉 */
if (made.size) {
  const f2 = JSON.parse(fs.readFileSync(D + 'feed.json', 'utf8'));
  let n = 0;
  const apply = (arr) => (arr || []).forEach((it) => {
    const name = path.basename(String(it.video || ''));
    const h = made.get(name);
    if (h) { it.hls = h; n += 1; }
  });
  apply(f2.posts); apply(f2.items);
  fs.writeFileSync(D + 'feed.json.tmp', JSON.stringify(f2, null, 2));
  fs.renameSync(D + 'feed.json.tmp', D + 'feed.json');
  log('feed.json 更新 ' + n + ' 条');
}
log('完成：新切 ' + ok + ' 个，已存在 ' + skip + ' 个，失败 ' + fail + ' 个');
