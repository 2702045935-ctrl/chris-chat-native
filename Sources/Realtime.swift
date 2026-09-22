import Foundation
import SwiftUI

/// 服务器推送过来的一件事（收到新消息、转账、朋友圈、余额变动…）
struct PushEvent: Equatable {
    var type = ""
    var chatId = ""
    var fromId = ""
    var balance: Double? = nil
    var announce = ""
    var user: User? = nil
    /// 朋友圈有没有新的（服务器在 ready 里给；有就给「发现」挂红点）
    var momentUnread: Int? = nil
    /// 待处理的好友申请数量（服务器在 ready 里给；手机在后台没收到推送时靠它补上通讯录红点）
    var friendRequests: Int? = nil
    /// 转账推过来的东西（谁发的、什么状态、多少钱）：对方收款时付款方这边要变气泡 + 弹提示
    var transferFromId = ""
    var transferStatus = ""
    var transferAmount: Double? = nil
    var callId = ""
    var callAction = ""
    var callMedia = ""
    var callPeerId = ""
    var callPeerName = ""
    var callPeerAvatar = ""
    var callError = ""
    /// 通话里的 SDP（WebRTC 协商用，字符串形式）
    var callSDP: String? = nil
    /// 语音「服务器转发」的一帧音频（base64 的 16kHz 单声道 PCM）
    var callAudioData: String? = nil
    /// 通话里的 ICE 候选（整段 JSON 字符串）
    var callCandidate: String? = nil
    /// 挂断原因：hangup / rejected / cancel / timeout / offline / disconnected
    var callReason = ""
    /// 通话前问服务器「两端是不是同一个网络」的回答（同一个 → 直连，不同 → 强制走中继）
    var callSameNetwork = false
    /* ---- 直播专场（弹幕/点赞/在线人数） ---- */
    var roomId = ""
    var liveAction = ""
    var liveText = ""
    var liveFrom = ""
    var watching = 0
    var likes = 0
    /* 直播信令（真视频直播）：谁发的、什么类型、SDP/候选 */
    var liveFromId = ""
    var liveSigKind = ""
    var liveSDP = ""
    var liveCandidate = ""
    var tick = 0
}

/// 和服务器保持一条长连接（WebSocket）：别人一发消息，这边立刻就能收到，
/// 不用轮询。断了会自动重连。
@MainActor
final class Realtime: ObservableObject {
    static let shared = Realtime()

    @Published private(set) var event = PushEvent()
    @Published private(set) var connected = false

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var tick = 0
    /// 是否走明文通道、连着失败几次了（见 start() 里的说明）
    private var plainFallback = false
    private var failCount = 0
    /// 推送洪水的节流：消息一秒钟来几千条时，不能每条都去通知界面（会把手机刷死）。
    /// 这里最多每 0.25 秒往界面发一次，攒着的那条在稍后合并发出去。
    private var pending: PushEvent?
    private var publishTask: Task<Void, Never>?
    /// 心跳：每 20 秒给服务器发一个 ping，45 秒收不到任何东西就认为断了、重连
    private var heartbeat: Task<Void, Never>?
    private var lastRx = Date()

    func start() {
        /* 已经在连着就别再重建 —— 以前每调一次 start() 都会先 stop() 再新建，
           而「回到前台 / 刷新」这些地方会调它，于是长连接被反复掐断重建
           （日志里那个号 10 分钟断 300 多次就是这么来的，消息也就跟着卡）。 */
        if socket != nil, connected { return }
        stop()
        guard !API.shared.token.isEmpty else { return }
        /* 服务器是加密口（5443，https/wss）。
           以前这里写死了 ws://host:5443 —— 拿明文去握加密口，服务器直接 socket hang up，
           于是实时推送一直是断的：聊天页不刷新、通话记录/转账状态也收不到。
           现在默认 wss（和网页版一样），万一这个部署只开了明文口，再退回 ws://host:5180。 */
        let host = API.shared.server
        let plainHost = host.replacingOccurrences(of: ":5443", with: ":5180")
        let raw = plainFallback ? "ws://\(plainHost)" : "wss://\(host)"
        guard let url = URL(string: "\(raw)/?token=\(API.shared.token)") else { return }
        let task = API.shared.session.webSocketTask(with: url)
        socket = task
        task.resume()
        loop = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    var text = ""
                    switch message {
                    case .string(let t): text = t
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: break
                    }
                    if !text.isEmpty { self.handle(text) }
                    self.failCount = 0        // 收得到东西就说明这条通道是通的
                    self.lastRx = Date()
                } catch {
                    // 断了：3 秒后重连
                    self.connected = false
                    if Task.isCancelled { break }
                    /* 连着失败 3 次就换另一种协议再试：加密口握不上就退回明文 5180，
                       明文也连不上再换回加密，来回自愈，不会卡死在一种上。 */
                    self.failCount += 1
                    if self.failCount % 3 == 0 { self.plainFallback.toggle() }
                    /* 退避重连：1s → 2s → 3s → 最长 15s，避免疯狂重连刷屏、刷服务器 */
                    let wait = min(15.0, 1.0 + Double(self.failCount))
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if Task.isCancelled { break }
                    self.start()
                    return
                }
            }
        }
        connected = true
        lastRx = Date()
        /* 心跳 + 假死检测：服务器半分钟没动静就重连一次（比一直挂着收不到消息强） */
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if Task.isCancelled { return }
                guard let self = self else { return }
                if Date().timeIntervalSince(self.lastRx) > 45 {
                    self.connected = false
                    self.start()
                    return
                }
                self.sendJSON(["type": "ping"])
            }
        }
    }

    /// 往长连接里发一条 JSON（通话信令用）
    func sendJSON(_ obj: [String: Any]) {
        guard let socket = socket,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var ev = PushEvent()
        ev.type = (obj["type"] as? String) ?? ""
        ev.chatId = (obj["chatId"] as? String) ?? ""
        if let m = obj["message"] as? [String: Any] { ev.fromId = (m["senderId"] as? String) ?? "" }
        if let b = obj["balance"] as? Double { ev.balance = b }
        else if let b = obj["balance"] as? Int { ev.balance = Double(b) }
        // 资料变动（换封面 / 换头像 / 改昵称 / 改状态）：服务器推的是 profile
        if let u = obj["user"] as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: u),
           let decoded = try? JSONDecoder().decode(User.self, from: d) {
            ev.user = decoded
        }
        ev.announce = (obj["text"] as? String) ?? ""
        if let n = obj["momentUnread"] as? Int { ev.momentUnread = n }
        if let n = obj["friendRequests"] as? Int { ev.friendRequests = n }
        // 转账状态变化（对方收款 / 24 小时退回）
        if let t = obj["transfer"] as? [String: Any] {
            ev.transferFromId = (t["fromId"] as? String) ?? ""
            ev.transferStatus = (t["status"] as? String) ?? ""
            if let a = t["amount"] as? Double { ev.transferAmount = a }
            else if let a = t["amount"] as? Int { ev.transferAmount = Double(a) }
        }
        // 通话信令（invite/incoming/ringing/accept/reject/cancel/hangup）
        ev.callId = (obj["callId"] as? String) ?? ""
        ev.callAction = (obj["action"] as? String) ?? ""
        ev.callMedia = (obj["media"] as? String) ?? ""
        ev.callPeerId = (obj["peerId"] as? String) ?? ""
        ev.callPeerName = (obj["peerName"] as? String) ?? ""
        ev.callPeerAvatar = (obj["peerAvatar"] as? String) ?? ""
        ev.callError = (obj["error"] as? String) ?? ""
        ev.callReason = (obj["reason"] as? String) ?? ""
        if let same = obj["same"] as? Bool { ev.callSameNetwork = same }
        // 直播：进的哪个房间、什么动作（弹幕/点赞/人数）、谁说的、多少人
        ev.roomId = (obj["roomId"] as? String) ?? ""
        ev.liveAction = (obj["action"] as? String) ?? ""
        ev.liveText = (obj["text"] as? String) ?? ""
        ev.liveFrom = (obj["from"] as? String) ?? ""
        if let w = obj["watching"] as? Int { ev.watching = w }
        if let l = obj["likes"] as? Int { ev.likes = l }
        ev.liveFromId = (obj["from"] as? String) ?? ""
        ev.liveSigKind = (obj["sigKind"] as? String) ?? ""
        if let sdp = obj["sdp"] as? [String: Any] { ev.liveSDP = (sdp["sdp"] as? String) ?? "" }
        if let cand = obj["candidate"] as? [String: Any],
           let d2 = try? JSONSerialization.data(withJSONObject: cand),
           let t2 = String(data: d2, encoding: .utf8) { ev.liveCandidate = t2 }
        // WebRTC 协商内容：SDP 和 ICE 候选（网页版也是这么传的）
        if let sdp = obj["sdp"] as? [String: Any] { ev.callSDP = (sdp["sdp"] as? String) ?? "" }
        if let audio = obj["data"] as? String, !audio.isEmpty { ev.callAudioData = audio }
        if let cand = obj["candidate"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: cand),
           let text = String(data: data, encoding: .utf8) {
            ev.callCandidate = text
        }
        /* 推送洪水节流：每条都通知界面的话，几千条一来手机就卡死/崩。
           有任务在跑就先攒着，最多每 0.25 秒发一次（最后那条一定会发出去）。 */
        if publishTask == nil {
            tick += 1
            ev.tick = tick
            event = ev
            publishTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self = self, !Task.isCancelled else { return }
                self.publishTask = nil
                if let p = self.pending {
                    self.pending = nil
                    self.tick += 1
                    var merged = p
                    merged.tick = self.tick
                    self.event = merged
                }
            }
        } else {
            pending = ev
        }
    }
}

