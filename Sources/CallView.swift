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

/// 接通 / 挂断弹的对话框：居中的卡片 + 「确定」，颜色/圆角取后台那套
/// （和聊天页那行时间同一个配置：底色 chatTimeBg、文字色 chatTimeColor、圆角 chatTimeRadius），
/// 所以看着就是「聊天的框框」。通话页收起来以后它还在，所以挂断也一定看得到。
struct CallDialogOverlay: View {
    @ObservedObject private var call = CallCenter.shared

    var body: some View {
        ZStack {
            if let d = call.dialog {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { call.dismissDialog() }

                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        Text(d.title)
                            .font(pf(16, .medium))
                            .foregroundColor(C.chatTimeInk)
                            .multilineTextAlignment(.center)
                        if !d.detail.isEmpty {
                            Text(d.detail)
                                .font(pf(13))
                                .foregroundColor(C.chatTimeInk.opacity(0.75))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 18)

                    Rectangle()
                        .fill(C.chatTimeInk.opacity(0.18))
                        .frame(height: 0.5)

                    Button {
                        call.dismissDialog()
                    } label: {
                        Text(d.okText)
                            .font(pf(16, .medium))
                            .foregroundColor(C.chatTimeInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 268)
                .background(
                    RoundedRectangle(cornerRadius: max(12, L.o("chatTimeRadius", 4) + 8), style: .continuous)
                        .fill(C.chatTimeBg)
                )
                .transition(.scale(scale: 0.94).combined(with: .opacity))
                .zIndex(1000)
            }
        }
        .zIndex(1000)
        .animation(.easeOut(duration: 0.16), value: call.dialog)
    }
}

struct CallView: View {
    @ObservedObject private var call = CallCenter.shared
    @EnvironmentObject var app: AppState
    @State private var showInvite = false
    /// 最小化小窗的位置（nil = 默认贴右上角；拖过之后记住位置，松手会吸附到左右边）
    @State private var miniX: CGFloat? = nil
    @State private var miniY: CGFloat? = nil
    @State private var dragging: CGSize = .zero

    private var blurRadius: CGFloat { UIConfig.num("callBackdropBlur", 60) }
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

            if call.minimized {
                miniWindow
            } else {
                if call.isVideo && call.phase == .active {
                    videoLayer
                } else {
                    avatarLayer
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
            }
        }
        .sheet(isPresented: $showInvite) {
            inviteSheet
        }
    }

    /* ---------------------------------------------------------- 背景 */

    private var backdrop: some View {
        ZStack {
            Color(red: 0.10, green: 0.11, blue: 0.10)
            /* 和微信一样：糊的是「对方的头像」那张图（放大糊狠一点），
               所以背景会带出这个人头像的色调。对方没头像才退回聊天背景图。 */
            if !call.peerAvatar.isEmpty {
                RemoteImage(path: call.peerAvatar)
                    .blur(radius: blurRadius)
                    .scaleEffect(1.35)
            } else if !bgPath.isEmpty {
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
                .opacity(call.phase == .outgoing ? 0 : 1)
            if call.phase == .outgoing {
                /* 打不通就别再滚「正在等待…」了，直接把原因写在屏幕上
                   （服务器回了不在线/忙线以后，通话页会停 8 秒让用户看清） */
                if let err = call.errorText, !err.isEmpty {
                    Text(err)
                        .font(pfExact(15, .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 6)
                } else {
                    // 等对方接的时候：状态文字像滚动屏一样滚（同时放回铃音）
                    MarqueeText(text: "正在等待对方接受邀请…")
                        .padding(.top, 6)
                }
            }
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
                    Text(Tr("正在连接画面…"))
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
                roundKey(label: "拒绝", bg: Color(hex: 0xFA5151)) { call.reject() }
                roundKey(label: "接听", bg: Color(hex: 0x07C160), ink: .white,
                         action: { call.accept() }) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 27, weight: .medium))
                }
            } else {
                roundKey(key: call.muted ? "ui.callMicOff" : "ui.callMic",
                         symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                         builtin: call.muted ? I.callMicOff : I.callMic,
                         label: call.muted ? "麦克风已关" : "麦克风已开",
                         engaged: call.muted) { call.toggleMute() }
                roundKey(label: call.phase == .active ? "挂断" : "取消",
                         bg: Color(hex: 0xFA5151)) { call.hangup() }
                roundKey(key: call.speakerOn ? "ui.callSpeaker" : "ui.callSpeakerOff",
                         symbol: call.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                         builtin: call.speakerOn ? I.callSpeaker : I.callSpeakerOff,
                         label: call.speakerOn ? "扬声器已开" : "扬声器已关",
                         engaged: call.speakerOn) { call.toggleSpeaker() }
            }
        }
        .padding(.bottom, 54)
    }

    /// 左右两颗（麦克风 / 扬声器）：打开时**变白底 + 深色图标**（和微信一样），
    /// 关着的时候是半透明黑底 + 白色图标。图标本身后台「UI 图标」里能换。
    private func roundKey(key: String, symbol: String, builtin: String,
                          label: String, engaged: Bool,
                          action: @escaping () -> Void) -> some View {
        let ink: Color = engaged ? .black : .white
        return
        roundKey(label: label,
                 bg: engaged ? Color.white : Color.white.opacity(0.18),
                 ink: ink,
                 action: action) {
            CallIcon(key: key, symbol: symbol, builtin: builtin, size: 30, color: ink)
        }
    }

    /// 挂断/取消那颗：图标是微信那种宽横梁（SF Symbols 里没有一样的，自己画）
    private func roundKey(label: String, bg: Color,
                          action: @escaping () -> Void) -> some View {
        roundKey(label: label, bg: bg, ink: .white, action: action) {
            CallIcon(key: "ui.callHangup", symbol: "phone.down.fill", builtin: I.callHangup, size: 72)
        }
    }

    private func roundKey<Icon: View>(label: String, bg: Color, ink: Color,
                                      action: @escaping () -> Void,
                                      @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 14) {
            Button(action: action) {
                icon()
                    .foregroundColor(ink)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(bg))
            }
            .buttonStyle(.plain)
            Text(label)
                .font(pfExact(14))
                .foregroundColor(.white.opacity(0.92))
        }
    }

    /* ---------------------------------------------------------- 顶部两个按钮（照参考图） */

    /// 参考图实测：左上那个「画中画/最小化」在 x29-47 y79-97；右上「+」在 x384-400 y78-94
    private var topBar: some View {
        HStack {
            Button {
                call.minimize()
            } label: {
                CallIcon(key: "ui.callMinimize", symbol: "rectangle.inset.bottomright.filled",
                         builtin: I.callMinimize, size: 20)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)

            Spacer()

            Button {
                showInvite = true
            } label: {
                CallIcon(key: "ui.callAdd", symbol: "plus", builtin: I.callAdd, size: 17)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .padding(.top, 19)
    }

    /// 最小化后的样子：**右上角一个小浮窗**（和微信一样）——
    /// 视频通话显示远端画面，语音通话显示头像+名字+计时；点一下回到通话界面，
    /// 右上角那个小 ✕ 可以直接挂断。通话本身一直在继续，不受影响。
    /// 可以拖着走，松手吸附到左右边（微信就是这样）。
    private var miniWindow: some View {
        GeometryReader { geo in
            let w: CGFloat = call.isVideo ? 108 : 146
            let h: CGFloat = call.isVideo ? 144 : 48
            let maxX = max(8, geo.size.width - w - 8)
            let maxY = max(6, geo.size.height - h - 90)
            let homeX = geo.size.width - w - 10
            let x = min(max((miniX ?? homeX) + dragging.width, 8), maxX)
            let y = min(max((miniY ?? 6) + dragging.height, 6), maxY)
            windowBody(w: w, h: h)
                .position(x: x + w / 2, y: y + h / 2)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in dragging = v.translation }
                        .onEnded { v in
                            let nx = (miniX ?? homeX) + v.translation.width
                            let ny = (miniY ?? 6) + v.translation.height
                            // 松手吸附：靠近哪边就贴哪边（微信那种手感）
                            miniX = nx + w / 2 < geo.size.width / 2 ? 8 : maxX
                            miniY = min(max(ny, 6), maxY)
                            dragging = .zero
                        }
                )
        }
    }

    private func windowBody(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
                    Group {
                        if call.isVideo {
                            ZStack {
                                VideoSurface(track: call.remoteVideo)
                                if call.remoteVideo == nil {
                                    Avatar(path: call.peerAvatar, size: 44, radius: 8)
                                }
                            }
                        } else {
                            HStack(spacing: 9) {
                                Avatar(path: call.peerAvatar, size: 28, radius: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(call.peerName)
                                        .font(pfExact(13, .medium))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(call.phase == .active ? timeText : (call.tip.isEmpty ? "通话中" : call.tip))
                                        .font(pfExact(11))
                                        .foregroundColor(.white.opacity(0.72))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .background(Color(hex: 0x07C160))
                        }
                    }
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                    .contentShape(Rectangle())
                    .onTapGesture { call.restore() }

                    Button {
                        call.hangup()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }

    /// （旧版：一条横条。留着备用，不再使用）
    private var miniBarOld: some View {
        HStack(spacing: 8) {
            Circle().fill(C.green).frame(width: 8, height: 8)
            Text(call.phase == .active ? "通话中 \(timeText)" : call.tip)
                .font(pfExact(14))
                .foregroundColor(.white)
            Spacer(minLength: 0)
            Button {
                call.restore()
            } label: {
                Text(Tr("回到通话")).font(pfExact(14)).foregroundColor(Color(hex: 0x07C160))
            }
            .buttonStyle(.plain)
            Button {
                call.hangup()
            } label: {
                CallIcon(key: "ui.callHangup", symbol: "phone.down.fill", builtin: I.callHangup, size: 24)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /* ---------------------------------------------------------- 邀请好友（右上 +） */

    private var inviteSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.contacts) { u in
                        Button {
                            showInvite = false
                            let name = u.nickname ?? u.username ?? "好友"
                            Task {
                                let msg = await call.invite(userId: u.id, name: name)
                                app.show(msg)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Avatar(path: u.avatar ?? "", size: 36, radius: 6)
                                Text(u.nickname ?? u.username ?? "好友").foregroundColor(C.label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(Tr("邀请好友加入通话"))
                } footer: {
                    Text(Tr("对方会收到一条邀请消息；多人同时在同一个通话里（会议模式）还在做，先保证人能叫到。"))
                }
            }
            .navigationTitle(Tr("添加通话"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 微信「挂断 / 取消」那个图标：一条略带弧度的宽横梁，两头向下收，宽高比约 4:1。
/// 参考图实测 67×16pt（在 72pt 的圆里几乎占满宽度）。
struct HangUpIcon: View {
    var width: CGFloat = 66
    var body: some View {
        let h = width * 0.25
        let s = width / 66
        return Path { p in
            p.move(to: CGPoint(x: 3 * s, y: 5.4 * s))
            p.addQuadCurve(to: CGPoint(x: 63 * s, y: 5.4 * s),
                           control: CGPoint(x: 33 * s, y: 0.4 * s))       // 上沿：中间略高
            p.addLine(to: CGPoint(x: 63 * s, y: 9.2 * s))
            p.addQuadCurve(to: CGPoint(x: 43 * s, y: 13.2 * s),
                           control: CGPoint(x: 53 * s, y: 13.4 * s))      // 右腿向下收
            p.addLine(to: CGPoint(x: 23 * s, y: 13.2 * s))
            p.addQuadCurve(to: CGPoint(x: 3 * s, y: 9.2 * s),
                           control: CGPoint(x: 13 * s, y: 13.4 * s))      // 左腿向下收
            p.closeSubpath()
        }
        .fill(Color.white)
        .frame(width: width, height: max(8, h))
    }
}

/// 左上「最小化」：画中画图标（一个大圆角方框，右下角套一个小方框）
struct PipIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let line = max(1.4, w * 0.09)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .stroke(Color.white, lineWidth: line)
                    .frame(width: w * 0.86, height: h * 0.86)
                RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                        .stroke(Color.white, lineWidth: line))
                    .frame(width: w * 0.52, height: h * 0.40)
                    .offset(x: w * 0.48, y: h * 0.60)
            }
        }
    }
}

/// 右上「+」：两根线交叉（参考图实测横竖各 16pt，线宽约 1.8）
struct PlusIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Path { p in
                p.move(to: CGPoint(x: 0, y: w / 2))
                p.addLine(to: CGPoint(x: w, y: w / 2))
                p.move(to: CGPoint(x: w / 2, y: 0))
                p.addLine(to: CGPoint(x: w / 2, y: w))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.6, w * 0.11), lineCap: .round))
        }
    }
}

/// 通话页的图标：后台「UI 图标」里配过（ui.callMinimize / ui.callAdd / ui.callMic /
/// ui.callMicOff / ui.callSpeaker / ui.callSpeakerOff / ui.callHangup）就用配的，
/// 可以传 SVG、图片地址（上传的图）或者 emoji；没配就用内置的。
struct CallIcon: View {
    let key: String
    var symbol: String = "circle"
    var builtin: String? = nil
    var size: CGFloat = 24
    var color: Color = .white

    var body: some View {
        if let v = IconOverrides.custom(key), !v.isEmpty {
            if v.hasPrefix("<svg") {
                SVGIcon(markup: v, size: size, color: color)
            } else if v.hasPrefix("http") || v.hasPrefix("/uploads") || v.hasPrefix("data:") {
                RemoteImage(path: v).frame(width: size, height: size)
            } else {
                Text(v)
                    .font(.system(size: size * 0.9))
                    .foregroundColor(color)
                    .frame(width: size, height: size)
            }
        } else if let b = builtin {
            SVGIcon(markup: b, size: size, color: color)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.9, weight: .medium))
                .foregroundColor(color)
                .frame(width: size, height: size)
        }
    }
}

/// 「滚动屏」：文字从右边缘慢慢滚到左边，循环滚（等对方接的时候用）
struct MarqueeText: View {
    let text: String
    var size: CGFloat = 15
    var duration: Double = 7
    @State private var x: CGFloat = 0
    @State private var ready = false

    var body: some View {
        GeometryReader { geo in
            Text(text)
                .font(pfExact(size))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize()
                .offset(x: x)
                .onAppear {
                    guard !ready else { return }
                    ready = true
                    x = geo.size.width
                    withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                        x = -geo.size.width
                    }
                }
        }
        .frame(height: size + 6)
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
