import SwiftUI

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(alignment: .top, spacing: L.rowGap) {
            Avatar(path: chat.avatar ?? "", size: L.avatar, radius: 6)
                .overlay(alignment: .topTrailing) {
                    UnreadBadge(count: chat.unreadCount)
                        .offset(x: 12, y: -8)
                }

            VStack(alignment: .leading, spacing: 0) {
                Text(chat.name)
                    .font(pf(L.rowNameSize))
                    .foregroundColor(C.name)
                    .lineLimit(1)
                Text(chat.lastMessage?.preview ?? "")
                    .font(pf(L.rowPreviewSize))
                    .foregroundColor(C.preview)
                    .lineLimit(1)
                    .padding(.top, 3)
            }

            Spacer(minLength: 6)

            Text(TimeFmt.list(chat.lastMessage?.createdAt ?? chat.updatedAt))
                .font(pf(L.rowTimeSize))
                .foregroundColor(C.time)
                .padding(.top, 2)
                .fixedSize()
        }
        .padding(.leading, L.rowPadL)
        .padding(.trailing, L.rowPadR)
        .frame(height: L.rowH)
        .contentShape(Rectangle())
    }
}

/* ============================================================
   会话行 + 左滑三级操作（完全照网页版）：
   ① 左滑露出 标为未读(绿) / 不显示(橙) / 删除(红)，三个各 83 宽，整条 249
   ② 点「不显示」→ 这一条撑满 249 变成「不显示该聊天」（橙），再点一下才执行
   ③ 点「删除」→ 这一条撑满 249 变红「清空记录同时不显示聊天」，再点一下才执行
   拖过 289 会预览第二层；点别处整条收回去。
   ============================================================ */

struct SwipeChatRow: View {
    enum Mode { case none, hideConfirm, delConfirm }

    let chat: Chat
    var onOpen: () -> Void
    var onUnread: () -> Void
    var onHide: (Bool) -> Void      // true = 连记录一起清掉
    var onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    @State private var mode: Mode = .none
    @State private var dragging = false

    /// 三个按钮的尺寸：和原版微信一致（每个 80 宽、整行高 72、17 号白字）
    /// 想微调就改 ui.json 里的 swipeBtnW / swipeFont
    private var btnW: CGFloat { UIConfig.num("swipeBtnW", 80) }
    private var btnFont: CGFloat { UIConfig.num("swipeFont", 17) }
    private var fullW: CGFloat { btnW * 3 }

    private var rowBg: Color { chat.pinned == true ? C.pinnedBg : C.chatRowBg }

    var body: some View {
        ZStack(alignment: .trailing) {
            /* ① 行内容：跟着手指往左推 */
            ChatRow(chat: chat)
                .frame(width: L.width, height: L.rowH, alignment: .leading)
                .background(rowBg)
                .overlay(alignment: .bottom) { HairLine(inset: L.dividerLeft) }
                .offset(x: offset)
                .contentShape(Rectangle())
                .onTapGesture {
                    if offset != 0 { close() } else { onOpen() }
                }
                .simultaneousGesture(dragGesture)
                .zIndex(1)

            /* ② 操作按钮：画在最上层，只露出滑开的那一块 —— 这样点一定点得到 */
            actionButtons
                .frame(width: fullW, height: L.rowH, alignment: .trailing)
                .frame(width: max(0, -offset), height: L.rowH, alignment: .trailing)
                .clipped()
                .allowsHitTesting(offset != 0)
                .zIndex(2)
        }
        .frame(width: L.width, height: L.rowH, alignment: .leading)
        .clipped()
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            actionButton("标为未读", Color(hex: 0x07C160), mode == .none ? btnW : 0) {
                onUnread()
                close()
            }
            actionButton(mode == .hideConfirm ? "不显示该聊天" : "不显示",
                         Color(hex: 0xFA9D3C),
                         mode == .hideConfirm ? fullW : (mode == .none ? btnW : 0)) {
                if mode == .hideConfirm {
                    onHide(false)
                    close()
                } else {
                    mode = .hideConfirm
                    withAnimation(.easeOut(duration: 0.18)) { offset = -fullW }
                }
            }
            actionButton(mode == .delConfirm ? "清空记录同时不显示聊天" : "删除",
                         Color(hex: mode == .delConfirm ? 0xE75E58 : 0xFA5151),
                         mode == .delConfirm ? fullW : (mode == .none ? btnW : 0)) {
                if mode == .delConfirm {
                    onDelete()
                    close()
                } else {
                    mode = .delConfirm
                    withAnimation(.easeOut(duration: 0.18)) { offset = -fullW }
                }
            }
        }
    }

    private func actionButton(_ title: String, _ bg: Color, _ width: CGFloat,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(pfExact(btnFont))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: max(0, width), height: L.rowH)
                .background(bg)
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !dragging {
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragging = true
                    startOffset = offset
                }
                var x = startOffset + value.translation.width
                x = min(0, max(-fullW - 140, x))
                offset = x
                // 拖过 289 预览第二层（那一条撑满 249，变成「不显示该聊天」）
                if -x > fullW + 40 && mode == .none {
                    mode = .hideConfirm
                } else if -x < fullW - 9 && mode == .hideConfirm {
                    mode = .none
                }
            }
            .onEnded { _ in
                dragging = false
                if -offset < 46 {
                    close()
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { offset = -fullW }
                }
            }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) {
            offset = 0
            mode = .none
        }
    }
}

/* ============================================================ 微信（会话列表） */

struct ChatsView: View {
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var path = NavigationPath()
    @State private var plusMenu = false
    @State private var openRow: String?

    private var list: [Chat] {
        guard !keyword.isEmpty else { return app.chats }
        return app.chats.filter {
            $0.name.contains(keyword) || (($0.lastMessage?.preview ?? "").contains(keyword))
        }
    }

    /// 和网页版一样：有未读时标题变成「微信(3)」
    private var navTitle: String {
        let total = app.chats.reduce(0) { $0 + ($1.unread ?? 0) }
        return total > 0 ? "微信(\(total))" : "微信"
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavBar(title: navTitle) {
                    Button {
                        plusMenu = true
                    } label: {
                        FlexIcon(custom: IconOverrides.custom("nav.plus"),
                                 size: UIConfig.num("navPlusSize", 20),
                                 color: C.label, symbol: "plus")
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }

                SearchBoxCenter(text: $keyword)
                    .padding(L.searchPad)
                    .background(C.pageBg)

                if app.chats.isEmpty {
                    emptyView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { chat in
                                SwipeChatRow(
                                    chat: chat,
                                    onOpen: { path.append(chat) },
                                    onUnread: { markUnread(chat) },
                                    onHide: { clear in hide(chat, clear: clear) },
                                    onDelete: { remove(chat) }
                                )
                            }
                        }
                    }
                    .background(C.chatRowBg)
                    .refreshable { await app.loadChats() }
                }
            }
            .background(C.pageBg.ignoresSafeArea(edges: .bottom))
            .background(C.navBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
            .navigationDestination(for: String.self) { key in
                if key == "newGroup" {
                    GroupCreateView { chat in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { path.append(chat) }
                    }
                } else if key == "addFriend" {
                    AddFriendView()
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        .confirmationDialog("", isPresented: $plusMenu, titleVisibility: .hidden) {
            Button("发起群聊") { path.append("newGroup") }
            Button("加好友") { path.append("addFriend") }
            Button("取消", role: .cancel) { }
        }
        .task { await app.loadChats() }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(app.loadError ?? "正在加载会话…")
                .font(pf(14))
                .foregroundColor(C.subLabel)
            if app.loadError != nil {
                Button("重试") { Task { await app.loadChats() } }
                    .font(pf(15))
                    .foregroundColor(C.green)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(C.chatRowBg)
    }

    private func markUnread(_ chat: Chat) {
        Task {
            await API.shared.markUnread(chatId: chat.id)
            await app.loadChats()
            app.show("已标为未读")
        }
    }

    private func hide(_ chat: Chat, clear: Bool) {
        Task {
            if clear {
                await API.shared.deleteChat(chatId: chat.id)
            } else {
                await API.shared.hideChat(chatId: chat.id)
            }
            await app.loadChats()
            app.show(clear ? "已清空记录并设为不显示" : "已不显示该聊天")
        }
    }

    private func remove(_ chat: Chat) {
        Task {
            await API.shared.deleteChat(chatId: chat.id)
            await app.loadChats()
            app.show("已删除")
        }
    }
}
