import SwiftUI
import UniformTypeIdentifiers

/// 微信气泡：圆角 6 + 左上/右上那个 5px 小尖角
struct BubbleShape: Shape {
    let mine: Bool
    var radius: CGFloat = 6
    var tail: Bool = true

    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: radius)
        guard tail else { return p }
        var t = Path()
        if mine {
            t.move(to: CGPoint(x: rect.maxX + 4, y: rect.minY + 11))
            t.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 16))
            t.addLine(to: CGPoint(x: rect.maxX + 4, y: rect.minY + 21))
        } else {
            t.move(to: CGPoint(x: rect.minX - 4, y: rect.minY + 11))
            t.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 16))
            t.addLine(to: CGPoint(x: rect.minX - 4, y: rect.minY + 21))
        }
        t.closeSubpath()
        p.addPath(t)
        return p
    }
}

enum PanelKind { case none, emoji, plus, gift }

struct ChatDetailView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var loading = true
    @State private var panel: PanelKind = .none
    @State private var plusItems: [PlusItem] = []
    @State private var gifts: [Gift] = []

    @State private var showPhoto = false
    @State private var showCamera = false
    @State private var showLocation = false
    @State private var showTransfer = false
    @State private var showChatMenu = false
    @State private var showFile = false
    @State private var showCall = false
    @State private var billInfo: TransferInfo?
    @State private var uploading = false
    /// 点开聊天里的图片：paths = 这个会话里所有图片，index = 点的那张
    @State private var viewer: PhotoPager.Item?
    /// 点头像 → 名片（自己的头像是自己的名片）
    @State private var cardUser: User?

    @FocusState private var focused: Bool
    @ObservedObject private var realtime = Realtime.shared
    @ObservedObject private var recorder = VoiceRecorder.shared
    @State private var pushTask: Task<Void, Never>?
    /// 左上角返回箭头旁边那个未读数字（微信同位置）
    @State private var unreadHere = 0
    /// 点一下那个数字 = 滚回最新消息
    @State private var scrollTick = 0

    private var myId: String { app.me?.id ?? "" }
    private var isGroup: Bool { chat.type == "group" }

    /// 一对一会话里的对方 id（真人语音/视频通话要用它去呼叫）
    private var peerUserId: String? {
        guard let ids = chat.memberIds else { return nil }
        return ids.first(where: { $0 != myId })
    }

    /// 这通电话是不是就跟当前这个会话的人在打（是的话聊天页顶部挂提示条）
    private var callActiveHere: Bool {
        let c = CallCenter.shared
        guard c.phase.isBusy, let peer = peerUserId else { return false }
        return c.peerId == peer
    }

    private var callBarText: String {
        let c = CallCenter.shared
        switch c.phase {
        case .incoming:   return c.isVideo ? "邀请你视频通话" : "邀请你语音通话"
        case .outgoing:   return c.isVideo ? "正在等待对方接受视频通话" : "正在等待对方接受语音通话"
        case .connecting: return "正在接通…"
        case .active:     return c.isVideo ? "正在视频通话中" : "正在语音通话中"
        case .idle:       return ""
        }
    }

    /// 打给真人（WebRTC）：语音或视频
    private func startRealCall(video: Bool) {
        guard !isGroup else { app.show("群聊通话还没做，先在单聊里打"); return }
        guard let peer = peerUserId else { app.show("找不到对方账号，先刷新一下会话"); return }
        if CallCenter.shared.phase != .idle { app.show("正在通话中"); return }
        CallCenter.shared.start(peerId: peer, name: chat.name, avatar: chat.avatar ?? "", video: video)
    }

    private func displayName(_ message: Message) -> String {
        if let n = message.senderName, !n.isEmpty { return n }
        return app.contact(for: message.senderId ?? "")?.name ?? ""
    }

    private var backgroundPath: String {
        let v = app.me?.chatBackground ?? "auto"
        if v.isEmpty || v == "auto" {
            // 自己没设就用服务器上配的默认背景（和网页版一致），都没有才留空白
            let def = app.defaultChatBackground
            return (def == "auto") ? "" : def
        }
        return v
    }

    var body: some View {
        ZStack {
            /* 聊天区铺满整屏（含顶栏、输入栏下面那两块），
               顶栏和输入栏用 iOS 原生超薄毛玻璃浮在上面，
               所以消息滚到上面/下面的时候会透过玻璃看到 —— 就是微信那种质感 */
            messageList
                // 点一下（哪怕是空白处）：表情/＋ 面板收回去，打字键盘也收起来
                // 再叠一层：手一滑动也收（微信就是这样）
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissTyping() })
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in dismissTyping() })
                .background {
                    ZStack {
                        C.pageBg
                        if !backgroundPath.isEmpty {
                            RemoteImage(path: backgroundPath)
                                .id(backgroundPath)     // 换聊天背景立刻生效
                        }
                    }
                    .ignoresSafeArea()
                    /* 背景图是异步加载的：不加这一句，图片一到就会跟着「推进来」那段
                       导航动画一起缩一下（打开聊天页那种缩放感就是这么来的）。 */
                    .transaction { $0.animation = nil }
                }

            if uploading {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView("正在上传…")
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.cardBg))
                }
            }

            /* 按住说话时中间那个浮层：麦克风 + 音量条 + 提示 */
            if recorder.recording {
                VoiceHUD(seconds: recorder.seconds, level: recorder.level, willCancel: recorder.willCancel)
                    .zIndex(50)
            }

        }
        /* 顶栏：超薄毛玻璃（浅色模式下就是 iOS 那种浅浅的磨砂），背景图/消息从底下透过去 */
        .safeAreaInset(edge: .top, spacing: 0) {
            NavBar(title: chat.name, back: { dismiss() }, leftExtra: leftUnreadBadge) {
                Button {
                    showChatMenu = true
                } label: {
                    Text("⋯")
                        .font(pf(22))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
            }
            .background {
                /* 超薄毛玻璃 + 一层白（深色模式换成深灰）：
                   之前太透了，压一层白以后就是 iOS 那种「奶白磨砂」的观感 */
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    // 压白程度跟着后台「聊天页毛玻璃不透明度」走（0.5 起步，越大小越透）
                    Color.dyn(0xFFFFFF, 0x1C1C1E)
                        .opacity(max(0, min(0.5, UIConfig.num("glassAlpha", 0.8) - 0.5)))
                }
                .ignoresSafeArea(edges: .top)
            }

            /* 通话中：顶栏下面挂一条绿提示，点一下回到通话界面（微信就是这样） */
            if callActiveHere {
                Button {
                    CallCenter.shared.restore()
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Color.white.opacity(0.92)).frame(width: 7, height: 7)
                        Text(callBarText)
                            .font(pf(13.5))
                            .foregroundColor(.white)
                        Spacer(minLength: 0)
                        Text("回到通话 ›")
                            .font(pf(13.5))
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(C.green)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        /* 右上「⋯」：真人聊天可以直接打语音/视频（机器人还是走 AI 通话） */
        .confirmationDialog("聊天", isPresented: $showChatMenu, titleVisibility: .hidden) {
            if (chat.botRank ?? 9) < 9 {
                Button("语音通话") { showCall = true }
                Button("视频通话") { showCall = true }
            } else {
                Button("语音通话") { startRealCall(video: false) }
                Button("视频通话") { startRealCall(video: true) }
            }
            Button("聊天背景") { app.show("换聊天背景：点「我 → 设置 → 聊天背景」") }
            Button("刷新消息") { Task { await load(initial: true) } }
            Button("取消", role: .cancel) { }
        }
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPhoto) {
            PhotoPicker { image in sendImage(image) }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in sendImage(image) }
        }
        .sheet(isPresented: $showLocation) {
            LocationSheet { payload in send(kind: "location", content: payload) }
        }
        .sheet(isPresented: $showTransfer) {
            /* 用「照网页版一条条量出来」的那套转账页（TransferView）：
               转账页 + 支付面板 + 付款方式面板 + 结果页，颜色/尺寸和网页版一致 */
            TransferView(chat: chat)
        }
        .fullScreenCover(isPresented: $showCall) {
            AICallView(chat: chat)
        }
        .fullScreenCover(item: $viewer) { item in
            PhotoPager(paths: item.paths, startIndex: item.index) { viewer = nil }
        }
        .modifier(TapAvatarCard(cardUser: $cardUser))
        .hidesTabBar()
        .sheet(isPresented: Binding(
            get: { billInfo != nil },
            set: { if !$0 { billInfo = nil } }
        )) {
            if let info = billInfo {
                BillDetailView(chat: chat, info: info)
            }
        }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { sendFile(url) }
        }
        .task(id: chat.id) {
            await load(initial: true)
            await API.shared.markRead(chatId: chat.id)
            await app.loadChats()
            if plusItems.isEmpty { plusItems = (try? await API.shared.plusPanel()) ?? [] }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                await load(initial: false)
            }
        }
        // 服务器一推消息，立刻拉一次（不用等轮询）
        .onChange(of: realtime.event) { _ in
            // 一下子来很多条时合并成一次刷新，别把手机刷爆
            pushTask?.cancel()
            pushTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                await load(initial: false)
            }
        }
    }

    /* ---------------------------------------------------------- 消息列表 */

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(messages) { message in
                        VStack(spacing: 0) {
                            if showTime(for: message) {
                                Text(TimeFmt.bubble(message.createdAt))
                                    .font(pf(L.msgTimeSize))
                                    .foregroundColor(C.chatTimeInk)
                                    /* 时间加一个明显的圆角小框（和微信一样；颜色/圆角后台能调，只作用于聊天页） */
                                    .padding(.horizontal, L.o("chatTimePadX", 8))
                                    .padding(.vertical, L.o("chatTimePadY", 3))
                                    .background(RoundedRectangle(cornerRadius: L.o("chatTimeRadius", 4), style: .continuous)
                                        .fill(C.chatTimeBg))
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 12)
                                    .padding(.bottom, 16)
                            }
                            /* 系统消息（通话记录、撤回提示这种）：微信是居中一行灰字，没有头像和气泡 */
                            if message.kindName == "system" {
                                SystemLine(message: message)
                                    .padding(.bottom, 15)
                            } else {
                            MessageRow(message: message,
                                       mine: message.senderId == myId,
                                       senderName: (!isGroup || message.senderId == myId)
                                           ? "" : displayName(message),
                                       onTapTransfer: { info in billInfo = info },
                                       onOpenImage: { path in openImage(path) },
                                       onOpenAvatar: { id in openAvatar(id) })
                                .padding(.bottom, 15)
                                .contextMenu {
                                    if message.senderId == myId {
                                        Button(role: .destructive) {
                                            recall(message)
                                        } label: {
                                            Label("撤回", systemImage: "arrow.uturn.backward")
                                        }
                                    }
                                    Button {
                                        UIPasteboard.general.string = message.body
                                        app.show("已复制")
                                    } label: {
                                        Label("复制", systemImage: "doc.on.doc")
                                    }
                                    Button(role: .destructive) {
                                        report(message)
                                    } label: {
                                        Label("举报", systemImage: "exclamationmark.bubble")
                                    }
                                }
                            }
                        }
                        .id(message.id)
                    }
                    if loading && messages.isEmpty {
                        ProgressView().padding(.top, 40)
                    }
                }
                .padding(L.msgPad)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in scrollToEnd(proxy, animated: true) }
            .onChange(of: scrollTick) { _ in scrollToEnd(proxy, animated: true) }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    /* 左上角「返回箭头」旁边那个未读数字：和微信一样的位置。
       进聊天页先带上会话原来的未读数，之后每多收到一条别人的消息就 +1；
       点一下这个数字 = 当作看完，数字清零并滚回最新一条。 */
    private var leftUnreadBadge: AnyView? {
        guard unreadHere > 0 else { return nil }
        return AnyView(
            Button {
                unreadHere = 0
                scrollTick += 1
            } label: {
                Text(unreadHere > 99 ? "99+" : "\(unreadHere)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Capsule().fill(C.red))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        )
    }

    private func showTime(for message: Message) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return false }
        if index == 0 { return true }
        return TimeFmt.minutesBetween(messages[index - 1].createdAt, message.createdAt) >= 5
    }

    /* ---------------------------------------------------------- 输入栏 */

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    /* 点一下：提示"按住说话"（真正的录音在下面的长按手势里） */
                    app.show("按住左边的麦克风说话，松开发送，上滑取消")
                } label: {
                    SVGIcon(markup: I.voice, size: L.composerIcon,
                            color: recorder.recording ? C.green : C.chatBarIcon)
                        .frame(width: L.composerIconBox, height: L.composerIconBox)
                }
                .buttonStyle(.plain)
                /* 按住说话：按住开始录，松开发送，上滑取消 */
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !recorder.recording {
                                focused = false
                                panel = .none
                                Task { _ = await recorder.begin() }
                            }
                            recorder.drag(v.translation.height)
                        }
                        .onEnded { _ in finishVoice() }
                )

                HStack(spacing: 0) {
                    TextField("", text: $input)
                        .focused($focused)
                        .font(pf(17))
                        .foregroundColor(C.label)
                        .onTapGesture { panel = .none }
                    SVGIcon(markup: I.speaker, size: 22, color: C.chatBarIcon)
                        .padding(.leading, 6)
                }
                .padding(.horizontal, 8)
                .frame(height: L.inputH)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dyn(0xFFFFFF, 0x2C2C2E)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.dyn(0xE8E8E8, 0x3A3A3C), lineWidth: 0.5)
                )

                if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        focused = false
                        panel = (panel == .emoji) ? .none : .emoji
                    } label: {
                        SVGIcon(markup: I.smile, size: L.composerIcon, color: C.chatBarIcon)
                            .frame(width: L.composerIconBox, height: L.composerIconBox)
                    }
                    .buttonStyle(.plain)

                    Button {
                        focused = false
                        panel = (panel == .plus) ? .none : .plus
                        if panel == .plus && plusItems.isEmpty {
                            Task { plusItems = (try? await API.shared.plusPanel()) ?? [] }
                        }
                    } label: {
                        SVGIcon(markup: I.plusCircle, size: L.composerIcon, color: C.chatBarIcon)
                            .frame(width: L.composerIconBox, height: L.composerIconBox)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        sendText()
                    } label: {
                        Text("发送")
                            .font(pf(16, .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 11)
            .padding(.vertical, 8)

            panelView
                /* 表情 / ＋ / 礼物面板还是实心底（和微信一样），不跟着玻璃一起透 */
                .background(panel == .none ? Color.clear : C.tabBg)
        }
        /* 输入栏：和顶栏同一套超薄毛玻璃 + 一层白；上面压一条 0.5px 细线做分隔（微信也有） */
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.dyn(0xFFFFFF, 0x1C1C1E)
                    .opacity(max(0, min(0.5, UIConfig.num("glassAlpha", 0.8) - 0.5)))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(C.navLine).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var panelView: some View {
        switch panel {
        case .emoji:
            EmojiPanel(draft: $input,
                       onSend: { sendText(); panel = .none },
                       onDelete: { if !input.isEmpty { input.removeLast() } })
        case .plus:
            PlusPanel(items: plusItems) { item in handlePlus(item) }
        case .gift:
            GiftPanel(gifts: gifts) { gift in
                let payload = "{\"id\":\"\(gift.id)\",\"name\":\"\(gift.name ?? "礼物")\",\"icon\":\"\(gift.icon ?? "🎁")\",\"price\":\(Int(gift.price ?? 0))}"
                send(kind: "gift", content: payload)
                panel = .none
            }
        case .none:
            EmptyView()
        }
    }

    /* ---------------------------------------------------------- 各个动作 */

    private func handlePlus(_ item: PlusItem) {
        switch item.action ?? "none" {
        case "photo":
            panel = .none
            showPhoto = true
        case "camera":
            panel = .none
            showCamera = true
        case "location":
            panel = .none
            showLocation = true
        case "gift":
            panel = .gift
            if gifts.isEmpty { Task { gifts = (try? await API.shared.gifts()) ?? [] } }
        case "transfer":
            panel = .none
            showTransfer = true
        case "file":
            panel = .none
            showFile = true
        case "videocall":
            panel = .none
            if (chat.botRank ?? 9) < 9 {
                showCall = true                       // 机器人：走 AI 通话
            } else {
                startRealCall(video: true)            // 真人：真·视频通话（WebRTC）
            }
        case "voice":
            panel = .none
            app.show("按住输入框左边的麦克风说话：松开发送，上滑取消")
        case "redpacket":
            panel = .none
            send(kind: "text", content: "🧧 恭喜发财，大吉大利")
        case "favorite":
            panel = .none
            app.show("收藏夹还是空的")
        case "card":
            panel = .none
            app.show("名片：去「通讯录」点头像即可发送")
        default:
            app.show("\(item.label ?? "")排在下一批")
        }
    }

    /// 收起打字键盘 / 表情面板（点聊天区域、或者滑动聊天区域时调用）
    private func dismissTyping() {
        if panel != .none { panel = .none }
        if focused { focused = false }
    }

    private func sendText() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        input = ""
        send(kind: "text", content: text)
    }

    /// 点聊天里的图片：把那一条所在的整个会话的图片都收进去，可以左右翻
    private func openImage(_ path: String) {
        let all = messages.filter { $0.kindName == "image" && !$0.isRecalled }.map { $0.body }
        guard !all.isEmpty else { return }
        viewer = PhotoPager.Item(paths: all, index: all.firstIndex(of: path) ?? 0)
    }

    /// 点头像 → 名片。自己的头像是自己的名片；查不到的（陌生人 / 群里的人）现拉一次
    private func openAvatar(_ senderId: String) {
        let id = senderId.isEmpty ? myId : senderId
        if id.isEmpty { return }
        if id == myId, let me = app.me { cardUser = me; return }
        if let u = app.contact(for: id) { cardUser = u; return }
        Task {
            if let u = try? await API.shared.user(id: id) { cardUser = u }
            else { app.show("打不开这个人的名片") }
        }
    }

    private func send(kind: String, content: String) {
        Task {
            do {
                if let message = try await API.shared.send(chatId: chat.id, kind: kind, content: content) {
                    messages.append(message)
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发送失败")
            }
            await app.loadChats()
        }
    }

    private func sendImage(_ image: UIImage) {
        uploading = true
        Task {
            do {
                let url = try await API.shared.upload(image: image)
                if let message = try await API.shared.send(chatId: chat.id, kind: "image", content: url) {
                    messages.append(message)
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "图片发送失败")
            }
            uploading = false
            await app.loadChats()
        }
    }

    /* ---------------------------------------------------------- 按住说话 */

    /// 松手：录到了就发，太短/取消了就啥也不做
    private func finishVoice() {
        guard let got = recorder.end() else { return }
        sendVoice(url: got.url, seconds: got.seconds)
    }

    private func sendVoice(url: URL, seconds: Int) {
        Task {
            uploading = true
            defer { uploading = false }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                app.show("录音读不到，再录一次")
                return
            }
            let payload: [String: Any] = [
                "dataUrl": "data:audio/mp4;base64," + data.base64EncodedString(),
                "filename": "voice.m4a"
            ]
            do {
                let up = try await API.shared.rawUpload(payload)
                let body = "{\"url\":\"\(up.url)\",\"seconds\":\(seconds),\"bytes\":\(data.count)}"
                send(kind: "audio", content: body)
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "语音发送失败")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func sendFile(_ url: URL) {
        let name = url.lastPathComponent
        Task {
            uploading = true
            defer { uploading = false }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                app.show("读不到这个文件")
                return
            }
            let b64 = data.base64EncodedString()
            let payload: [String: Any] = ["dataUrl": "data:application/octet-stream;base64," + b64,
                                          "filename": name]
            do {
                let bytes = try await API.shared.rawUpload(payload)
                let content = "{\"url\":\"\(bytes.url)\",\"name\":\"\(name)\",\"bytes\":\(data.count)}"
                if let message = try await API.shared.send(chatId: chat.id, kind: "file", content: content) {
                    messages.append(message)
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "文件发送失败")
            }
            await app.loadChats()
        }
    }

    private func doTransfer(amount: Double, note: String, method: String, password: String) {
        Task {
            do {
                try await API.shared.transfer(chatId: chat.id, amount: amount, note: note,
                                              method: method, password: password)
                await load(initial: true)
                await app.loadChats()
                app.show("已转账 ¥\(String(format: "%.2f", amount))")
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "转账失败")
            }
        }
    }

    private func recall(_ message: Message) {
        Task {
            await API.shared.recall(chatId: chat.id, messageId: message.id)
            await load(initial: true)
        }
    }

    private func report(_ message: Message) {
        let target = message.senderId ?? ""
        guard !target.isEmpty else { return }
        Task {
            await API.shared.report(userId: target, chatId: chat.id,
                                    reason: "聊天内容举报",
                                    content: String(message.body.prefix(200)))
            app.show("已举报，管理员会处理")
        }
    }

    /* ---------------------------------------------------------- 数据 */

    private func load(initial: Bool) async {
        do {
            let result = try await API.shared.messages(chatId: chat.id, limit: 40)
            /* 不能只看条数和最后一条的 id：对方收款以后转账卡片还是同一条消息，
               只是 body 里的 status 从 pending 变成 received —— 以前这种情况会被
               当成「没变化」跳过，气泡就一直停在「待对方确认收款」。 */
            let same = result.messages.count == messages.count
                && result.messages.last?.id == messages.last?.id
                && zip(result.messages, messages).allSatisfy { $0.id == $1.id && $0.body == $1.body }
            if initial || !same {
                /* 左上角未读数字：首次进来带上列表里的未读；之后只要多出别人的新消息就往上加 */
                if initial {
                    unreadHere = chat.unreadCount
                } else if result.messages.count > messages.count, !messages.isEmpty {
                    let fresh = result.messages.suffix(result.messages.count - messages.count)
                    let incoming = fresh.filter { $0.senderId != myId && $0.kindName != "system" }.count
                    if incoming > 0 { unreadHere += incoming }
                }
                messages = result.messages
            }
        } catch {
            if initial { app.show("聊天记录加载失败") }
        }
        loading = false
    }
    /// 转账页预填的「收款账号」：一对一会话里对方的微信号；找不到就留空让用户自己填
    private var peerAccount: String {
        if let t = chat.title, let u = app.contacts.first(where: { ($0.nickname ?? "") == t || ($0.name ?? "") == t }) {
            return u.username ?? ""
        }
        return ""
    }
}

/* ============================================================ 单条消息 */

/// 系统消息行：通话记录就是「📞 通话时长 00:12」这样居中的一行灰字（和微信一样）。
/// 图标后台能换：ui.callRecord（语音）/ ui.callRecordVideo（视频）。
struct SystemLine: View {
    let message: Message

    var body: some View {
        HStack(spacing: 4) {
            if message.isCallRecord {
                CallIcon(key: message.isVideoCall ? "ui.callRecordVideo" : "ui.callRecord",
                         symbol: message.isVideoCall ? "video.fill" : "phone.fill",
                         builtin: message.isVideoCall ? I.callRecordVideo : I.callRecord,
                         size: 13, color: C.msgTime)
            }
            Text(message.body)
                .font(pf(12.5))
                .foregroundColor(C.msgTime)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }
}

struct MessageRow: View {
    let message: Message
    let mine: Bool
    var senderName: String = ""
    /// 点转账卡片 → 打开账单详情
    var onTapTransfer: ((TransferInfo) -> Void)? = nil
    /// 点图片 → 打开大图
    var onOpenImage: ((String) -> Void)? = nil
    /// 点头像 → 名片
    var onOpenAvatar: ((String) -> Void)? = nil

    @EnvironmentObject var app: AppState
    /// 语音消息播放状态（哪条在播）
    @ObservedObject private var voicePlayer = VoicePlayer.shared

    private var avatarPath: String {
        if let p = message.senderAvatar, !p.isEmpty { return p }
        return app.contact(for: message.senderId ?? "")?.avatarPath ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 60) }

            if !mine {
                Avatar(path: avatarPath, size: L.chatAvatar, radius: 6)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenAvatar?(message.senderId ?? "") }
                Spacer().frame(width: 9)
                VStack(alignment: .leading, spacing: 4) {
                    if !senderName.isEmpty {
                        Text(senderName)
                            .font(pf(12))
                            .foregroundColor(C.subLabel)
                    }
                    content
                }
            } else {
                content
            }

            if !mine { Spacer(minLength: 60) }

            if mine {
                Spacer().frame(width: 9)
                Avatar(path: avatarPath, size: L.chatAvatar, radius: 6)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenAvatar?(message.senderId ?? "") }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if message.isRecalled {
            Text(mine ? "你撤回了一条消息" : "对方撤回了一条消息")
                .font(pf(12))
                .foregroundColor(C.msgTime)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 5).fill(C.bubbleOther))
        } else {
            bubble
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.kindName {
        case "image":
            RemoteImage(path: message.body, icon: "photo")
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onOpenImage?(message.body) }

        case "location":
            locationBubble

        case "transfer":
            transferBubble
                .onTapGesture {
                    if let info = TransferInfo(json: message.body) { onTapTransfer?(info) }
                }

        case "gift":
            giftBubble

        case "file":
            fileBubble

        case "audio":
            audioBubble

        default:
            Text(message.body)
                .font(pf(L.chatFontSize))
                .foregroundColor(C.bubbleText)
                .padding(.horizontal, L.bubblePadH)
                .padding(.vertical, L.bubblePadV)
                .background(
                    BubbleShape(mine: mine)
                        .fill(mine ? C.bubbleMine : C.bubbleOther)
                )
        }
    }

    private func dict(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private var locationBubble: some View {
        let o = dict(message.body)
        let lat = (o["lat"] as? Double) ?? 0
        let lng = (o["lng"] as? Double) ?? 0
        let name = (o["name"] as? String) ?? "位置"
        let addr = (o["addr"] as? String) ?? ""
        return VStack(spacing: 0) {
            RemoteImage(path: Tiles.url(lat: lat, lng: lng), icon: "map")
                .frame(width: 216, height: 136)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(pf(15)).foregroundColor(C.bubbleText).lineLimit(1)
                Text(addr.isEmpty ? "点击查看地图" : addr)
                    .font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 216)
        .background(C.bubbleOther)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var transferBubble: some View {
        let o = dict(message.body)
        let amount = (o["amount"] as? Double) ?? 0
        let note = (o["note"] as? String) ?? ""
        let status = (o["status"] as? String) ?? "pending"
        let state = status == "received" ? "已收款" : (status == "refunded" ? "已退回" : "待对方确认收款")
        /* 转账卡片的颜色：
           还没人收 = 微信橙 #FA9D3D（参考图实测的橙）；
           收了之后（不管是发钱那侧还是收钱那侧）都变淡橙 #F0C69A —— 这就是「已收款要变色」；
           24 小时没人收退回是灰的。 */
        let card: Color
        if status == "refunded" {
            card = Color(hex: 0xC2C2C2)
        } else if status == "received" {
            card = Color(hex: 0xF0C69A)
        } else {
            card = Color(hex: 0xFA9D3C)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "yensign.circle.fill")
                    .font(pf(26))
                    .foregroundColor(Color(hex: 0xFFFFFF))
                VStack(alignment: .leading, spacing: 2) {
                    Text("¥\(String(format: "%.2f", amount))")
                        .font(pfMoney(19))
                        .foregroundColor(.white)
                    Text(note.isEmpty ? (mine ? "你发起了一笔转账" : "转账给你") : note)
                        .font(pf(12))
                        .foregroundColor(Color.white.opacity(0.88))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(state)
                .font(pf(11))
                .foregroundColor(Color.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: 216, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 语音消息气泡：喇叭 + 秒数，点一下播放（再点一下停）
    private var audioBubble: some View {
        let o = dict(message.body)
        let path = (o["url"] as? String) ?? ""
        let secs = max(1, (o["seconds"] as? Int) ?? 1)
        let playing = voicePlayer.playingID == message.id
        let width = min(210, 74 + CGFloat(secs) * 3.2)
        return HStack(spacing: 8) {
            SVGIcon(markup: I.speaker, size: 20,
                    color: playing ? C.green : C.bubbleText)
            Text("\(secs)″")
                .font(pfMoney(12.5))
                .foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 40, alignment: mine ? .trailing : .leading)
        .background(BubbleShape(mine: mine).fill(mine ? C.bubbleMine : C.bubbleOther))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let url = API.shared.assetURL(path) else {
                app.show("这条语音找不到了")
                return
            }
            voicePlayer.toggle(id: message.id, url: url)
        }
    }

    private var giftBubble: some View {
        let o = dict(message.body)
        let icon = (o["icon"] as? String) ?? "🎁"
        let name = (o["name"] as? String) ?? "礼物"
        let price = (o["price"] as? Double) ?? 0
        return HStack(spacing: 10) {
            Text(icon).font(pf(30))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(pf(15, .medium)).foregroundColor(C.bubbleText)
                    Text("¥\(String(format: "%.0f", price))").font(pfMoney(12)).foregroundColor(C.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            BubbleShape(mine: mine).fill(mine ? C.bubbleMine : C.bubbleOther)
        )
    }

    private var fileBubble: some View {
        let o = dict(message.body)
        let name = (o["name"] as? String) ?? "文件"
        let bytes = (o["bytes"] as? Int) ?? 0
        return HStack(spacing: 10) {
            SVGIcon(markup: I.plusIcons["file"] ?? "", size: 26, color: C.bubbleText)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(pf(14)).foregroundColor(C.bubbleText).lineLimit(1)
                Text(byteText(bytes)).font(pf(11)).foregroundColor(C.subLabel)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(width: 216, alignment: .leading)
        .background(
            BubbleShape(mine: mine).fill(mine ? C.bubbleMine : C.bubbleOther)
        )
    }

    private func byteText(_ n: Int) -> String {
        if n > 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024 / 1024) }
        if n > 1024 { return "\(n / 1024) KB" }
        return "\(n) B"
    }

    private func card(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            SVGIcon(markup: icon, size: 20, color: mine ? C.bubbleText : C.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(pf(15, .medium)).foregroundColor(C.bubbleText)
                if !detail.isEmpty {
                    Text(detail).font(pf(12)).foregroundColor(C.subLabel).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, L.bubblePadH)
        .padding(.vertical, L.bubblePadV)
        .background(
            BubbleShape(mine: mine).fill(mine ? C.bubbleMine : C.bubbleOther)
        )
    }
}

/* ============================================================ 地图小图 */

enum Tiles {
    static func url(lat: Double, lng: Double, z: Int = 15) -> String {
        let n = pow(2.0, Double(z))
        let x = Int(floor((lng + 180) / 360 * n))
        let rad = lat * .pi / 180
        let y = Int(floor((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n))
        return "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png"
    }
}
