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
    @ObservedObject private var lang = LangStore.shared
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var loading = true
    @State private var panel: PanelKind = .none
    @State private var plusItems: [PlusItem] = []
    @State private var gifts: [Gift] = []
    /// App 内打开的网页（AI 发的淘宝 / 闪购卡片，没装 App 时用这个）
    @State private var web: WebURL?
    /// 已经自动跳过的卡片（同一条只跳一次）
    @State private var autoOpened: Set<String> = []
    /* 长按消息的那套（和微信一样）：动作条 / 转发 / 多选 / 引用 */
    @State private var actionMessage: Message?
    @State private var forwardItems: [ForwardItem] = []
    @State private var showForward = false
    @State private var selectMode = false
    @State private var selected: Set<String> = []
    @State private var quote: Message?
    /// 每条消息在屏幕上的位置（长按弹的小方框要贴在它旁边）
    @State private var msgFrames: [String: CGRect] = [:]
    @State private var menuRect: CGRect = .zero

    @State private var showPhoto = false
    @State private var showCamera = false
    @State private var showLocation = false
    /* 位置：微信「＋ → 位置」会先问一句「发送位置 / 共享实时位置」 */
    @State private var showLocationMenu = false
    @State private var showLiveLocation = false
    /// 发送位置：用新的地图选点页（微信那种），不再用那个手填经纬度的表单
    @State private var showSendLocation = false
    @State private var showTransfer = false
    /// 红包：发红包页 / 拆红包 / 详情
    @State private var showSendRedPacket = false
    @State private var openRedPacket: RedPacketInfo? = nil
    @State private var redPacketDetail: String? = nil
    @State private var showGroupInfo = false
    @State private var showSearch = false
    @State private var showChatInfo = false
    @State private var showFile = false
    @State private var showCall = false
    /// 点「视频通话」以后弹的那个「语音通话 / 视频通话」选择（微信就是这样）
    @State private var showCallChoice = false
    @State private var billInfo: TransferInfo?
    @State private var uploading = false
    /// 点开聊天里的图片：paths = 这个会话里所有图片，index = 点的那张
    @State private var viewer: PhotoPager.Item?
    /// 点头像 → 名片（自己的头像是自己的名片）
    @State private var cardUser: User?
    /// 点位置气泡打开的大地图页
    @State private var openLocation: LocationPoint?
    /// 点机器人（AI 助手 / 腾讯新闻）的头像 → 弹它的名片
    @State private var botCard = false

    /* ---------------------------------------------------------- 长按消息的动作 */

    private func openActions(_ m: Message) {
        if selectMode { toggleSelect(m); return }
        menuRect = msgFrames[m.id] ?? .zero
        actionMessage = m
    }

    private func actionTitle(_ m: Message) -> String {
        let t = m.kindName == "text" ? m.body : "[" + (m.kindName == "image" ? "图片" : m.kindName) + "]"
        return String(t.prefix(40))
    }

    private func actions(for m: Message) -> [MsgAction] {
        var list: [MsgAction] = [
            MsgAction(key: "copy", label: "复制", icon: "doc.on.doc"),
            MsgAction(key: "forward", label: "转发", icon: "arrowshape.turn.up.right")
        ]
        /* 朗读：文字消息、通话记录、AI 回复都能念（微信里长按也有这一项） */
        if readableText(m).isEmpty == false {
            list.append(MsgAction(key: "speak", label: "朗读", icon: "speaker.wave.2"))
        }
        if !m.isRecalled {
            list.append(MsgAction(key: "fav", label: "收藏", icon: "star"))
            list.append(MsgAction(key: "quote", label: "引用", icon: "text.quote"))
        }
        if m.senderId == myId, !m.isRecalled {
            list.append(MsgAction(key: "recall", label: "撤回", icon: "arrow.uturn.backward", danger: true))
        }
        list.append(MsgAction(key: "multi", label: "多选", icon: "checkmark.circle"))
        list.append(MsgAction(key: "del", label: "删除", icon: "trash", danger: true))
        if m.senderId != myId {
            list.append(MsgAction(key: "report", label: "举报", icon: "exclamationmark.bubble"))
        }
        return list
    }

    /// 这条消息能不能念、念什么（表格/卡片这类没文字的就不显示「朗读」）
    private func readableText(_ m: Message) -> String {
        if m.isCallRecord { return m.callText }
        switch m.kindName {
        case "text", "link": return m.body
        default: return ""
        }
    }

    private func run(_ a: MsgAction, on m: Message) {
        switch a.key {
        case "speak":
            Speaker.shared.speak(readableText(m))
            app.show(Tr("正在朗读…"))
        case "copy":
            UIPasteboard.general.string = m.kindName == "text" ? m.body : "[" + m.kindName + "]"
            app.show(Tr("已复制"))
        case "forward":
            forwardItems = [ForwardItem(kind: (m.kindName == "image") ? "image" : "text", content: m.body)]
            showForward = true
        case "fav":
            Task {
                let ok = await API.shared.addFavorite(kind: m.kindName == "image" ? "image" : "text",
                                                      content: m.body,
                                                      title: chat.name,
                                                      from: displayName(m))
                app.show(ok ? Tr("已收藏") : Tr("收藏失败"))
            }
        case "quote":
            quote = m
        case "recall":
            recall(m)
        case "multi":
            selectMode = true
            selected = [m.id]
        case "del":
            messages.removeAll { $0.id == m.id }
            app.show(Tr("已删除"))
        case "report":
            report(m)
        default:
            break
        }
    }

    private func toggleSelect(_ m: Message) {
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
    }

    private func mySelected() -> [Message] {
        messages.filter { selected.contains($0.id) }
    }

    private func multiForward() {
        let picked = mySelected()
        guard !picked.isEmpty else { return }
        forwardItems = picked.map { ForwardItem(kind: ($0.kindName == "image") ? "image" : "text", content: $0.body) }
        showForward = true
    }

    private func multiFavorite() {
        let picked = mySelected()
        guard !picked.isEmpty else { return }
        Task {
            var n = 0
            for m in picked {
                if await API.shared.addFavorite(kind: m.kindName == "image" ? "image" : "text",
                                                content: m.body, title: chat.name, from: displayName(m)) { n += 1 }
            }
            app.show(Tr("已收藏") + " \(n) " + Tr("条"))
            selectMode = false
            selected = []
        }
    }

    private func multiDelete() {
        let ids = selected
        messages.removeAll { ids.contains($0.id) }
        app.show(Tr("已删除"))
        selectMode = false
        selected = []
    }

    @FocusState private var focused: Bool
    @ObservedObject private var realtime = Realtime.shared
    @ObservedObject private var recorder = VoiceRecorder.shared
    /// 输入框里那个小喇叭：语音转文字
    @StateObject private var dictation = Dictation()
    /// 话筒按钮：按下多久了（<0.22s 松手 = 语音转文字，按住 = 发语音）
    @State private var pressStart: Date?
    @State private var voiceStarting = false
    @State private var pushTask: Task<Void, Never>?
    /// 左上角返回箭头旁边那个未读数字（微信同位置）
    @State private var unreadHere = 0
    /// 点一下那个数字 = 滚回最新消息
    @State private var scrollTick = 0
    @State private var hasOlder = false          // 上面还有更早的记录
    @State private var loadingOlder = false
    @State private var holdScroll = false        // 上翻加载时不要自动跳到底部
    @State private var atBottom = true           // 列表是不是已经到底（没到底就别跟着新消息硬滚）
    @State private var voiceMode = false         // 输入区是不是「按住说话」模式（微信：左边那个语音/键盘切换）

    private var myId: String { app.me?.id ?? "" }
    private var isGroup: Bool { chat.type == "group" }

    /// 顶栏标题：群聊和微信一样带上当前群人数「群名(9)」，单聊就是对方名字
    private var navTitle: String {
        guard isGroup else { return chat.name }
        let n = chat.memberCount ?? (chat.memberIds?.count ?? 0)
        return n > 0 ? chat.name + "(" + String(n) + ")" : chat.name
    }

    /// 一对一会话里的对方 id（真人语音/视频通话要用它去呼叫）
    /// ⚠️ 以前是 `ids.first(where: { $0 != myId })`：万一这一刻 myId 还没加载出来（空串），
    /// 条件永远成立，就会返回名单里的**第一个人** —— 可能是我自己，也可能是机器人或
    /// 群里的其他人，而且完全没检查这个会话是不是「两个人」。
    /// 线上表现就是「电话打给了另一个人」。现在必须同时满足：
    /// ① 我自己的 id 已经知道 ② 这个会话恰好两个人 ③ 我在名单里 ④ 对方不是我自己。
    private var peerUserId: String? {
        let me = myId
        guard !me.isEmpty else { return nil }
        guard let ids = chat.memberIds, ids.count == 2, ids.contains(me) else { return nil }
        guard let other = ids.first(where: { $0 != me }), !other.isEmpty else { return nil }
        return other
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
        guard !isGroup else { app.show(Tr("群聊通话还没做，先在单聊里打")); return }
        guard let peer = peerUserId else { app.show(Tr("找不到对方账号，先刷新一下会话")); return }
       if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        /* 万一状态卡住了（异步回调把「通话中」又设回来过），这里先自愈一次，
           不然用户会「打不出去」：点拨打只弹一句「正在通话中」。 */
        CallCenter.shared.resetIfStale()
        if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        /* 呼叫时带的名字/头像用「这个 peer 自己的」，不要用会话名 ——
           会话名可能是群名或者是上一次同步下来的旧值，就会显示成别人。 */
        let peerName = app.contact(for: peer)?.name ?? chat.name
        CallCenter.shared.start(peerId: peer, name: peerName, avatar: chat.avatar ?? "", video: video)
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
                VoiceHUD(seconds: recorder.seconds, level: recorder.level,
                         willCancel: recorder.willCancel, willTranscribe: recorder.willTranscribe,
                         maxSeconds: recorder.maxSeconds)
                    .zIndex(50)
            }

        }
        /* 按住说话到 60 秒自动发出（微信就是这样），免得录个没完 */
        .onChange(of: recorder.seconds) { s in
            if recorder.recording, s >= recorder.maxSeconds { finishVoice() }
        }
        /* 顶栏：超薄毛玻璃（浅色模式下就是 iOS 那种浅浅的磨砂），背景图/消息从底下透过去 */
        .safeAreaInset(edge: .top, spacing: 0) {
            NavBar(title: navTitle, back: { dismiss() }, leftExtra: leftUnreadBadge) {
                Button {
                    /* 微信逻辑：右上「⋯」不是弹菜单，而是进聊天信息页
                       —— 群聊进「群聊信息」，单聊进「聊天信息」 */
                    if isGroup { showGroupInfo = true } else { showChatInfo = true }
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
                        Text(Tr("回到通话 ›"))
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectMode {
                MultiSelectBar(count: selected.count,
                               onForward: { multiForward() },
                               onFavorite: { multiFavorite() },
                               onDelete: { multiDelete() },
                               onCancel: { selectMode = false; selected = [] })
            } else {
                composer
            }
        }
        /* 长按：贴着那条消息弹出一个小方框（微信那种，不是从底下滑上来的） */
        .overlay {
            GeometryReader { geo in
                if let m = actionMessage {
                    let g = geo.frame(in: .global)
                    let box = MsgMenuBox.size(actions(for: m).count)
                    let rect = menuRect == .zero
                        ? CGRect(x: g.midX, y: g.midY, width: 0, height: 0)
                        : menuRect
                    let above = (rect.minY - g.minY) > (box.height + 16)
                    let x = min(max(8, rect.midX - g.minX - box.width / 2),
                                max(8, geo.size.width - box.width - 8))
                    let y = above ? (rect.minY - g.minY - box.height - 8)
                                  : min(geo.size.height - box.height - 8, rect.maxY - g.minY + 8)
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.03)
                            .ignoresSafeArea()
                            .onTapGesture { actionMessage = nil }
                        MsgMenuBox(actions: actions(for: m)) { a in
                            actionMessage = nil
                            run(a, on: m)
                        }
                        .offset(x: x, y: max(8, y))
                    }
                }
            }
            .zIndex(30)
        }
        .onPreferenceChange(MsgFrameKey.self) { msgFrames = $0 }
        .sheet(isPresented: $showForward) {
            ForwardPickerView(items: forwardItems) { }
                .environmentObject(app)
        }
        /* 点「视频通话」→ 微信那样弹「语音通话 / 视频通话」两个选择 */
        .confirmationDialog(Tr("音视频通话"), isPresented: $showCallChoice, titleVisibility: .hidden) {
            Button(Tr("语音通话")) { startRealCall(video: false) }
            Button(Tr("视频通话")) { startRealCall(video: true) }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 右上「⋯」进的是聊天信息页（微信那套）；页里能打语音/视频、免打扰、置顶、
           查记录、换背景、清空、删除 —— 见 DirectChatInfoView */
        .sheet(isPresented: $showChatInfo) {
            DirectChatInfoView(chat: chat).environmentObject(app)
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
        /* 位置：发送位置 / 共享实时位置（微信那一套） */
        .confirmationDialog(Tr("位置"), isPresented: $showLocationMenu, titleVisibility: .visible) {
            Button(Tr("发送位置")) { showSendLocation = true }
            Button(Tr("共享实时位置")) { showLiveLocation = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        .sheet(isPresented: $showSendLocation) {
            SendLocationView { payload in send(kind: "location", content: payload) }
        }
        .sheet(isPresented: $showLiveLocation) {
            LiveLocationView(chat: chat) {
                send(kind: "text", content: "📍 我发起了共享实时位置，点＋→位置→共享实时位置就能加入")
            }
            .environmentObject(app)
        }
        .sheet(isPresented: $showTransfer) {
            /* 用「照网页版一条条量出来」的那套转账页（TransferView）：
               转账页 + 支付面板 + 付款方式面板 + 结果页，颜色/尺寸和网页版一致 */
            TransferView(chat: chat)
        }
        /* 红包：发红包（半屏）→ 塞钱进红包要支付密码；抢 / 看详情各自一套 */
        .sheet(isPresented: $showSendRedPacket) {
            RedPacketSendView(chat: chat) { _ in
                Task { await load(initial: false); await app.loadChats() }
            }
            .environmentObject(app)
        }
        .fullScreenCover(item: $openRedPacket) { info in
            RedPacketOpenView(info: info, myId: myId) { id in
                redPacketDetail = id
            }
            .environmentObject(app)
        }
        .sheet(isPresented: Binding(
            get: { redPacketDetail != nil },
            set: { if !$0 { redPacketDetail = nil } }
        )) {
            if let id = redPacketDetail {
                RedPacketDetailView(id: id, myId: myId).environmentObject(app)
            }
        }
        .fullScreenCover(isPresented: $showCall) {
            AICallView(chat: chat)
        }
        .fullScreenCover(item: $viewer) { item in
            PhotoPager(paths: item.paths, startIndex: item.index) { viewer = nil }
        }
        .modifier(TapAvatarCard(cardUser: $cardUser))
        .sheet(isPresented: $botCard) {
            BotCardView(chat: chat).environmentObject(app)
        }
        .sheet(item: $web) { SafariSheet(url: $0.url) }
        /* 点位置气泡 → 整页大地图（微信那样） */
        .sheet(item: $openLocation) { p in
            LocationDetailView(point: p).environmentObject(app)
        }
        .onChange(of: messages.count) { _ in autoOpenShopCard() }
        .sheet(isPresented: $showGroupInfo) { GroupInfoView(chat: chat) }
        .sheet(isPresented: $showSearch) { ChatSearchView(chat: chat) }
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
                    /* 上面还有更早的记录时，顶部给一个「查看更早的消息」 */
                    if hasOlder {
                        HStack(spacing: 6) {
                            if loadingOlder { ProgressView().scaleEffect(0.7) }
                            Text(loadingOlder ? Tr("加载中…") : Tr("查看更早的消息"))
                                .font(pf(13))
                                .foregroundColor(C.subLabel)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await loadOlder() } }
                    }
                    ForEach(messages) { message in
                        messageBlock(message)
                            .id(message.id)
                    }
                    /* 底部哨兵：它在屏幕上就说明「已经到底了」。
                       只有到底了才允许跟着新消息自动滚 —— 不然你正往上翻旧消息时
                       来一条新消息，列表会被硬拽到底，手感上就是「卡住划不动」。 */
                    Color.clear
                        .frame(height: 1)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                    if loading && messages.isEmpty {
                        ProgressView().padding(.top, 40)
                    }
                }
                .padding(L.msgPad)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in
                /* 只有「已经到底了」或者「刚才是自己发的」才跟着滚；
                   而且不用动画 —— 动画会和正在拖动的手势打架（就是那个「划不动」）。 */
                guard !holdScroll else { return }
                guard atBottom || messages.last?.senderId == myId else { return }
                scrollToEnd(proxy, animated: false)
            }
            .onChange(of: scrollTick) { _ in
                atBottom = true                       // 用户自己点的「回到底部」
                scrollToEnd(proxy, animated: true)
            }
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

    /* ----------------------------------------------------------
       一条消息 = 时间线 + 内容 + 底部间距（微信的排版逻辑）：
         · 同一个人连着发：中间只留 4（看起来是一组）
         · 换个人发：留 15（明显断开）
         · 出现时间线：让时间线自己带上下 12，消息这边就不留了
         · 系统消息（通话记录 / 撤回提示）居中一行灰字，上下各 12
       还有两条跟着分组走：群里昵称只挂在连发的第一条上、气泡的小尖角也只画在第一条上。
       ---------------------------------------------------------- */

    @ViewBuilder
    private func messageBlock(_ message: Message) -> some View {
        VStack(spacing: 0) {
            if showTime(for: message) { timeLine(message) }
            if message.kindName == "system" {
                /* 微信的通话记录是一条气泡，摆在哪边看「谁打的」：
                   自己打出去的 → 右边（绿），对方打过来的 → 左边（白）。
                   老记录里没有「谁打的」这个信息，就还是居中一行灰字。 */
                if message.isCallRecord && !message.callFrom.isEmpty {
                    callRow(message)
                } else {
                    SystemLine(message: message)
                        .padding(.bottom, gapAfter(message))
                        /* 老记录（没有「谁打的」信息）：点一下按这个会话的对方回拨 */
                        .onTapGesture { startRealCall(video: message.isVideoCall) }
                }
            } else if message.isRecalled {
                recallLine(message)
                    .padding(.bottom, gapAfter(message))
            } else {
                messageRow(message)
            }
        }
    }

    private func timeLine(_ message: Message) -> some View {
        Text(TimeFmt.bubble(message.createdAt))
            .font(pf(L.msgTimeSize))
            .foregroundColor(C.chatTimeInk)
            /* 时间加一个明显的圆角小框（和微信一样；颜色/圆角后台能调，只作用于聊天页） */
            .padding(.horizontal, L.o("chatTimePadX", 8))
            .padding(.vertical, L.o("chatTimePadY", 3))
            .background(RoundedRectangle(cornerRadius: L.o("chatTimeRadius", 4), style: .continuous)
                .fill(C.chatTimeBg))
            .frame(maxWidth: .infinity)
            .padding(.top, L.o("chatTimeGapTop", 12))
            .padding(.bottom, L.o("chatTimeGapBottom", 12))
    }

    /// 撤回的提示：微信里不是气泡，是居中一行灰字
    private func recallLine(_ message: Message) -> some View {
        Text(recallText(message))
            .font(pf(12.5))
            .foregroundColor(C.msgTime)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
    }

    private func recallText(_ message: Message) -> String {
        if message.senderId == myId { return Tr("你撤回了一条消息") }
        if isGroup { return displayName(message) + " " + Tr("撤回了一条消息") }
        return Tr("对方撤回了一条消息")
    }

    @ViewBuilder
    private func messageRow(_ message: Message) -> some View {
        MessageRow(message: message,
                   mine: mineFor(message),
                   myId: myId,
                   senderName: senderNameFor(message),
                   showTail: isRunStart(message),
                   onTapTransfer: { info in billInfo = info },
                   onOpenImage: { path in openImage(path) },
                   onOpenAvatar: { id in openAvatar(id) },
                   onOpenWeb: { url in web = WebURL(url: url) },
                   onOpenLocation: { p in openLocation = p },
                   onTapRedPacket: { info in tapRedPacket(info) })
            .padding(.bottom, gapAfter(message))
            /* 长按一条消息：弹微信那套动作条（复制/转发/收藏/引用/撤回/删除/多选） */
            .onLongPressGesture { openActions(message) }
            .overlay(alignment: .leading) {
                if selectMode {
                    Image(systemName: selected.contains(message.id)
                          ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundColor(selected.contains(message.id) ? C.green : C.subLabel)
                        .padding(.leading, 10)
                }
            }
            .overlay {
                if selectMode {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { toggleSelect(message) }
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: MsgFrameKey.self,
                                       value: [message.id: g.frame(in: .global)])
            })
    }

    /// 通话记录按「谁打的」定左右（其他消息还是看发送者）
    private func mineFor(_ message: Message) -> Bool {
        if message.isCallRecord && !message.callFrom.isEmpty { return message.callFrom == myId }
        return message.senderId == myId
    }

    /// 通话记录那一行：头像 + 气泡（里面是电话/摄像机图标 +「通话时长 00:12」）
    @ViewBuilder
    private func callRow(_ message: Message) -> some View {
        let mine = mineFor(message)
        let callerAvatar = app.contact(for: message.callFrom)?.avatarPath ?? ""
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 0) }
            if !mine {
                Avatar(path: callerAvatar, size: L.chatAvatar, radius: 4)
                Spacer().frame(width: L.chatGap)
            }
            CallRecordBubble(message: message, mine: mine)
            if mine {
                Spacer().frame(width: L.chatGap)
                Avatar(path: callerAvatar, size: L.chatAvatar, radius: 4)
            }
            if !mine { Spacer(minLength: 0) }
        }
        .padding(.bottom, gapAfter(message))
        .onLongPressGesture { openActions(message) }
        /* 微信那样：点一下这条通话记录 = 直接回拨（视频记录就回拨视频） */
        .onTapGesture { redial(from: message) }
    }

    /// 点通话记录回拨：对方 = 这条记录的双方里「不是我」的那个。
    /// 严格校验（空的、等于我自己都不拨），免得又出现「不能给自己打电话」那种误拨。
    private func redial(from message: Message) {
        let peer = (message.callFrom == myId) ? (message.call?.to ?? "") : message.callFrom
        guard !peer.isEmpty, peer != myId else { app.show(Tr("这条记录里找不到对方账号")); return }
        if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        CallCenter.shared.resetIfStale()
        if CallCenter.shared.phase != .idle { app.show(Tr("正在通话中")); return }
        let name = app.contact(for: peer)?.name ?? chat.name
        CallCenter.shared.start(peerId: peer, name: name,
                                avatar: app.contact(for: peer)?.avatarPath ?? (chat.avatar ?? ""),
                                video: message.isVideoCall)
    }

    private func indexOf(_ message: Message) -> Int? {
        messages.firstIndex(where: { $0.id == message.id })
    }

    /// 是不是「同一个人连发」里的第一条（昵称和气泡尖角都挂这一条）
    private func isRunStart(_ message: Message) -> Bool {
        guard let i = indexOf(message), i > 0 else { return true }
        let prev = messages[i - 1]
        if prev.kindName == "system" || prev.isRecalled { return true }
        if (prev.senderId ?? "") != (message.senderId ?? "") { return true }
        return TimeFmt.minutesBetween(prev.createdAt, message.createdAt) >= 5
    }

    /// 群里才写昵称，而且只写在连发的第一条上（微信就是这样）
    private func senderNameFor(_ message: Message) -> String {
        guard isGroup, message.senderId != myId else { return "" }
        return isRunStart(message) ? displayName(message) : ""
    }

    /// 这一条下面留多少空隙
    private func gapAfter(_ message: Message) -> CGFloat {
        guard let i = indexOf(message) else { return 15 }
        guard i + 1 < messages.count else { return 4 }
        let next = messages[i + 1]
        if showTime(for: next) { return 0 }        // 时间线自己带上下间距
        if next.kindName == "system" || next.isRecalled { return 12 }
        if message.kindName == "system" || message.isRecalled { return 12 }
        let same = (next.senderId ?? "") == (message.senderId ?? "")
        return same ? 4 : 15
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 18)
                    /* 数字外面那个「药丸框」：里面填色，外面再描一圈白边 */
                    .background(
                        Capsule()
                            .fill(C.red)
                            .overlay(Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
                    )
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
            /* 引用了某条消息：上面挂一条引用条（点 ✕ 取消） */
            if let q = quote {
                HStack(spacing: 8) {
                    Rectangle().fill(C.green).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(q.senderId == myId ? Tr("我") : displayName(q))
                            .font(pf(11.5))
                            .foregroundColor(C.green)
                        Text(q.kindName == "text" ? String(q.body.prefix(40)) : "[" + q.kindName + "]")
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { quote = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundColor(C.subLabel)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .background(C.tabBg)
            }
            HStack(spacing: 6) {
                /* 这个键两种用法（微信也是这样，同时照顾老习惯）：
                   轻点 = 切「语音 / 键盘」模式；**按住 = 直接开始录音** ——
                   靠「按了多久」区分。上一版只保留了切换，按住毫无反应，
                   用户就以为「浮层没了」（线上真被这么反馈过）。 */
                Image(systemName: voiceMode ? "keyboard" : "mic")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundColor(recorder.recording ? C.green : C.chatBarIcon)
                    .frame(width: L.composerIconBox, height: L.composerIconBox)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if pressStart == nil { pressStart = Date() }
                                if recorder.recording {
                                    recorder.drag(v.translation.height)
                                    return
                                }
                                if !voiceStarting, Date().timeIntervalSince(pressStart ?? Date()) > 0.22 {
                                    voiceStarting = true
                                    focused = false
                                    panel = .none
                                    Task { _ = await recorder.begin(); voiceStarting = false }
                                }
                            }
                            .onEnded { _ in
                                let held = Date().timeIntervalSince(pressStart ?? Date())
                                pressStart = nil
                                voiceStarting = false
                                if recorder.recording {
                                    if recorder.willCancel { recorder.cancel(); return }
                                    if recorder.willTranscribe {
                                        guard let got = recorder.end() else { return }
                                        FileSpeech.requestAuth()
                                        Task {
                                            let text = await FileSpeech.recognize(url: got.url)
                                            if text.isEmpty { app.show(Tr("没听清，再说一次或者直接发语音")) }
                                            else { input = text }
                                        }
                                        return
                                    }
                                    finishVoice()
                                    return
                                }
                                if held < 0.22 {                 // 轻点 = 切「语音 / 键盘」
                                    voiceMode.toggle()
                                    if voiceMode { focused = false; panel = .none }
                                }
                            }
                    )

                HStack(spacing: 0) {
                    if voiceMode {
                        /* 微信那种「按住 说话」：按住开始录、上滑取消、松手发送。
                           打字内容存成草稿，切回键盘时原样回来。 */
                        HStack(spacing: 7) {
                            if recorder.recording {
                                Image(systemName: "waveform")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(recorder.willCancel ? C.red : C.green)
                            }
                            Text(recorder.recording
                                 ? (recorder.willCancel ? Tr("松开手指，取消发送") : Tr("松开 发送"))
                                 : Tr("按住 说话"))
                                .font(pf(15.5))
                                .foregroundColor(recorder.willCancel ? C.red : C.label)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if pressStart == nil { pressStart = Date() }
                                    if recorder.recording {
                                        recorder.drag(v.translation.height)
                                    } else if !voiceStarting {
                                        voiceStarting = true
                                        focused = false
                                        panel = .none
                                        Task {
                                            _ = await recorder.begin()
                                            voiceStarting = false
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    pressStart = nil
                                    voiceStarting = false
                                    guard recorder.recording else { return }
                                    /* 松手时按当前滑到的档位处理（照微信那张图）：
                                       取消区 → 丢弃；转文字区 → 本地识别成文字进输入框；其余 → 发语音 */
                                    if recorder.willCancel { recorder.cancel(); return }
                                    if recorder.willTranscribe {
                                        guard let got = recorder.end() else { return }
                                        FileSpeech.requestAuth()
                                        Task {
                                            let text = await FileSpeech.recognize(url: got.url)
                                            if text.isEmpty { app.show(Tr("没听清，再说一次或者直接发语音")) }
                                            else { input = text }
                                        }
                                        return
                                    }
                                    finishVoice()
                                }
                        )
                    } else if recorder.recording {
                        /* 录音时把输入框整条收起来（微信就是这样）：
                           不然刚打的字一直露在框里，还和录音按钮混在一起。
                           松手立刻恢复，原来打的字还在（草稿）。 */
                        HStack(spacing: 7) {
                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(recorder.willCancel ? C.red : C.green)
                            Text(recorder.willCancel ? Tr("松开手指，取消发送") : Tr("松开 发送"))
                                .font(pf(15.5))
                                .foregroundColor(recorder.willCancel ? C.red : C.label)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        HStack(spacing: 4) {
                            TextField("", text: $input)
                                .focused($focused)
                                .font(pf(17))
                                .foregroundColor(C.label)
                                .onTapGesture { panel = .none }
                            /* 「听声出字」：只在**点进输入框、键盘起来**的时候才出现（微信就是这个时机），
                               点一下开始听，说的字直接落进输入框，可以改完再发 */
                            if focused {
                                Button {
                                    let base = input
                                    dictation.toggle { s in input = base.isEmpty ? s : (base + s) }
                                } label: {
                                    Image(systemName: dictation.listening ? "mic.fill" : "mic")
                                        .font(.system(size: 17))
                                        .foregroundColor(dictation.listening ? C.green : C.chatBarIcon)
                                        .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: L.inputH)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(recorder.recording
                              ? (recorder.willCancel ? Color.dyn(0xFFF1F1, 0x3A2A2A) : Color.dyn(0xF2F2F2, 0x242427))
                              : Color.dyn(0xFFFFFF, 0x2C2C2E))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(recorder.recording
                                ? (recorder.willCancel ? C.red.opacity(0.35) : C.green.opacity(0.35))
                                : Color.dyn(0xE8E8E8, 0x3A3A3C), lineWidth: 0.5)
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
                        Text(Tr("发送"))
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
        .overlay(alignment: .top) {
            if dictation.listening {
                Text("正在听你说，说完自己上屏…")
                    .font(pf(12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(C.green))
                    .offset(y: -22)
            }
        }
        .onChange(of: dictation.error) { msg in
            if !msg.isEmpty { app.show(msg) }
        }
        .onDisappear { dictation.stop() }
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
                       onDelete: { if !input.isEmpty { input.removeLast() } },
                       onSendSticker: { url in
                           /* 我们的表情：以图片消息发出去（和微信发自定义表情一样） */
                           send(kind: "image", content: url)
                           panel = .none
                       })
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
            showLocationMenu = true
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
                /* 微信的写法：点「视频通话」不是直接拨，而是弹出「语音通话 / 视频通话」两个选择 */
                showCallChoice = true
            }
        case "voice":
            panel = .none
            app.show(Tr("按住输入框左边的麦克风说话：松开发送，上滑取消"))
        case "redpacket":
            panel = .none
            showSendRedPacket = true
        case "favorite":
            panel = .none
            app.show(Tr("收藏夹还是空的"))
        case "card":
            panel = .none
            app.show(Tr("名片：去「通讯录」点头像即可发送"))
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
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        /* 引用：把被引的那条放在前面（像微信那样带一条引用） */
        if let q = quote {
            let who = q.senderId == myId ? Tr("我") : displayName(q)
            let snip = q.kindName == "text" ? String(q.body.prefix(30)) : "[" + q.kindName + "]"
            text = "「" + who + "：" + snip + "」\n" + text
        }
        input = ""
        quote = nil
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
        /* 机器人：不用去通讯录找，直接弹它自己的名片（AI 助手 / 腾讯新闻） */
        if (chat.botRank ?? 9) < 9, senderId.isEmpty || senderId == peerUserId {
            botCard = true
            return
        }
        if id == myId, let me = app.me { cardUser = me; return }
        if let u = app.contact(for: id) { cardUser = u; return }
        Task {
            if let u = try? await API.shared.user(id: id) { cardUser = u }
            else { app.show(Tr("打不开这个人的名片")) }
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

    /// 点红包卡片：还能抢就直接拆红包；自己发的 / 已领过 / 领完 / 过期 → 看详情
    private func tapRedPacket(_ info: RedPacketInfo) {
        if info.fromId != myId && info.stillOpen && !info.claimed(by: myId) {
            openRedPacket = info
        } else {
            redPacketDetail = info.id
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
                app.show(Tr("录音读不到，再录一次"))
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
                app.show(Tr("读不到这个文件"))
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
            app.show(Tr("已举报，管理员会处理"))
        }
    }

    /* ---------------------------------------------------------- 数据 */

    private func load(initial: Bool) async {
        /* 登录后同步下来的最近记录：先铺在界面上（微信也是先出内容再刷），
           然后再向服务器要最新的 —— 这样点开会话是"立刻有内容"，不是白屏等网络。 */
        if initial, messages.isEmpty, let cached = app.prefetched[chat.id], !cached.isEmpty {
            messages = cached
            hasOlder = true
        }
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
                if initial { hasOlder = result.hasMore }
            }
        } catch {
            if initial { app.show(Tr("聊天记录加载失败")) }
        }
        loading = false
        autoOpenShopCard()
    }

    /* 往上看更早的记录：服务端支持 before 翻页（一次 40 条），加载完把更早的接在前面 */
    private func loadOlder() async {
        guard !loadingOlder, let first = messages.first, let seq = first.seq else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let r = try await API.shared.messages(chatId: chat.id, limit: 40, before: seq)
            hasOlder = r.hasMore
            guard !r.messages.isEmpty else { return }
            holdScroll = true
            messages = r.messages + messages
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { holdScroll = false }
        } catch {
            app.show(Tr("聊天记录加载失败"))
        }
    }

    /// AI 发来的「点外卖 / 买东西」卡片：一到手就直接跳（装了淘宝跳淘宝 App，没装用 App 内网页），
    /// 不用用户自己去点那串网址。同一条只跳一次。
    private func autoOpenShopCard() {
        guard let last = messages.last, last.kindName == "link",
              last.senderId != myId, !autoOpened.contains(last.id),
              let link = ShopLink(json: last.body) else { return }
        autoOpened.insert(last.id)
        ShopOpener.open(link) { url in web = WebURL(url: url) }
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
                         size: 13, color: ink)
            }
            Text(message.body)
                .font(pf(12.5))
                .foregroundColor(ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    /// 没接通的通话记录用红色（微信里「未接听 / 已拒绝 / 已取消 / 对方无应答」都是红的）
    private var ink: Color {
        guard message.isCallRecord else { return C.msgTime }
        let t = message.body
        let bad = ["未接听", "已拒绝", "已取消", "无应答", "不在线", "忙线", "未接通", "无人接听"]
        return bad.contains(where: { t.contains($0) }) ? Color(hex: 0xFA5151) : C.msgTime
    }
}

/// 通话记录的气泡：电话/摄像机小图标 +「通话时长 00:12」（微信里通话记录就是这么一条气泡，
/// 自己打出去的在右边、对方打过来的在左边）
struct CallRecordBubble: View {
    let message: Message
    let mine: Bool

    var body: some View {
        HStack(spacing: 6) {
            CallIcon(key: message.isVideoCall ? "ui.callRecordVideo" : "ui.callRecord",
                     symbol: message.isVideoCall ? "video.fill" : "phone.fill",
                     builtin: message.isVideoCall ? I.callRecordVideo : I.callRecord,
                     size: 15, color: ink)
            Text(message.callText)
                .font(pf(L.chatFontSize))
                .foregroundColor(ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(BubbleShape(mine: mine).fill(mine ? C.bubbleMine : C.bubbleOther))
        .frame(maxWidth: L.bubbleMaxW, alignment: mine ? .trailing : .leading)
    }

    /// 没接通的通话记录用红色（微信里「未接听 / 已取消 / 对方无应答」都是红的）
    private var ink: Color {
        let t = message.body
        let bad = ["未接听", "已拒绝", "已取消", "无应答", "不在线", "忙线", "未接通", "无人接听"]
        return bad.contains(where: { t.contains($0) }) ? Color(hex: 0xFA5151) : C.bubbleText
    }
}

struct MessageRow: View {
    let message: Message
    let mine: Bool
    /// 我自己的 id：红包卡片要判断「我抢过没有」
    var myId: String = ""
    var senderName: String = ""
    /// 气泡那个小尖角只画在「连发的第一条」上（微信就是这样，后面的气泡是普通圆角）
    var showTail: Bool = true
    /// 点转账卡片 → 打开账单详情
    var onTapTransfer: ((TransferInfo) -> Void)? = nil
    /// 点图片 → 打开大图
    var onOpenImage: ((String) -> Void)? = nil
    /// 点头像 → 名片
    var onOpenAvatar: ((String) -> Void)? = nil
    /// 点 AI 的「点外卖 / 买东西」卡片 → 打开（没装淘宝就用 App 内网页）
    var onOpenWeb: ((URL) -> Void)? = nil
    /// 点位置气泡 → 打开大地图
    var onOpenLocation: ((LocationPoint) -> Void)? = nil
    /// 点红包卡片 → 拆红包 / 看详情
    var onTapRedPacket: ((RedPacketInfo) -> Void)? = nil

    @EnvironmentObject var app: AppState
    /// 语音消息播放状态（哪条在播）
    @ObservedObject private var voicePlayer = VoicePlayer.shared
    /// 这次进聊天页里已经听过哪些语音（配合本机记录，用来点掉那个小红点）
    @State private var playedVoice: Set<String> = []

    private var avatarPath: String {
        if let p = message.senderAvatar, !p.isEmpty { return p }
        return app.contact(for: message.senderId ?? "")?.avatarPath ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 0) }

            if !mine {
                avatarView
                Spacer().frame(width: L.chatGap)
            }

            bubbleColumn

            if mine {
                Spacer().frame(width: L.chatGap)
                avatarView
            }

            if !mine { Spacer(minLength: 0) }
        }
    }

    /// 头像（点一下看名片）：微信是 40、圆角 4
    private var avatarView: some View {
        Avatar(path: avatarPath, size: L.chatAvatar, radius: 4)
            .contentShape(Rectangle())
            .onTapGesture { onOpenAvatar?(message.senderId ?? "") }
    }

    /// 昵称（群里才有）+ 气泡，整列最宽按微信的 66% 卡住
    private var bubbleColumn: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            if !senderName.isEmpty {
                Text(senderName)
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
                    .lineLimit(1)
            }
            content
        }
        .frame(maxWidth: L.bubbleMaxW, alignment: mine ? .trailing : .leading)
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

    /// 气泡底色（自己的绿、对方的白/深灰）
    private var bubbleFill: Color { mine ? C.bubbleMine : C.bubbleOther }

    @ViewBuilder
    private var bubble: some View {
        switch message.kindName {
        case "image":
            /* 微信里的图片：按原比例出缩略图（最长边 200），不是硬裁成正方形 */
            ImageBubble(path: message.body) { onOpenImage?(message.body) }

        case "location":
            /* 点一下就进「位置详情」大地图页（微信就是这么点的） */
            locationBubble
                .onTapGesture {
                    if let p = LocationPoint.parse(message.body) { onOpenLocation?(p) }
                }

        case "transfer":
            transferBubble
                .onTapGesture {
                    if let info = TransferInfo(json: message.body) { onTapTransfer?(info) }
                }

        case "redpacket":
            redPacketBubble
                .onTapGesture {
                    if let info = RedPacketInfo(json: message.body) { onTapRedPacket?(info) }
                }

        case "gift":
            giftBubble

        case "link":
            if let link = ShopLink(json: message.body) {
                ShopLinkCard(link: link) {
                    ShopOpener.open(link) { url in onOpenWeb?(url) }
                }
            } else {
                Text(message.body)
                    .font(pf(L.chatFontSize))
                    .foregroundColor(C.bubbleText)
                    .padding(.horizontal, L.bubblePadH)
                    .padding(.vertical, L.bubblePadV)
                    .background(BubbleShape(mine: mine, tail: showTail).fill(bubbleFill))
            }

        case "file":
            fileBubble

        case "audio":
            audioBubble

        default:
            Group {
                /* AI 发来的淘宝 / 淘宝闪购链接：做成能直接点开的蓝色链接 */
                if message.body.contains("http://") || message.body.contains("https://") {
                    Text(linkText(message.body))
                } else {
                    Text(message.body)
                }
            }
                .font(pf(L.chatFontSize))
                .foregroundColor(C.bubbleText)
                .lineSpacing(4)                        // 微信正文的行距
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, L.bubblePadH)
                .padding(.vertical, L.bubblePadV)
                .background(
                    BubbleShape(mine: mine, tail: showTail)
                        .fill(bubbleFill)
                )
        }
    }

    private func dict(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// 把消息里的 http/https 链接挑出来，做成可以点开的链接（微信里就是蓝色的那种）
    private func linkText(_ s: String) -> AttributedString {
        var out = AttributedString()
        var idx = s.startIndex
        while idx < s.endIndex {
            guard let r = s.range(of: "http", range: idx..<s.endIndex) else {
                out += AttributedString(String(s[idx..<s.endIndex]))
                break
            }
            if r.lowerBound > idx { out += AttributedString(String(s[idx..<r.lowerBound])) }
            var end = r.lowerBound
            while end < s.endIndex, !s[end].isWhitespace, s[end] != "，", s[end] != "。", s[end] != "、", s[end] != "）" {
                end = s.index(after: end)
            }
            let text = String(s[r.lowerBound..<end])
            var seg = AttributedString(text)
            if let u = URL(string: text) {
                seg.link = u
                seg.foregroundColor = Color.dyn(0x576B95, 0x7D90B8)
            }
            out += seg
            idx = end
        }
        return out
    }

    private var locationBubble: some View {
        let o = dict(message.body)
        let lat = (o["lat"] as? Double) ?? 0
        let lng = (o["lng"] as? Double) ?? 0
        let name = (o["name"] as? String) ?? "位置"
        let addr = (o["addr"] as? String) ?? ""
        let pt = LocationPoint(lat: lat, lng: lng, name: name, addr: addr)
        return VStack(spacing: 0) {
            /* 小地图改成**本机用苹果地图渲染的快照**：
               以前用的是 tile.openstreetmap.org 的瓦片，国内网络经常拉不到 → 气泡一片空白。 */
            MapSnapshotView(point: pt, width: 216, height: 136)
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
        /* 微信的位置气泡是白卡 + 小尖角（自己的也是白的）。
           先把内容裁成圆角，再把带尖角的形状铺在底下，尖角才不会被裁掉。 */
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(BubbleShape(mine: mine, tail: showTail).fill(C.bubbleOther))
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
        /* 排版照微信：左边一个白色圆底图标，右边金额（大字）+"转账"/说明，
           最下面一条细线隔开的底栏：左边「转账」，右边状态（待对方确认收款 / 已收款 / 已退回） */
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 38, height: 38)
                    Image(systemName: "yensign")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("¥\(String(format: "%.2f", amount))")
                        .font(pfMoney(21, .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(note.isEmpty ? Tr("转账") : note)
                        .font(pf(12))
                        .foregroundColor(Color.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 11)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 0.5)

            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                Text(Tr("转账"))
                    .font(pf(11.5))
                    .foregroundColor(Color.white.opacity(0.85))
                Spacer(minLength: 4)
                Text(state)
                    .font(pf(12))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .frame(width: 240, alignment: .leading)
        .background(card)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 红包气泡：橙色卡片（领过 / 领完 / 过期都变淡）
    @ViewBuilder
    private var redPacketBubble: some View {
        if let info = RedPacketInfo(json: message.body) {
            RedPacketCard(info: info, mine: mine, myId: myId)
        } else {
            /* 老版本留下来的、结构对不上的红包消息（服务端已经删掉那套逻辑了）：
               不显示一堆 JSON，给一句人话 */
            Text("[红包] 这条记录是旧版本的，已经失效")
                .font(pf(14))
                .foregroundColor(C.subLabel)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.hairline))
        }
    }

    /// 语音消息气泡：喇叭 + 秒数，点一下播放（再点一下停）
    private var audioBubble: some View {
        let o = dict(message.body)
        let path = (o["url"] as? String) ?? ""
        let secs = max(1, (o["seconds"] as? Int) ?? 1)
        let playing = voicePlayer.playingID == message.id
        let width = min(210, 74 + CGFloat(secs) * 3.2)
        /* 微信里喇叭永远贴着「靠头像那一边」：对方发的在左、自己发的在右 */
        return HStack(spacing: 8) {
            if mine { Spacer(minLength: 0) }
            if mine {
                Text("\(secs)″")
                    .font(pfMoney(12.5))
                    .foregroundColor(C.subLabel)
                speakerIcon(playing: playing)
            } else {
                speakerIcon(playing: playing)
                Text("\(secs)″")
                    .font(pfMoney(12.5))
                    .foregroundColor(C.subLabel)
            }
            if !mine { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 40, alignment: mine ? .trailing : .leading)
        .background(BubbleShape(mine: mine, tail: showTail).fill(bubbleFill))
        /* 没听过的语音：气泡右上角一个小红点（微信），听过就没了；
           自己发的语音不点这个点 */
        .overlay(alignment: .topTrailing) {
            if !mine, !playedVoice.contains(message.id), !VoicePlayed.isPlayed(message.id) {
                Circle().fill(C.red)
                    .frame(width: 8, height: 8)
                    .offset(x: -5, y: 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            playedVoice.insert(message.id)
            VoicePlayed.markPlayed(message.id)
            guard let url = API.shared.assetURL(path) else {
                app.show(Tr("这条语音找不到了"))
                return
            }
            voicePlayer.toggle(id: message.id, url: url)
        }
    }

    /// 语音那个小喇叭（播放中变绿）
    private func speakerIcon(playing: Bool) -> some View {
        SVGIcon(markup: I.speaker, size: 20,
                color: playing ? C.green : C.bubbleText)
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
            BubbleShape(mine: mine, tail: showTail).fill(bubbleFill)
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
            BubbleShape(mine: mine, tail: showTail).fill(bubbleFill)
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
            BubbleShape(mine: mine, tail: showTail).fill(bubbleFill)
        )
    }
}

/* ============================================================ 地图小图 */

/* ============================================================
   图片气泡（照微信）：保持原比例，最长边不超过 200；图还没加载出来时
   先按 150 的方块占位，加载完自动变成真实比例。点一下看大图。
   ============================================================ */

struct ImageBubble: View {
    let path: String
    let onTap: () -> Void

    @State private var box: CGSize? = nil

    var body: some View {
        let size = box ?? CGSize(width: 150, height: 150)
        RemoteImage(path: path, icon: "photo", onLoaded: { img in
            if box == nil { box = ImageBubble.thumb(img.size) }
        })
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    /// 微信的缩略图尺寸：按比例缩到最长边 200；太小的图给到 60 以上好点
    static func thumb(_ size: CGSize) -> CGSize {
        let w = max(1, size.width)
        let h = max(1, size.height)
        let scale = min(1, 200 / max(w, h))
        var tw = (w * scale).rounded()
        var th = (h * scale).rounded()
        if max(tw, th) < 60 {
            let k = 60 / max(tw, th)
            tw = (tw * k).rounded()
            th = (th * k).rounded()
        }
        return CGSize(width: min(200, tw), height: min(200, th))
    }
}

enum Tiles {
    static func url(lat: Double, lng: Double, z: Int = 15) -> String {
        let n = pow(2.0, Double(z))
        let x = Int(floor((lng + 180) / 360 * n))
        let rad = lat * .pi / 180
        let y = Int(floor((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n))
        return "https://tile.openstreetmap.org/\(z)/\(x)/\(y).png"
    }
}
