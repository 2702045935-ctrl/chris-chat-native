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
    /// 给界面渲染用的远端 / 本地画面
    @Published private(set) var remoteVideo: RTCVideoTrack?
    @Published private(set) var localVideo: RTCVideoTrack?
    /// 出错提示（界面弹一下就行）
    @Published var errorText: String?

    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    private var callId = ""
    private var peerId = ""
    private var iAmCaller = false
    private var remoteOfferSDP: String?
    private var pendingIce: [RTCIceCandidate] = []
    private var audioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private var ticker: Timer?
    /// 拨出去没人接的兜底计时（服务端 45 秒也会结束，这里是客户端保险，别让界面卡在"呼叫中"）
    private var ringTimer: Timer?
    private var sub: AnyCancellable?
    private var iceUrls: [String] = ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]

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
        self.peerId = peerId
        peerName = name
        peerAvatar = avatar
        isVideo = video
        iAmCaller = true
        muted = false
        cameraOff = false
        seconds = 0
        tip = video ? "正在等待对方接受邀请…" : "正在呼叫…"
        callId = "call" + String(Int(Date().timeIntervalSince1970 * 1000)) + String(UUID().uuidString.prefix(4))
        phase = .outgoing
        startRingTimeout()
        Task { await beginMedia() }
    }

    /// 接听（来电界面点绿键）
    func accept() {
        guard phase == .incoming else { return }
        phase = .connecting
        tip = "正在接通…"
        Task { await beginMedia() }
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
        let started = (phase == .active)
        if !callId.isEmpty {
            sendCall(["action": started ? "hangup" : (iAmCaller ? "cancel" : "reject")])
        }
        finish(tip: started ? "通话结束" : "已取消")
    }

    func toggleMute() {
        muted.toggle()
        audioTrack?.isEnabled = !muted
    }

    func toggleCamera() {
        guard isVideo else { return }
        cameraOff.toggle()
        localVideoTrack?.isEnabled = !cameraOff
    }

    /// 扬声器开关：语音通话默认走听筒（关），视频通话默认开
    func toggleSpeaker() {
        speakerOn.toggle()
        applySpeaker()
    }

    private func applySpeaker() {
        let s = AVAudioSession.sharedInstance()
        try? s.overrideOutputAudioPort(speakerOn ? .speaker : .none)
    }

    /// 前后摄像头切换（视频通话中）
    func flipCamera() {
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

    private func handle(_ ev: PushEvent) {
        if ev.type == "call-error" {
            if !ev.callError.isEmpty { errorText = ev.callError }
            if ev.callId == callId { finish(tip: ev.callError) }
            return
        }
        let action = ev.callAction
        switch action {
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
            UINotification.buzz()          // 震动提醒

        case "ringing":
            guard ev.callId == callId else { return }
            tip = isVideo ? "正在等待对方接受邀请…" : "正在呼叫…"

        case "accepted":
            guard ev.callId == callId else { return }
            phase = .connecting
            tip = "正在接通…"

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
                case "timeout":      why = "未接听"
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
        guard let b = await API.shared.branding() else { return }
        // 后台配了就优先用后台的（跨网络需要 TURN 时在这儿填）
        if let raw = b.iceServers?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let list = raw.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { String($0).trimmingCharacters(in: .whitespaces) }
            let urls = list.filter { !$0.isEmpty }
            if !urls.isEmpty { iceUrls = urls }
        }
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

        let f = makeFactory()
        let cfg = RTCConfiguration()
        cfg.iceServers = iceUrls.map { RTCIceServer(urlStrings: [$0]) }
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
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
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
        self.tip = tip
        ticker?.invalidate()
        ticker = nil
        ringTimer?.invalidate()
        ringTimer = nil
        stopMedia()
        callId = ""
        peerId = ""
        remoteOfferSDP = nil
        pendingIce.removeAll()
        seconds = 0
        muted = false
        cameraOff = false
        if !wasIdle {
            phase = .idle
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

    /// 45 秒还没接通就自己挂掉（服务端也会推 end，两边都做才不会被网络问题卡住）
    private func startRingTimeout() {
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.phase == .outgoing || self.phase == .incoming else { return }
                if !self.callId.isEmpty {
                    self.sendCall(["action": self.iAmCaller ? "cancel" : "reject"])
                }
                self.finish(tip: "未接听")
            }
        }
    }
}

/* ---------------------------------------------------------- WebRTC 回调 */

extension CallCenter: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
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
                    self.phase = .active
                    self.tip = self.isVideo ? "视频通话中" : "通话中"
                    self.ringTimer?.invalidate()
                    self.ringTimer = nil
                    self.startTimer()
                }
            case .failed:
                self.errorText = "通话连接失败，可能是网络挡住了"
                self.finish(tip: "通话失败")
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
