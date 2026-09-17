import SwiftUI

/// 微信气泡：圆角 6 + 左上/右上那个 5px 小尖角
struct BubbleShape: Shape {
    let mine: Bool
    var radius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: radius)
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

struct ChatDetailView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [Message] = []
    @State private var input = ""
    @State private var loading = true
    @FocusState private var focused: Bool

    private var myId: String { app.me?.id ?? "" }

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
                            .font(.system(size: 22))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }

                messageList
            }
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: chat.id) {
            await load(initial: true)
            await API.shared.markRead(chatId: chat.id)
            await app.loadChats()
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
                                    .font(.system(size: 14))
                                    .foregroundColor(C.msgTime)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 12)
                                    .padding(.bottom, 16)
                            }
                            MessageRow(message: message, mine: message.senderId == myId)
                                .padding(.bottom, 15)
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

    private func senderPath(_ message: Message) -> String {
        if let p = message.senderAvatar, !p.isEmpty { return p }
        return app.contact(for: message.senderId ?? "")?.avatarPath ?? ""
    }

    /* ---------------------------------------------------------- 输入栏 */

    private var composer: some View {
        HStack(spacing: 6) {
            Button {
                app.show("发语音排在下一批")
            } label: {
                SVGIcon(markup: I.voice, size: L.composerIcon, color: C.iconGray)
                    .frame(width: L.composerIconBox, height: L.composerIconBox)
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                TextField("", text: $input)
                    .focused($focused)
                    .font(.system(size: 17))
                    .foregroundColor(C.label)
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
                    app.show("表情 / 图片 / 转账面板排在下一批")
                } label: {
                    SVGIcon(markup: I.smile, size: L.composerIcon, color: C.iconGray)
                        .frame(width: L.composerIconBox, height: L.composerIconBox)
                }
                .buttonStyle(.plain)

                Button {
                    app.show("图片 / 转账 / 位置面板排在下一批")
                } label: {
                    SVGIcon(markup: I.plusCircle, size: L.composerIcon, color: C.iconGray)
                        .frame(width: L.composerIconBox, height: L.composerIconBox)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    send()
                } label: {
                    Text("发送")
                        .font(.system(size: 16, weight: .medium))
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

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return }
        input = ""
        Task {
            do {
                if let message = try await API.shared.send(chatId: chat.id, text: text) {
                    messages.append(message)
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发送失败")
            }
            await app.loadChats()
        }
    }
}

/* ============================================================ 单条消息 */

struct MessageRow: View {
    let message: Message
    let mine: Bool

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
            }

            if message.isRecalled {
                Text(mine ? "你撤回了一条消息" : "对方撤回了一条消息")
                    .font(.system(size: 12))
                    .foregroundColor(C.msgTime)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 5).fill(C.bubbleOther))
            } else {
                bubble
            }

            if !mine { Spacer(minLength: 60) }

            if mine {
                Spacer().frame(width: 9)
                Avatar(path: avatarPath, size: L.chatAvatar, radius: 6)
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.kindName {
        case "image":
            RemoteImage(path: message.body, icon: "photo")
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case "audio":
            card(icon: I.speaker, title: "语音", detail: "点击播放")
        case "transfer":
            card(icon: I.wallet, title: "转账", detail: message.body)
        case "gift":
            card(icon: I.star, title: "礼物", detail: message.body)
        case "location":
            card(icon: I.nearby, title: "位置", detail: message.body)
        default:
            Text(message.body)
                .font(.system(size: 17))
                .foregroundColor(C.bubbleText)
                .padding(.horizontal, L.bubblePadH)
                .padding(.vertical, L.bubblePadV)
                .background(
                    BubbleShape(mine: mine)
                        .fill(mine ? C.bubbleMine : C.bubbleOther)
                )
        }
    }

    private func card(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            SVGIcon(markup: icon, size: 20, color: mine ? C.bubbleText : C.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(C.bubbleText)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(C.subLabel)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, L.bubblePadH)
        .padding(.vertical, L.bubblePadV)
        .background(
            BubbleShape(mine: mine)
                .fill(mine ? C.bubbleMine : C.bubbleOther)
        )
    }
}
