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
    @State private var showFile = false
    @State private var showCall = false
    @State private var uploading = false

    @FocusState private var focused: Bool

    private var myId: String { app.me?.id ?? "" }
    private var isGroup: Bool { chat.type == "group" }

    private func displayName(_ message: Message) -> String {
        if let n = message.senderName, !n.isEmpty { return n }
        return app.contact(for: message.senderId ?? "")?.name ?? ""
    }

    private var backgroundPath: String {
        let v = app.me?.chatBackground ?? "auto"
        if v.isEmpty || v == "auto" { return "" }
        return v
    }

    var body: some View {
        ZStack {
            C.pageBg.ignoresSafeArea()
            if !backgroundPath.isEmpty {
                RemoteImage(path: backgroundPath).ignoresSafeArea()
            }

            VStack(spacing: 0) {
                NavBar(title: chat.name, back: { dismiss() }) {
                    Button {
                        app.show("聊天设置排在下一批")
                    } label: {
                        Text("⋯")
                            .font(pf(22))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }

                messageList
            }

            if uploading {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView("正在上传…")
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.cardBg))
                }
            }
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .swipeBack { dismiss() }
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
            TransferSheet(chat: chat) { amount, note, method, password in
                doTransfer(amount: amount, note: note, method: method, password: password)
            }
        }
        .fullScreenCover(isPresented: $showCall) {
            AICallView(chat: chat)
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
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
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
                                    .foregroundColor(C.msgTime)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 12)
                                    .padding(.bottom, 16)
                            }
                            MessageRow(message: message,
                                       mine: message.senderId == myId,
                                       senderName: (!isGroup || message.senderId == myId)
                                           ? "" : displayName(message))
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
                    app.show("按住说话排在下一批")
                } label: {
                    SVGIcon(markup: I.voice, size: L.composerIcon, color: C.iconGray)
                        .frame(width: L.composerIconBox, height: L.composerIconBox)
                }
                .buttonStyle(.plain)

                HStack(spacing: 0) {
                    TextField("", text: $input)
                        .focused($focused)
                        .font(pf(17))
                        .foregroundColor(C.label)
                        .onTapGesture { panel = .none }
                    SVGIcon(markup: I.speaker, size: 22, color: C.iconGray)
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
                        SVGIcon(markup: I.smile, size: L.composerIcon, color: C.iconGray)
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
                        SVGIcon(markup: I.plusCircle, size: L.composerIcon, color: C.iconGray)
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
        }
        .background(
            ZStack {
                C.tabBg.ignoresSafeArea(edges: .bottom)
                VStack(spacing: 0) {
                    Rectangle().fill(C.navLine).frame(height: 0.5)
                    Spacer()
                }
            }
        )
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
                showCall = true
            } else {
                app.show("和真人的实时语音/视频要装 WebRTC 组件（下一版），先用文字或图片聊")
            }
        case "voice":
            panel = .none
            app.show("按住说话：请在电脑版或聊天页右上角使用")
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

    private func sendText() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        input = ""
        send(kind: "text", content: text)
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

    /* ---------------------------------------------------------- 数据 */

    private func load(initial: Bool) async {
        do {
            let result = try await API.shared.messages(chatId: chat.id, limit: 40)
            let same = result.messages.count == messages.count
                && result.messages.last?.id == messages.last?.id
            if initial || !same {
                messages = result.messages
            }
        } catch {
            if initial { app.show("聊天记录加载失败") }
        }
        loading = false
    }
}

/* ============================================================ 单条消息 */

struct MessageRow: View {
    let message: Message
    let mine: Bool
    var senderName: String = ""

    @EnvironmentObject var app: AppState

    private var avatarPath: String {
        if let p = message.senderAvatar, !p.isEmpty { return p }
        return app.contact(for: message.senderId ?? "")?.avatarPath ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 60) }

            if !mine {
                Avatar(path: avatarPath, size: L.chatAvatar, radius: 6)
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

        case "location":
            locationBubble

        case "transfer":
            transferBubble

        case "gift":
            giftBubble

        case "file":
            fileBubble

        case "audio":
            card(icon: I.speaker, title: "语音", detail: "点击播放")

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
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "yensign.circle.fill")
                    .font(pf(26))
                    .foregroundColor(Color(hex: 0xFFFFFF))
                VStack(alignment: .leading, spacing: 2) {
                    Text("¥\(String(format: "%.2f", amount))")
                        .font(pf(19, .medium))
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
        .background(Color(hex: 0xFA9D3C))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
                Text("¥\(String(format: "%.0f", price))").font(pf(12)).foregroundColor(C.red)
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
