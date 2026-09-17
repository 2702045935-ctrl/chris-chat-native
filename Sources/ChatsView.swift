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
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(C.name)
                    .lineLimit(1)
                Text(chat.lastMessage?.preview ?? "")
                    .font(.system(size: 14))
                    .foregroundColor(C.preview)
                    .lineLimit(1)
                    .padding(.top, 3)
            }

            Spacer(minLength: 6)

            Text(TimeFmt.list(chat.lastMessage?.createdAt ?? chat.updatedAt))
                .font(.system(size: 12))
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

struct ChatsView: View {
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var confirmHide: Chat?
    @State private var confirmDelete: Chat?
    @State private var path = NavigationPath()
    @State private var plusMenu = false

    private var list: [Chat] {
        guard !keyword.isEmpty else { return app.chats }
        return app.chats.filter {
            $0.name.contains(keyword) || (($0.lastMessage?.preview ?? "").contains(keyword))
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavBar(title: "微信") {
                    Button {
                        plusMenu = true
                    } label: {
                        SVGIcon(markup: I.plusRing, size: 30, color: C.ringInk)
                            .padding(.leading, 2)
                            .padding(.trailing, 7)
                            .frame(height: L.navH)
                    }
                    .buttonStyle(.plain)
                }

                SearchBoxCenter(text: $keyword)
                    .padding(L.searchPad)
                    .background(C.pageBg)

                if app.chats.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(list) { chat in
                            NavigationLink(value: chat) {
                                ChatRow(chat: chat)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(chat.pinned == true ? C.pinnedBg : C.chatRowBg)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    confirmDelete = chat
                                } label: {
                                    Text("删除")
                                }
                                .tint(C.red)

                                Button {
                                    confirmHide = chat
                                } label: {
                                    Text("不显示")
                                }
                                .tint(C.orange)

                                Button {
                                    markUnread(chat)
                                } label: {
                                    Text("标为未读")
                                }
                                .tint(C.green)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, 0)
                    .scrollContentBackground(.hidden)
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
        .confirmationDialog("不显示该聊天？", isPresented: Binding(
            get: { confirmHide != nil },
            set: { if !$0 { confirmHide = nil } }
        ), titleVisibility: .visible) {
            Button("不显示该聊天") {
                if let c = confirmHide { hide(c) }
                confirmHide = nil
            }
            Button("清空聊天记录同时不显示") {
                if let c = confirmHide { remove(c) }
                confirmHide = nil
            }
            Button("取消", role: .cancel) { confirmHide = nil }
        }
        .confirmationDialog("删除该聊天？", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let c = confirmDelete { remove(c) }
                confirmDelete = nil
            }
            Button("取消", role: .cancel) { confirmDelete = nil }
        }
        .task { await app.loadChats() }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(app.loadError ?? "正在加载会话…")
                .font(.system(size: 14))
                .foregroundColor(C.subLabel)
            if app.loadError != nil {
                Button("重试") { Task { await app.loadChats() } }
                    .font(.system(size: 15))
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

    private func hide(_ chat: Chat) {
        Task {
            await API.shared.hideChat(chatId: chat.id)
            await app.loadChats()
            app.show("已不显示该聊天")
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
