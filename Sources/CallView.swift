import SwiftUI
import WebRTC

/* ============================================================
   通话界面 —— 照微信参考图做的（420×912pt 量的）：

     · 背景：聊天背景图「糊掉 + 压暗」（不是纯黑）。参考图实测是深橄榄色渐变，
       说明背后是一张被虚化的照片。没设背景图就退化成深灰。
     · 头像 96 居中，顶在 y≈251（安全区下面约 156）
     · 名字 22pt 白色（y≈367）、状态 15pt 白 70%（y≈404）
     · 提示（比如"暂时无法接通…"）15pt 白 55%（y≈559）
     · 底部三个 72pt 圆按钮 + 各自标签（y≈726 圆、y≈812 标签）：
         麦克风已开/已关      取消（红，视频/语音通话中）      扬声器已开/已关
       来电时换成：拒接（红） / 接听（绿）
   两个后台参数：callBackdropBlur（模糊，默认 40）、callGlassTint（压暗，默认 0.45）
   ============================================================ */

struct CallOverlay: View {
    @ObservedObject private var call = CallCenter.shared

    var body: some View {
        if call.phase != .idle {
            CallView()
                .zIndex(999)
        }
    }
}

struct CallView: View {
    @ObservedObject private var call = CallCenter.shared
    @EnvironmentObject var app: AppState

    private var blurRadius: CGFloat { UIConfig.num("callBackdropBlur", 40) }
    private var tint: CGFloat { UIConfig.num("callGlassTint", 0.45) }

    /// 通话背景用的聊天背景图（自己设的 → 服务器默认 → 没有）
    private var bgPath: String {
        let v = app.me?.chatBackground ?? "auto"
        if v.isEmpty || v == "auto" {
            let def = app.defaultChatBackground
            return (def == "auto") ? "" : def
        }
        return v
    }

    var body: some View {
        ZStack {
            backdrop

            if call.isVideo && call.phase == .active {
                videoLayer
            } else {
                avatarLayer
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomBar
            }
        }
    }

    /* ---------------------------------------------------------- 背景 */

    private var backdrop: some View {
        ZStack {
            Color(red: 0.10, green: 0.11, blue: 0.10)
            if !bgPath.isEmpty {
                RemoteImage(path: bgPath)
                    .blur(radius: blurRadius)
                    .scaleEffect(1.25)                  // 糊完边缘不留白
            }
            Color.black.opacity(tint)                   // 压暗，保证白字看得清
        }
        .ignoresSafeArea()
    }

    /* ---------------------------------------------------------- 语音/呼叫中：头像 + 名字 */

    private var avatarLayer: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: max(40, 251 - L.safeTop))
            Avatar(path: call.peerAvatar, size: 96, radius: 12)
            Text(call.peerName)
                .font(pfExact(22, .medium))
                .foregroundColor(.white)
                .padding(.top, 20)
            Text(statusText)
                .font(pfExact(15))
                .foregroundColor(.white.opacity(0.7))
                .padding(.top, 6)
            if !hintText.isEmpty {
                Text(hintText)
                    .font(pfExact(15))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 142)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /* ---------------------------------------------------------- 视频通话：远端铺满 + 本地小窗 */

    private var videoLayer: some View {
        ZStack {
            VideoSurface(track: call.remoteVideo)
                .ignoresSafeArea()
            if call.remoteVideo == nil {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在连接画面…")
                        .font(pfExact(14))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.peerName)
                            .font(pfExact(17, .medium))
                            .foregroundColor(.white)
                        Text(statusText)
                            .font(pfExact(13))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                Spacer()
                HStack {
                    Spacer()
                    VideoSurface(track: call.localVideo)
                        .frame(width: 104, height: 148)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1))
                        .opacity(call.cameraOff ? 0.12 : 1)
                        .padding(.trailing, 16)
                        .padding(.bottom, 150)
                }
            }
        }
    }

    /* ---------------------------------------------------------- 文字 */

    private var statusText: String {
        switch call.phase {
        case .incoming:   return call.isVideo ? "邀请你视频通话…" : "邀请你语音通话…"
        case .outgoing:   return "正在等待对方接受邀请…"
        case .connecting: return "正在接通…"
        case .active:     return timeText
        case .idle:       return ""
        }
    }

    /// 参考图里"暂时无法接通，建议稍后尝试…"那一行：只在有话说的时候显示
    private var hintText: String {
        let t = call.tip
        if call.phase == .idle { return "" }
        if t == "未接听" || t == "对方已拒绝" || t == "对方不在线" { return t + "，建议稍后尝试" }
        if t.contains("失败") || t.contains("断开") { return t }
        return ""
    }

    private var timeText: String {
        String(format: "%02d:%02d", call.seconds / 60, call.seconds % 60)
    }

    /* ---------------------------------------------------------- 底部三个圆按钮 */

    private var bottomBar: some View {
        HStack(spacing: 51) {
            if call.phase == .incoming {
                // 来电：拒接 + 接听
                roundKey(icon: "phone.down.fill", label: "拒绝",
                         bg: Color(hex: 0xFA5151)) { call.reject() }
                roundKey(icon: "phone.fill", label: "接听",
                         bg: Color(hex: 0x07C160)) { call.accept() }
            } else {
                roundKey(icon: call.muted ? "mic.slash.fill" : "mic.fill",
                         label: call.muted ? "麦克风已关" : "麦克风已开",
                         bg: Color.white.opacity(call.muted ? 0.34 : 0.18)) { call.toggleMute() }
                roundKey(icon: "phone.down.fill", label: call.phase == .active ? "挂断" : "取消",
                         bg: Color(hex: 0xFA5151)) { call.hangup() }
                roundKey(icon: call.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                         label: call.speakerOn ? "扬声器已开" : "扬声器已关",
                         bg: Color.white.opacity(call.speakerOn ? 0.34 : 0.18)) { call.toggleSpeaker() }
            }
        }
        .padding(.bottom, 54)
    }

    private func roundKey(icon: String, label: String, bg: Color,
                          action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(bg))
            }
            .buttonStyle(.plain)
            Text(label)
                .font(pfExact(14))
                .foregroundColor(.white.opacity(0.92))
        }
    }
}

/* ---------------------------------------------------------- 视频画面 */

/// 把 WebRTC 的画面接到 SwiftUI 里（Metal 渲染，省电、延迟低）
struct VideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?

    final class Holder {
        var attached: RTCVideoTrack?
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView()
        v.videoContentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.attached === track { return }
        context.coordinator.attached?.remove(view)
        context.coordinator.attached = track
        track?.add(view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Holder) {
        coordinator.attached?.remove(view)
    }
}
