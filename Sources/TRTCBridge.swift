import Foundation
import UIKit
import SwiftUI
import TXLiteAVSDK_TRTC

/* ============================================================
   腾讯云 TRTC（音视频通话）

   为什么要它：自己的 TURN 走 UDP 被机房/家宽挡住的时候，跨网通话就连不上
   （实测：3478/udp 从外网没有回包）。TRTC 走腾讯云的接入点，不依赖我们自己的中继。

   怎么用：进房要三样东西（sdkAppId / userId / userSig），这三样都由我们服务器签
   （见 /api/trtc/sig，密钥只在服务端）。房间号按「这次通话的 callId」算，两边一致。

   和老的 WebRTC 怎么相处：TRTC **进房成功才接管**媒体；进不去（没配置、网络不通）
   就什么也不动，继续走原来那套 WebRTC + 服务器转发语音，保证不退化。
   ============================================================ */

@MainActor
final class TRTCBridge: NSObject, ObservableObject {
    static let shared = TRTCBridge()

    /// 已经进房（媒体由 TRTC 负责）
    @Published private(set) var joined = false
    /// 远端画面（TRTC 自己往这个 view 里画）
    @Published private(set) var remoteView: UIView? = nil
    /// 本地画面（小窗）
    @Published private(set) var localView: UIView? = nil
    /// 对端有没有人在房间里
    @Published private(set) var peerInRoom = false
    /// 最近一次错误（给通话页显示）
    @Published private(set) var lastError = ""

    /// 进房 / 退房回调（CallCenter 用它切状态）
    var onJoined: ((Bool) -> Void)?
    var onPeerChanged: ((Bool) -> Void)?

    private var cloud: TRTCCloud?
    private var roomSeed = ""
    private var isVideo = false
    private var busy = false
    /// 房间里那个对端的 userId（退房前要把它的画面停掉）
    private var peerUserId = ""
    /// 是否已经开始真正采集（麦克风 / 摄像头）
    private var active = false

    private override init() { super.init() }

    /// 进房。返回 false 表示「TRTC 用不了」，调用方继续用老路。
    @discardableResult
    func start(roomSeed: String, video: Bool) async -> Bool {
        guard !joined, !busy else { return joined }
        busy = true
        defer { busy = false }
        self.roomSeed = roomSeed
        isVideo = video
        lastError = ""

        let cfg: API.TRTCSig
        do {
            cfg = try await API.shared.trtcSig(room: roomSeed)
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? "TRTC 取不到签名"
            return false
        }
        guard cfg.sdkAppId > 0, !cfg.userSig.isEmpty, cfg.roomId > 0 else {
            lastError = "TRTC 参数不完整"
            return false
        }

        let params = TRTCParams()
        params.sdkAppId = UInt32(cfg.sdkAppId)
        params.userId = cfg.userId
        params.userSig = cfg.userSig
        params.roomId = UInt32(cfg.roomId)
        params.role = .anchor

        let c = TRTCCloud.sharedInstance()
        c.delegate = self
        cloud = c
        remoteView = UIView()
        localView = UIView()
        /* 先只「进房」，**不采集**麦克风和摄像头 ——
           不然会和我们自己的 WebRTC / 服务器转发抢麦克风（两个引擎同时开就是沙沙声或没声）。
           等确认对端也在这个房间里，再调 activate() 真正开始采集。 */
        c.enterRoom(params, appScene: video ? .videoCall : .audioCall)
        return true
    }

    /// 对端也在房间里了：这时候才真正开始采集（麦克风 + 视频通话的摄像头）
    func activate() {
        guard let c = cloud, joined, !active else { return }
        active = true
        c.startLocalAudio(.default)
        c.muteLocalAudio(false)
        if isVideo { c.startLocalPreview(true, view: localView) }
    }

    func stop() {
        cloud?.stopLocalPreview()
        cloud?.stopLocalAudio()
        if !peerUserId.isEmpty { cloud?.stopRemoteView(peerUserId) }
        cloud?.exitRoom()
        cloud?.delegate = nil
        cloud = nil
        TRTCCloud.destroySharedInstance()
        joined = false
        peerInRoom = false
        peerUserId = ""
        active = false
        remoteView = nil
        localView = nil
    }

    /* ---------------- 通话中那几个开关 ---------------- */

    func setMuted(_ mute: Bool) {
        cloud?.muteLocalAudio(mute)
    }

    func setCameraOff(_ off: Bool) {
        guard isVideo else { return }
        if off { cloud?.stopLocalPreview() } else { cloud?.startLocalPreview(true, view: localView) }
    }

    func flipCamera() {
        cloud?.switchCamera()
    }

    func setSpeaker(_ on: Bool) {
        /* 头文件里：TRTCAudioModeSpeakerphone = 0（外放）、TRTCAudioModeEarpiece = 1（听筒）。
           这里按原始值构造，省得被 Swift 把枚举名改来改去。 */
        if let route = TRTCAudioRoute(rawValue: on ? 0 : 1) {
            cloud?.setAudioRoute(route)
        }
    }
}

extension TRTCBridge: TRTCCloudDelegate {
    nonisolated func onEnterRoom(_ result: Int) {
        Task { @MainActor in
            if result > 0 {
                self.joined = true
                self.lastError = ""
                self.onJoined?(true)
            } else {
                self.joined = false
                self.lastError = "TRTC 进房失败（错误码 \(result)）"
                self.onJoined?(false)
            }
        }
    }

    nonisolated func onExitRoom(_ reason: Int) {
        Task { @MainActor in
            self.joined = false
            self.peerInRoom = false
            self.onJoined?(false)
        }
    }

    nonisolated func onRemoteUserEnterRoom(_ userId: String) {
        Task { @MainActor in
            self.peerUserId = userId
            self.peerInRoom = true
            self.onPeerChanged?(true)
        }
    }

    nonisolated func onRemoteUserLeaveRoom(_ userId: String, reason: Int) {
        Task { @MainActor in
            self.peerInRoom = false
            self.onPeerChanged?(false)
        }
    }

    nonisolated func onUserVideoAvailable(_ userId: String, available: Bool) {
        Task { @MainActor in
            if available, let v = self.remoteView {
                self.peerUserId = userId
                self.cloud?.startRemoteView(userId, view: v)
                self.peerInRoom = true
                self.onPeerChanged?(true)
            } else {
                self.cloud?.stopRemoteView(userId)
            }
        }
    }

    nonisolated func onError(_ errCode: Int, errMsg: String?, extInfo: [String: Any]?) {
        Task { @MainActor in
            self.lastError = "TRTC 错误 \(errCode)：" + (errMsg ?? "")
        }
    }
}

/* ============================================================
   把 TRTC 的 UIView 塞进 SwiftUI（远端大画面 / 本地小窗都用它）
   ============================================================ */

struct TRTCVideoView: UIViewRepresentable {
    let view: UIView?

    func makeUIView(context: Context) -> UIView {
        let holder = UIView()
        holder.backgroundColor = .clear
        if let v = view {
            v.frame = holder.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.addSubview(v)
        }
        return holder
    }

    func updateUIView(_ holder: UIView, context: Context) {
        guard let v = view else { return }
        if v.superview !== holder {
            v.frame = holder.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.addSubview(v)
        }
    }
}
