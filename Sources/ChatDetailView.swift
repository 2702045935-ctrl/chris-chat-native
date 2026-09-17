import SwiftUI

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
            Brand.pageBg.ignoresSafeArea()
            if !backgroundPath.isEmpty {
                RemoteImage(path: backgroundPath).ignoresSafeArea()
            }

            VStack(spacing: 0) {
                messageList
                inputBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                }
            }
            ToolbarItem(placement: .principal) {
                Text(chat.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Brand.label)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    app.show("聊天设置排在下一批")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                }
            }
        }
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
                LazyVStack(spacing: 14) {
                    if loading && messages.isEmpty {
                        ProgressView().padding(.top, 40)
                    }
                    ForEach(messages) { message in
                        VStack(spacing: 14) {
                            if showTime(for: message) {
                                Text(TimeFmt.bubble(message.createdAt))
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.dyn(0xC0C0C0, 0x8E8E93))
                            }
                            MessageRow(message: message,
                                       mine: message.senderId == myId,
                                       avatar: avatarPath(message),
                                       name: displayName(message))
                        }
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _ in
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

    private func showTime(for message: Message) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return false }
        if index == 0 { return true }
        return TimeFmt.minutesBetween(messages[index - 1].createdAt, message.createdAt) >= 5
    }

    private func avatarPath(_ message: Message) -> String {
        if let p = message.senderAvatar, !p.isEmpty { return p }
        return app.contact(for: message.senderId ?? "")?.avatarPath ?? ""
    }

    private func displayName(_ message: Message) -> String {
        if let n = message.senderName, !n.isEmpty { return n }
        return app.contact(for: message.senderId ?? "")?.name ?? ""
    }

    /* ---------------------------------------------------------- 输入栏 */

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                app.show("发语音排在下一批")
            } label: {
                Image(systemName: "mic")
                    .font(.system(size: 19))
                    .foregroundColor(Brand.label)
                    .frame(width: 30, height: 30)
            }

            TextField("", text: $input)
                .focused($focused)
                .font(.system(size: 16))
                .foregroundColor(Brand.label)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Brand.cellBg))

            Button {
                app.show("表情面板排在下一批")
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 22))
                    .foregroundColor(Brand.label)
            }

            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    app.show("图片 / 转账 / 位置面板排在下一批")
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                        .foregroundColor(Brand.label)
                }
            } else {
                Button {
                    send()
                } label: {
                    Text("发送")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Brand.green))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Brand.barBg)
        .overlay(alignment: .top) { HairLine() }
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
    let avatar: String
    let name: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 56) }

            if !mine {
                Avatar(path: avatar, size: 40, radius: 4)
            }

            if message.isRecalled {
                Text(mine ? "你撤回了一条消息" : "\(name)撤回了一条消息")
                    .font(.system(size: 12))
                    .foregroundColor(Color.dyn(0xB0B0B0, 0x8E8E93))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.dyn(0xF0F0F0, 0x2C2C2E)))
            } else {
                bubble
            }

            if !mine { Spacer(minLength: 56) }

            if mine {
                Avatar(path: avatar, size: 40, radius: 4)
            }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.kindName {
        case "image":
            RemoteImage(path: message.body, icon: "photo")
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case "audio":
            card(icon: "mic.fill", title: "语音", detail: "点击播放")
        case "transfer":
            card(icon: "yensign.circle.fill", title: "转账", detail: message.body)
        case "gift":
            card(icon: "gift.fill", title: "礼物", detail: message.body)
        case "location":
            card(icon: "location.fill", title: "位置", detail: message.body)
        default:
            Text(message.body)
                .font(.system(size: 16))
                .foregroundColor(Color.dyn(0x000000, 0xEDEDED))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(mine ? Brand.bubbleMine : Brand.bubbleOther)
                )
        }
    }

    private func card(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(mine ? Color.dyn(0x2E7D32, 0xFFFFFF) : Brand.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color.dyn(0x181818, 0xEDEDED))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(Brand.subLabel)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(mine ? Brand.bubbleMine : Brand.bubbleOther)
        )
    }
}
