import Foundation
import AVFoundation
import AudioToolbox
import UIKit
import Combine
import WebRTC

/* ============================================================
   真人语音/视频通话（App ↔ App、App ↔ 网页版都能通）

   信令和网页版走同一条 WebSocket、同一套格式：
     打电话:  {type:'call', action:'invite', callId, toUserId, media, sdp}
     对方响铃:{action:'ringing'} / 对方来电: {action:'incoming', callId, media, peerId, peerName, sdp}
     接听:    {action:'accept', callId, sdp}
     接通:    {action:'accepted'} / 对端 SDP: {action:'sdp', sdp}
     打洞:    {action:'ice', callId, candidate}   两端互发
     挂断:    {action:'hangup'|'cancel'|'reject'}

   媒体走 WebRTC 点对点（P2P），服务器只转发信令，不经过音频视频。
   同一局域网可以直接连（host 候选），跨网络需要 STUN/TURN —— 后台
   「🎨 登录页/语音通话」里配了 iceServers 就用配的，没配就用公共 STUN。
   ============================================================ */

@MainActor
final class CallCenter: NSObject, ObservableObject {
    static let shared = CallCenter()

    enum Phase: Equatable {
        case idle, outgoing, incoming, connecting, active
        var isBusy: Bool { self != .idle }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var peerName = ""
    @Published private(set) var peerAvatar = ""
    @Published private(set) var isVideo = false
    @Published private(set) var muted = false
    @Published private(set) var cameraOff = false
    /// 扬声器（扬声器已开 / 已关，参考图底下那排有这一项）
    @Published private(set) var speakerOn = false
    @Published private(set) var seconds = 0
    @Published private(set) var tip = ""
    /// 接通 / 挂断弹的对话框（用户要的就是这个形式：居中一个框 + 「确定」）。
    /// 颜色/圆角跟聊天页那行时间用的是同一套后台配置，所以长得和聊天的框框一样。
    struct Dialog: Equatable {
        var title = ""
        var detail = ""
        var okText = "确定"
        var auto: Double = 0          // > 0 表示过这么多秒自动关掉（接通那种不用手动点）
    }
    @Published var dialog: Dialog? = nil
    private var dialogTask: Task<Void, Never>?
    /// 打不通时那 8 秒的定时器（见 failLater）
    private var failTask: Task<Void, Never>?
    /// 连不上时的诊断记录（ICE 状态、候选数量…），通话结束时一起报给服务器
    private var diag: [String] = []
    /// 语音是否正在走「服务器转发」这条路
    private var serverAudioOn = false
    /// 媒体是不是**已经**交给腾讯云 TRTC 了（界面据此换成 TRTC 画面）。
    /// 注意：TRTC 自己进房成功还不算，要等「对端也在这个房间里」才切 ——
    /// 否则对面若是旧版本（没有 TRTC），两边会各自说给不同的通道，结果谁都听不到。
    @Published private(set) var usingTRTC = false
    /// TRTC 已进房（还没切媒体）
    private var trtcJoined = false
    /// TRTC 的远端画面 / 本地小窗（界面直接用）
    var trtcRemoteView: UIView? { TRTCBridge.shared.remoteView }
    var trtcLocalView: UIView? { TRTCBridge.shared.localView }
    /// TRTC 进房后对端在不在
    var trtcPeerInRoom: Bool { TRTCBridge.shared.peerInRoom }

    func dismissDialog() {
        dialogTask?.cancel()
        dialogTask = nil
        dialog = nil
    }

    /// 弹一个对话框：title 必给，detail 可以空，auto > 0 就是自动关掉
    func showDialog(_ title: String, detail: String = "", auto: Double = 0) {
        guard !title.isEmpty else { return }
        dialogTask?.cancel()
        dialog = Dialog(title: title, detail: detail, auto: auto)
        guard auto > 0 else { return }
        dialogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(auto * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.dialog = nil
        }
    }
    /// 给界面渲染用的远端 / 本地画面
    @Published private(set) var remoteVideo: RTCVideoTrack?
    @Published private(set) var localVideo: RTCVideoTrack?
    /// 出错提示（界面弹一下就行）
    @Published var errorText: String?
    /// 最小化：通话照旧，界面缩成顶部一条（微信左上那个画中画按钮）
    @Published var minimized = false
    /// 有没有拿到「中继(relay)」候选：外网通话能不能兜底全看它。界面会显示出来，方便排查。
    @Published var relayOK = false

    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var callId = ""
    /// 当前通话的对方（聊天页靠它判断"这通电话是不是跟这个人打的"）
    private(set) var peerId = ""
    private var iAmCaller = false
    private var remoteOfferSDP: String?
    private var pendingIce: [RTCIceCandidate] = []
    /// 等服务器回答「两端是不是同一个网络」的等待者
    private var netWaiters: [String: CheckedContinuation<Bool, Never>] = [:]

    /// 问服务器：我和对端是不是同一个网络？
    /// 同一个 → 直连（快、不占带宽）；不同 → 强制走中继（4G↔宽带这种直连经常只通一半）
    func askSameNetwork(peerUserId: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            netWaiters[peerUserId] = cont
            Realtime.shared.sendJSON(["type": "call", "action": "net", "peerId": peerUserId])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let c = netWaiters.removeValue(forKey: peerUserId) {
                    c.resume(returning: false)      // 问不到就按「不同网络」处理：走中继最稳
                }
            }
        }
    }
    private var audioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private var ticker: Timer?
    /// 拨出去没人接的兜底计时（服务端 45 秒也会结束，这里是客户端保险，别让界面卡在"呼叫中"）
    private var ringTimer: Timer?
    /// 「正在接通」时的 12 秒观察（连不上就给提示）
    private var connectTimer: Timer?
    private var sub: AnyCancellable?
    /* 打洞 / 中转服务器。默认这套是国内能连上的 STUN + 一个公共 TURN：
       同一个 Wi-Fi 里其实用不到它们，但**跨网络**（4G/别人家宽带）必须靠 TURN 中转，
       不然对称 NAT 下两边根本连不上。后台「语音通话」里填了 iceServers 就用后台的。 */
    private var iceServers: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.miwifi.com:3478", "stun:stun.cloudflare.com:3478"]),
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
        RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:80", "turn:openrelay.metered.ca:443"],
                     username: "openrelayproject", credential: "openrelayproject")
    ]

    private override init() {
        super.init()
        // 服务器一推 call 事件就交给 handle
        sub = Realtime.shared.$event
            .receive(on: RunLoop.main)
            .sink { [weak self] ev in
                guard ev.type == "call" || ev.type == "call-error" else { return }
                self?.handle(ev)
            }
        Task { await loadIce() }
    }

    /* ---------------------------------------------------------- 对外动作 */

    /// 打出去（peer 是一对一会话里的对方）
    func start(peerId: String, name: String, avatar: String, video: Bool) {
        guard phase == .idle else { errorText = "正在通话中"; return }
        guard !peerId.isEmpty else { errorText = "找不到对方账号"; return }
        dismissDialog()                 // 上一通留下的对话框别压在新通话上面
        self.peerId = peerId
        peerName = name
        peerAvatar = avatar
        isVideo = video
        iAmCaller = true
        relayOK = false                      // 新的一通电话：中继状态重新算
        muted = false
        cameraOff = false
        seconds = 0
        tip = video ? "正在等待对方接受邀请…" : "正在呼叫…"
        callId = "call" + String(Int(Date().timeIntervalSince1970 * 1000)) + String(UUID().uuidString.prefix(4))
        phase = .outgoing
        startRingTimeout()
        Ringtone.shared.startRingback()        // 等对方接的时候放回铃音（嘟——）
        Task { await beginMedia() }
        Task { await startTRTCIfPossible() }   // 能进腾讯云就交给腾讯云（两边都拨进来以后音视频才真正通）
    }

    /// 接听（来电界面点绿键）
    func accept() {
        guard phase == .incoming else { return }
        Ringtone.shared.stop()
        relayOK = false                      // 接起来：中继状态重新算
        phase = .connecting
        tip = "正在接通…"
        Task { await beginMedia() }
        Task { await startTRTCIfPossible() }
        startConnectWatch()
        startServerAudioIfVoice()            // 语音：立刻开始走服务器转发
    }

    /// 拒接
    func reject() {
        guard !callId.isEmpty else { return }
        sendCall(["action": "reject"])
        finish(tip: "已拒绝")
    }

    /// 挂断 / 取消
    func hangup() {
        guard phase.isBusy else { return }
        failTask?.cancel()
        failTask = nil
        let started = (phase == .active)
        if !callId.isEmpty {
            sendCall(["action": started ? "hangup" : (iAmCaller ? "cancel" : "reject")])
        }
        finish(tip: started ? "通话结束" : "已取消")
    }

    func toggleMute() {
        muted.toggle()
        audioTrack?.isEnabled = !muted
        if usingTRTC { TRTCBridge.shared.setMuted(muted) }
    }

    func toggleCamera() {
        guard isVideo else { return }
        cameraOff.toggle()
        localVideoTrack?.isEnabled = !cameraOff
        if usingTRTC { TRTCBridge.shared.setCameraOff(cameraOff) }
    }

    /// 扬声器开关：语音通话默认走听筒（关），视频通话默认开
    func toggleSpeaker() {
        speakerOn.toggle()
        applySpeaker()
        if usingTRTC { TRTCBridge.shared.setSpeaker(speakerOn) }
    }

    func minimize() { minimized = true }
    func restore() { minimized = false }

    /// 邀请好友加入通话：给对方发一条邀请消息（点它就能回拨过来）。
    /// 提示：多人同时在一个通话里需要服务器支持多路，这块还没做，所以现在是把人叫进来。
    func invite(userId: String, name: String) async -> String {
        do {
            let chat = try await API.shared.directChat(userId: userId)
            _ = try await API.shared.send(chatId: chat.id, kind: "text",
                                          content: "邀请你加入语音通话，点这条消息回拨给我")
            return "已邀请 \(name)"
        } catch {
            return (error as? APIError)?.errorDescription ?? "邀请失败"
        }
    }

    private func applySpeaker() {
        let s = AVAudioSession.sharedInstance()
        try? s.overrideOutputAudioPort(speakerOn ? .speaker : .none)
    }

    /// 前后摄像头切换（视频通话中）
    func flipCamera() {
        if usingTRTC { TRTCBridge.shared.flipCamera(); return }
        guard isVideo, let capturer = capturer else { return }
        let front = capturer.captureSession.isRunning
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let dev = devices.first(where: { $0.position == (front ? .back : .front) }) ?? devices.first else { return }
        guard let fmt = bestFormat(for: dev) else { return }
        capturer.startCapture(with: dev, format: fmt, fps: 30)
    }

    /* ---------------------------------------------------------- 信令 */

    private func sendCall(_ body: [String: Any]) {
        var msg: [String: Any] = ["type": "call", "callId": callId]
        body.forEach { msg[$0.key] = $0.value }
        Realtime.shared.sendJSON(msg)
    }

    /// 语音通话：开始走「服务器转发」这条路（不用等 WebRTC，运营商挡不住）
    private func startServerAudioIfVoice() {
        guard !isVideo else { return }
        guard !serverAudioOn else { return }
        serverAudioOn = true
        audioTrack?.isEnabled = false          // 别让 WebRTC 的音频再叠一份
        CallAudioPipe.shared.onFrame = { [weak self] data in
            guard let self = self, !self.muted else { return }
            self.sendCall(["action": "audio", "data": data.base64EncodedString()])
        }
        CallAudioPipe.shared.start()
        Task { await API.shared.callDiag("App 语音走服务器转发 采集=" + (CallAudioPipe.shared.isRunning ? "ok" : "失败")
            + (CallAudioPipe.shared.isRunning ? "" : " 原因: " + CallAudioPipe.shared.lastError)) }
        note("语音走服务器转发 ✓")
        /* 这条路已经开始传声音了：界面直接进入「通话中」并开始计时（不用等 ICE） */
        if phase != .active {
            Ringtone.shared.stop()
            phase = .active
            tip = "通话中"
            ringTimer?.invalidate()
            ringTimer = nil
            startTimer()
        }
    }

    private func handle(_ ev: PushEvent) {
        if ev.type == "call-error" {
            if !ev.callError.isEmpty { errorText = ev.callError }
            /* 打不通（对方不在线 / 忙线 / 不能打）：先留在通话页上把原因显示几秒，
               再自动挂断。以前是一有 error 就 finish，用户只看到通话页一闪 ——
               用户要求「显示时间长一点再自动挂断」。 */
            if ev.callId == callId { failLater(ev.callError) }
            return
        }
        let action = ev.callAction
        switch action {
        case "net":
            if let c = netWaiters.removeValue(forKey: ev.callPeerId) { c.resume(returning: ev.callSameNetwork) }
        case "incoming":
            // 已经在通话里就自动挂掉（和网页版一样，服务器也会挡忙线）
            guard phase == .idle else {
                Realtime.shared.sendJSON(["type": "call", "action": "reject", "callId": ev.callId])
                return
            }
            callId = ev.callId
            peerId = ev.callPeerId
            peerName = ev.callPeerName.isEmpty ? "对方" : ev.callPeerName
            peerAvatar = ev.callPeerAvatar
            isVideo = (ev.callMedia == "video")
            iAmCaller = false
            muted = false
            cameraOff = false
            seconds = 0
            remoteOfferSDP = ev.callSDP
            tip = isVideo ? "邀请你视频通话…" : "邀请你语音通话…"
            phase = .incoming
            startRingTimeout()
            Ringtone.shared.startIncoming()    // 来电铃声响起来（重复放到接/挂）
            UINotification.buzz()          // 震动提醒

        case "ringing":
            guard ev.callId == callId else { return }
            tip = isVideo ? "正在等待对方接受邀请…" : "正在呼叫…"

        case "accepted":
            guard ev.callId == callId else { return }
            Ringtone.shared.stop()
            phase = .connecting
            tip = "正在接通…"
            startConnectWatch()
            startServerAudioIfVoice()      // 语音：立刻开始走服务器转发（不等 WebRTC）

        case "audio":
            /* 服务器转发过来的语音帧：直接丢给播放器（这条路不依赖 TURN/直连，一定通） */
            guard let b64 = ev.callAudioData, let d = Data(base64Encoded: b64) else { return }
            CallAudioPipe.shared.play(d)

        case "sdp":
            guard ev.callId == callId, let sdp = ev.callSDP else { return }
            let desc = RTCSessionDescription(type: .answer, sdp: sdp)
            pc?.setRemoteDescription(desc) { [weak self] err in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let err = err { self.errorText = "接通失败：\(err.localizedDescription)" }
                    self.flushIce()
                }
            }

        case "ice":
            guard ev.callId == callId, let json = ev.callCandidate else { return }
            guard let data = json.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let sdp = (o["candidate"] as? String) ?? ""
            let mid = (o["sdpMid"] as? String) ?? "0"
            let idx = (o["sdpMLineIndex"] as? Int) ?? 0
            let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(idx), sdpMid: mid)
            if pc?.remoteDescription == nil { pendingIce.append(cand) } else { pc?.add(cand) { _ in } }

        case "end":
            if ev.callId == callId || callId.isEmpty {
                let why: String
                switch ev.callReason {
                case "rejected":     why = "对方已拒绝"
                case "cancel":       why = iAmCaller ? "已取消" : "对方已取消"
                case "timeout":      why = iAmCaller ? "对方无应答" : "未接听"
                case "offline":      why = "对方不在线"
                case "disconnected": why = "对方已断开"
                case "hangup":       why = "通话已结束"
                default:             why = "通话已结束"
                }
                finish(tip: why)
            }

        default:
            break
        }
    }

    /* ---------------------------------------------------------- 媒体 + P2P */

    private func loadIce() async {
        /* 先把自己服务器的内置 TURN 加进去：它永远在（服务器就在跟你说话），
           直连连不上时靠它中转，比任何公网服务都靠得住。 */
        let hostOnly = API.shared.server.split(separator: ":").first.map(String.init) ?? ""
        if !hostOnly.isEmpty {
            /* 自己服务器上的 TURN：TCP 和 UDP 都写上。
               这台云服务器只转发了 TCP 3478（UDP 被服务商挡了），所以 TCP 那条才是能用的。 */
            iceServers.insert(RTCIceServer(urlStrings: ["turn:\(hostOnly):3478?transport=tcp",
                                                       "turn:\(hostOnly):3478?transport=udp"],
                                           username: "chris", credential: "chris1234"), at: 0)
        }
        guard let b = await API.shared.branding(),
              let raw = b.iceServers?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        /* 两种写法都认：
           ① JSON（推荐，能带 TURN 的账号密码）
              [{"urls":"turn:turn.xxx.com:3478","username":"u","credential":"p"}]
           ② 老写法：逗号或换行分隔的一串地址 */
        if let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var out: [RTCIceServer] = []
            for it in arr {
                var urls: [String] = []
                if let one = it["urls"] as? String { urls = [one] }
                else if let many = it["urls"] as? [String] { urls = many }
                if urls.isEmpty { continue }
                out.append(RTCIceServer(urlStrings: urls,
                                        username: it["username"] as? String,
                                        credential: it["credential"] as? String))
            }
            if !out.isEmpty { iceServers = out }
            return
        }
        let list = raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !list.isEmpty { iceServers = list.map { RTCIceServer(urlStrings: [$0]) } }
    }

    private func makeFactory() -> RTCPeerConnectionFactory {
        if let f = factory { return f }
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
        factory = f
        return f
    }

    private func beginMedia() async {
        let mic = await Permission.ask(.audio)
        if !mic { errorText = "没有麦克风权限，去「设置 → CHRIS聊天」里打开"; finish(tip: "没有麦克风权限"); return }
        if isVideo {
            let cam = await Permission.ask(.video)
            if !cam { errorText = "没有摄像头权限，去「设置 → CHRIS聊天」里打开"; finish(tip: "没有摄像头权限"); return }
        }
        activateAudioSession()
        speakerOn = isVideo                    // 视频通话默认外放，语音默认听筒
        applySpeaker()

        /* 语音通话：只听服务器转发，**完全不建 WebRTC**。
           原因：WebRTC 会占住音频会话，导致我们自己的采集引擎起不来
           （日志里网页在发帧、手机一帧都没发就是这个问题）。
           视频通话还是走 WebRTC，语音这条路不依赖 TURN/直连，运营商挡不住。 */
        if !isVideo {
            serverAudioOn = true
            CallAudioPipe.shared.onFrame = { [weak self] data in
                guard let self = self, !self.muted else { return }
                self.sendCall(["action": "audio", "data": data.base64EncodedString()])
            }
            CallAudioPipe.shared.start()
            Task { await API.shared.callDiag("App 语音走服务器转发 采集=" + (CallAudioPipe.shared.isRunning ? "ok" : "失败")
                + (CallAudioPipe.shared.isRunning ? "" : " 原因: " + CallAudioPipe.shared.lastError)) }
            note("语音走服务器转发 ✓")
            if phase != .active {
                Ringtone.shared.stop()
                phase = .active
                tip = "通话中"
                ringTimer?.invalidate()
                ringTimer = nil
                startTimer()
            }
            return
        }

        let f = makeFactory()
        let cfg = RTCConfiguration()
        cfg.iceServers = iceServers
        /* 先问服务器两端是不是同一个网络：
           同一个网络（同一 Wi-Fi / 同一出口）→ 直连，快、不占服务器带宽；
           不同网络（4G ↔ 家里宽带）→ 强制走中继，不然直连经常只通一半甚至完全连不通。
           服务器是局域网地址（本机部署）时也直接走直连。 */
        let sameNet = await askSameNetwork(peerUserId: peerId)
        _ = sameNet        // 只记诊断用；策略上公网一律走中继（两端一致，避免半通）
        let host = API.shared.server.split(separator: ":").first.map(String.init) ?? ""
        let isLan = host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("10.")
            || host.hasPrefix("192.168.") || host.hasPrefix("172.16") || host.hasPrefix("172.17")
            || host.hasPrefix("172.18") || host.hasPrefix("172.19") || host.hasPrefix("172.2")
            || host.hasPrefix("172.30") || host.hasPrefix("172.31")
        /* 以前公网强制「只走中继」，结果 4G↔宽带 这种组合经常连不上（一边走 TCP 中继、
           一边走 UDP 中继就配不上对）。现在改成 .all：直连能通用直连（快、不占带宽），
           连不上时 ICE 自己会退到中继候选。 */
        cfg.iceTransportPolicy = .all
        note("配置 iceServers=" + iceServers.map { ($0.urlStrings.first ?? "") }.joined(separator: ",")
             + " policy=all lan=" + (isLan ? "1" : "0"))
        cfg.sdpSemantics = .unifiedPlan
        let pc = f.peerConnection(with: cfg,
                                  constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                  delegate: self)
        self.pc = pc
        guard let pc = pc else { errorText = "初始化通话失败"; finish(tip: "初始化通话失败"); return }

        // 音频轨
        let audioSource = f.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let at = f.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack = at
        pc.add(at, streamIds: ["chris"])

        // 视频轨（视频通话才有）
        if isVideo {
            let src = f.videoSource()
            videoSource = src
            let vt = f.videoTrack(with: src, trackId: "video0")
            localVideoTrack = vt
            pc.add(vt, streamIds: ["chris"])
            localVideo = vt
            startCapture(src)
        }

        if iAmCaller {
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, err in
                Task { @MainActor in
                    guard let self = self, let sdp = sdp else {
                        self?.errorText = err?.localizedDescription ?? "无法发起通话"
                        self?.finish(tip: "无法发起通话")
                        return
                    }
                    pc.setLocalDescription(sdp) { _ in
                        Task { @MainActor in
                            let local = pc.localDescription
                            self.sendCall(["action": "invite", "toUserId": self.peerId,
                                           "media": self.isVideo ? "video" : "audio",
                                           "sdp": ["type": local?.type.rawValue ?? "offer",
                                                   "sdp": local?.sdp ?? sdp.sdp]])
                        }
                    }
                }
            }
        } else {
            guard let offerSDP = remoteOfferSDP else { errorText = "来电信息不完整"; finish(tip: "来电信息不完整"); return }
            let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
            pc.setRemoteDescription(offer) { [weak self] err in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let err = err { self.errorText = "接通失败：\(err.localizedDescription)"; self.finish(tip: "接通失败"); return }
                    self.flushIce()
                    pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, _ in
                        Task { @MainActor in
                            guard let sdp = sdp else { self.finish(tip: "接通失败"); return }
                            pc.setLocalDescription(sdp) { _ in
                                Task { @MainActor in
                                    let local = pc.localDescription
                                    self.sendCall(["action": "accept",
                                                   "sdp": ["type": local?.type.rawValue ?? "answer",
                                                           "sdp": local?.sdp ?? sdp.sdp]])
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func flushIce() {
        guard let pc = pc, pc.remoteDescription != nil else { return }
        pendingIce.forEach { pc.add($0) { _ in } }
        pendingIce.removeAll()
    }

    private func startCapture(_ source: RTCVideoSource) {
        let cap = RTCCameraVideoCapturer(delegate: source)
        capturer = cap
        guard let dev = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
            ?? RTCCameraVideoCapturer.captureDevices().first,
              let fmt = bestFormat(for: dev) else { return }
        cap.startCapture(with: dev, format: fmt, fps: 30)
    }

    private func bestFormat(for dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: dev)
        return formats.min(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - 1280) + abs(Int(da.height) - 720)
                 < abs(Int(db.width) - 1280) + abs(Int(db.height) - 720)
        }) ?? formats.last
    }

    private func activateAudioSession() {
        let s = AVAudioSession.sharedInstance()
        /* 通话就该用 voiceChat 模式：不写 .defaultToSpeaker，默认走听筒（和微信一样，
           参考图里"扬声器已关"就是听筒），点扬声器再 overrideOutputAudioPort(.speaker)。 */
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth])
        try? s.setActive(true)
    }

    private func stopMedia() {
        capturer?.stopCapture()
        capturer = nil
        if let pc = pc {
            pc.close()
        }
        pc = nil
        audioTrack = nil
        localVideoTrack = nil
        videoSource = nil
        remoteVideo = nil
        localVideo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finish(tip: String) {
        let wasIdle = (phase == .idle)
        let secs = seconds
        failTask?.cancel()
        failTask = nil
        self.tip = tip
        Ringtone.shared.stop()
        ticker?.invalidate()
        ticker = nil
        ringTimer?.invalidate()
        ringTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        /* 结束通话：把服务器转发的那条音频通道也关掉 */
        CallAudioPipe.shared.onFrame = nil
        CallAudioPipe.shared.stop()
        serverAudioOn = false
        /* 腾讯云那路也退房 */
        if usingTRTC || TRTCBridge.shared.joined {
            TRTCBridge.shared.stop()
        }
        usingTRTC = false
        trtcJoined = false
        stopMedia()
        /* 把这一通的 ICE 过程报给服务器（写进 call-trace.log），
           「一直在连接中」这种问题一看就知道卡在哪一步 */
        if !diag.isEmpty {
            let line = (iAmCaller ? "主叫" : "被叫") + (isVideo ? " 视频" : " 语音")
                + " 结果=" + (tip.isEmpty ? "结束" : tip) + " | " + diag.joined(separator: " ")
            diag.removeAll()
            Task { await API.shared.callDiag(line) }
        }
        callId = ""
        peerId = ""
        remoteOfferSDP = nil
        pendingIce.removeAll()
        seconds = 0
        muted = false
        cameraOff = false
        if !wasIdle {
            phase = .idle
            /* 按最新要求：挂断以后不再弹「通话已结束」那种小卡片了。
               通话结果本来就会在聊天里留一条记录（已取消 / 对方无应答 / 通话时长 …）。 */
        }
    }

    /// 打不通时：先把原因留在通话页上显示一会儿，再自动挂断（默认 8 秒）。
    /// 这段时间里用户可以自己点挂断，也可以看着原因看完它自己收。
    private func failLater(_ tip: String, hold: Double = 8) {
        guard phase != .idle else { return }
        let text = tip.isEmpty ? "对方没有接听" : tip
        errorText = text
        self.tip = text
        failTask?.cancel()
        failTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.finish(tip: text)
        }
    }

    /// 记一条诊断（最多留 20 条），通话结束时一起报给服务器
    private func note(_ s: String) {
        diag.append(s)
        if diag.count > 20 { diag.removeFirst() }
    }

    /// 接通阶段盯 12 秒：还是「正在接通」就把最可能的原因写在屏幕上
    private func startConnectWatch() {
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.phase == .connecting else { return }
                self.errorText = "声音一直连不上：① 两边都打开「设置 → CHRIS聊天 → 本地网络」；② 两台设备最好在同一个 Wi-Fi"
                self.tip = self.errorText ?? ""
            }
        }
    }

    private static func iceName(_ s: RTCIceConnectionState) -> String {
        switch s {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "?"
        }
    }

    private static func gatherName(_ s: RTCIceGatheringState) -> String {
        switch s {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        @unknown default: return "?"
        }
    }

    private func startTimer() {
        seconds = 0
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.seconds += 1 }
        }
    }

    /// 响了没人接：服务端 60 秒会自己收尾（记「对方无应答」），
    /// 这里 65 秒兜底一次——网络把服务端的 end 丢了也不会一直响下去。
    /// 主动方自己挂断时带 reason:'timeout'，让服务端记「对方无应答」而不是「已取消」。
    private func startRingTimeout() {
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 65, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.phase == .outgoing || self.phase == .incoming else { return }
                if !self.callId.isEmpty && self.iAmCaller {
                    self.sendCall(["action": "cancel", "reason": "timeout"])
                }
                self.finish(tip: self.iAmCaller ? "对方无应答" : "未接听")
            }
        }
    }
}

/* ---------------------------------------------------------- WebRTC 回调 */

extension CallCenter: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        Task { @MainActor in self.note("ice=" + CallCenter.iceName(state)) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in self.note("gathering=" + CallCenter.gatherName(newState)) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let isRelay = candidate.sdp.contains("typ relay")
        let isSrflx = candidate.sdp.contains("typ srflx")
        /* 诊断里写清楚类型和协议（host/srflx/relay + udp/tcp）：
           以前只写前 24 个字符，看不出是 TCP 还是 UDP，排查时抓瞎。 */
        let parts = candidate.sdp.split(separator: " ")
        let typ = parts.count > 7 ? String(parts[7]) : "?"
        let proto = parts.count > 2 ? String(parts[2]) : "?"
        let addr = parts.count > 5 ? "\(parts[4]):\(parts[5])" : ""
        let brief = "\(typ)/\(proto) \(addr)"
        if isRelay || isSrflx {
            Task { @MainActor in
                if isRelay { self.relayOK = true }
                self.note("cand=" + brief)
            }
        } else {
            Task { @MainActor in self.note("cand=" + brief) }
        }
        let body: [String: Any] = ["action": "ice",
                                   "candidate": ["candidate": candidate.sdp,
                                                 "sdpMid": candidate.sdpMid ?? "0",
                                                 "sdpMLineIndex": Int(candidate.sdpMLineIndex)]]
        Task { @MainActor in self.sendCall(body) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }

    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        Task { @MainActor in self.remoteVideo = track }
    }

    /// Unified Plan 下远端画面是从 receiver 来的（上面那个 stream 回调不一定触发）
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in self.remoteVideo = track }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove receiver: RTCRtpReceiver, streams: [RTCMediaStream]) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected:
                if self.phase != .active {
                    Ringtone.shared.stop()
                    self.phase = .active
                    self.tip = self.isVideo ? "视频通话中" : "通话中"
                    self.ringTimer?.invalidate()
                    self.ringTimer = nil
                    self.startTimer()
                    /* 接通也弹一下（同一个对话框，2 秒后自己关） */
                    self.showDialog(self.isVideo ? "视频通话已接通" : "语音通话已接通",
                                    detail: "", auto: 2)
                }
            case .failed:
                /* 通话中途断：也留 5 秒让用户看清原因 */
                self.failLater("通话连接失败，可能是网络挡住了", hold: 5)
            case .disconnected:
                // 断开 3 秒还没恢复就结束（和网页版一致）
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.phase == .active && self.pc?.connectionState == .disconnected {
                    self.finish(tip: "通话已断开")
                }
            default:
                break
            }
        }
    }
}

/* ---------------------------------------------------------- 小工具 */

enum Permission {
    /// 申请麦克风 / 摄像头权限
    static func ask(_ kind: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: kind) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: kind) { ok in cont.resume(returning: ok) }
            }
        default: return false
        }
    }
}

enum UINotification {
    /// 来电震一下（不依赖通知权限）
    static func buzz() {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.impactOccurred()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}
    /* ---------------------------------------------------------- 腾讯云 TRTC
       进房成功**不马上切**：先看对端有没有也进到这个房间。
         · 对端也进来了 → 媒体切给 TRTC（把我们自己那两路停掉，免得叠音）
         · 对端没进来（旧版本 / 取不到票 / 网络不通）→ 继续走原来的
           WebRTC（视频）+ 服务器转发语音，通话照样通，不会变哑巴。 */

    private func startTRTCIfPossible() async {
        guard !trtcJoined, !usingTRTC, !callId.isEmpty else { return }
        let bridge = TRTCBridge.shared
        bridge.onJoined = { [weak self] ok in
            guard let self = self else { return }
            guard ok else { return }
            self.trtcJoined = true
            self.note("TRTC 已进房（等对端）")
            /* 对端已经在房里了（比如我先退再进）：直接切 */
            if TRTCBridge.shared.peerInRoom { self.switchMediaToTRTC() }
        }
        bridge.onPeerChanged = { [weak self] inRoom in
            guard let self = self else { return }
            guard inRoom else { return }
            if self.trtcJoined { self.switchMediaToTRTC() }
            if self.phase != .active {
                Ringtone.shared.stop()
                self.phase = .active
                self.tip = "通话中"
                self.ringTimer?.invalidate()
                self.ringTimer = nil
                self.connectTimer?.invalidate()
                self.connectTimer = nil
                self.startTimer()
            }
        }
        let ok = await bridge.start(roomSeed: callId, video: isVideo)
        if !ok {
            note("TRTC 用不了：" + bridge.lastError + "（继续走老路）")
        } else {
            note("TRTC 已请求进房（room=" + callId + "）")
            /* 8 秒还没等到对端进房，就当对面不是 TRTC 版本，把老路继续用着 */
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self = self, !self.usingTRTC, !Task.isCancelled else { return }
                self.note("对端没进 TRTC 房间（可能是旧版本）→ 继续走服务器转发/WebRTC")
            }
        }
    }

    /// 确认对端也在 TRTC 房间里了：把媒体完全交给腾讯云
    private func switchMediaToTRTC() {
        guard !usingTRTC else { return }
        usingTRTC = true
        note("对端也在腾讯云房间里 → 媒体切到 TRTC ✓")
        /* 关掉我们自己那两路，避免叠音 + 抢摄像头 */
        CallAudioPipe.shared.onFrame = nil
        CallAudioPipe.shared.stop()
        serverAudioOn = false
        audioTrack?.isEnabled = false
        localVideoTrack?.isEnabled = false
        capturer?.stopCapture()
        /* 我们自己不采集了，才让 TRTC 开始采集（避免两个引擎抢麦克风/摄像头） */
        TRTCBridge.shared.activate()
        TRTCBridge.shared.setMuted(muted)
        TRTCBridge.shared.setSpeaker(speakerOn)
        if phase != .active {
            Ringtone.shared.stop()
            phase = .active
            tip = "通话中"
            ringTimer?.invalidate()
            ringTimer = nil
            connectTimer?.invalidate()
            connectTimer = nil
            startTimer()
        }
    }
