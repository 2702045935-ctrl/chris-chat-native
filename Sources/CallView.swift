import SwiftUI
import WebRTC

/* ============================================================
   通话界面（来电 / 呼叫中 / 通话中，语音和视频两套）
   挂在 App 最外层，所以不管在哪一页来电都能立刻弹出来。
   ============================================================ */

struct CallOverlay: View {
    @ObservedObject private var call = CallCenter.shared

    var body: some View {
        if call.phase != .idle {
            CallView()
                .transition(.opacity)
                .zIndex(999)
        }
    }
}

struct CallView: View {
    @ObservedObject private var call = CallCenter.shared
    @EnvironmentObject var app: AppState

    private var dark: Color { Color(red: 0.11, green: 0.11, blue: 0.12) }
    /* 通话页背景：毛玻璃。
       之前写成「85% 黑压上去」，出来就是纯黑；现在是
         ① 磨砂层（把背后的界面糊掉）—— callGlassAlpha 控制它的不透明度，默认 0.85
         ② 一层很淡的暗色（保证白字看得清）—— callGlassTint 控制，默认 0.30
       两个值都能在后台 ui.json 里调：越小越透，越大越暗。 */
    private var glassAlpha: CGFloat { UIConfig.num("callGlassAlpha", 0.85) }
    private var glassTint: CGFloat { UIConfig.num("callGlassTint", 0.45) }

    private var glassBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .opacity(glassAlpha)
            Color.black.opacity(glassTint)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        ZStack {
            glassBackground

            if call.isVideo && call.phase == .active {
                // 视频通话：远端铺满，本地小窗右下角
                ZStack {
                    VideoSurface(track: call.remoteVideo)
                        .ignoresSafeArea()
                    if call.remoteVideo == nil {
                        VStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("正在连接画面…").foregroundColor(.white.opacity(0.7)).font(pf(14))
                        }
                    }
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            VideoSurface(track: call.localVideo)
                                .frame(width: 110, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 1))
                                .opacity(call.cameraOff ? 0.15 : 1)
                                .padding(.trailing, 16)
                                .padding(.bottom, 172)
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    Spacer().frame(height: 80)
                    Avatar(path: call.peerAvatar, size: 96, radius: 14)
                    Text(call.peerName)
                        .font(pf(22, .medium))
                        .foregroundColor(.white)
                        .padding(.top, 18)
                    Text(statusText)
                        .font(pf(15))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.top, 8)
                    Spacer()
                }
            }

            VStack {
                Text(call.peerName)
                    .font(pf(17, .medium))
                    .foregroundColor(.white)
                    .padding(.top, 8)
                    .opacity(call.isVideo && call.phase == .active ? 1 : 0)
                Spacer()
                bottomBar
            }
        }
    }

    private var statusText: String {
        switch call.phase {
        case .incoming:  return call.isVideo ? "邀请你视频通话…" : "邀请你语音通话…"
        case .outgoing:  return call.tip.isEmpty ? "正在呼叫…" : call.tip
        case .connecting: return "正在接通…"
        case .active:    return timeText
        case .idle:      return ""
        }
    }

    private var timeText: String {
        let m = call.seconds / 60
        let s = call.seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    /* ---------------------------------------------------------- 底部按键 */

    private var bottomBar: some View {
        VStack(spacing: 26) {
            if call.phase == .active || call.phase == .connecting {
                HStack(spacing: 34) {
                    roundButton(icon: call.muted ? "mic.slash.fill" : "mic.fill",
                                label: call.muted ? "已静音" : "静音",
                                on: call.muted) { call.toggleMute() }
                    if call.isVideo {
                        roundButton(icon: call.cameraOff ? "video.slash.fill" : "video.fill",
                                    label: call.cameraOff ? "已关摄像头" : "摄像头",
                                    on: call.cameraOff) { call.toggleCamera() }
                        roundButton(icon: "arrow.triangle.2.circlepath.camera",
                                    label: "翻转", on: false) { call.flipCamera() }
                    }
                }
            }

            HStack(spacing: 90) {
                if call.phase == .incoming {
                    // 拒接
                    bigButton(color: Color(hex: 0xFA5151), icon: "phone.down.fill") { call.reject() }
                    bigButton(color: Color(hex: 0x07C160), icon: "phone.fill") { call.accept() }
                } else {
                    bigButton(color: Color(hex: 0xFA5151),
                              icon: call.phase == .outgoing ? "phone.down.fill" : "phone.down.fill") { call.hangup() }
                }
            }
            Text(call.phase == .incoming ? "滑动接听 · 点红键拒接" : "点红键结束")
                .font(pf(12))
                .foregroundColor(.white.opacity(0.45))
                .opacity(call.phase == .incoming ? 1 : 0)
            Spacer().frame(height: 24)
        }
    }

    private func roundButton(icon: String, label: String, on: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(on ? Color.white.opacity(0.9) : Color.white.opacity(0.16)))
                    .foregroundColor(on ? .black : .white)
            }
            .buttonStyle(.plain)
            Text(label).font(pf(12)).foregroundColor(.white.opacity(0.7))
        }
    }

    private func bigButton(color: Color, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(color))
        }
        .buttonStyle(.plain)
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
