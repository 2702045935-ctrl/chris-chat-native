import SwiftUI

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 12) {
            Avatar(path: chat.avatar ?? "", size: 48, radius: 5)
                .overlay(alignment: .topTrailing) {
                    UnreadBadge(count: chat.unreadCount).offset(x: 6, y: -6)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(chat.name)
                    .font(.system(size: 17))
                    .foregroundColor(Brand.label)
                    .lineLimit(1)
                Text(chat.lastMessage?.preview ?? "")
                    .font(.system(size: 14))
                    .foregroundColor(Brand.subLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 0) {
                Text(TimeFmt.list(chat.lastMessage?.createdAt ?? chat.updatedAt))
                    .font(.system(size: 12))
                    .foregroundColor(Brand.timeLabel)
                Spacer(minLength: 0)
            }
            .frame(height: 46)
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
        .contentShape(Rectangle())
    }
}

struct ChatsView: View {
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var confirmHide: Chat?
    @State private var confirmDelete: Chat?

    private var list: [Chat] {
        guard !keyword.isEmpty else { return app.chats }
        return app.chats.filter {
            $0.name.contains(keyword) || (($0.lastMessage?.preview ?? "").contains(keyword))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                SearchBar(text: $keyword)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

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
                            .listRowBackground(chat.pinned == true
                                               ? Color.dyn(0xF2F2F2, 0x2C2C2E)
                                               : Brand.cellBg)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    confirmDelete = chat
                                } label: {
                                    Text("删除")
                                }
                                .tint(Brand.red)

                                Button {
                                    confirmHide = chat
                                } label: {
                                    Text("不显示")
                                }
                                .tint(Brand.orange)

                                Button {
                                    markUnread(chat)
                                } label: {
                                    Text("标为未读")
                                }
                                .tint(Brand.green)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Brand.cellBg)
                    .refreshable { await app.loadChats() }
                }
            }
            .background(Brand.cellBg)
            .navigationTitle("微信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        app.show("发起群聊 / 加好友排在下一批")
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17))
                    }
                }
            }
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
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
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundColor(Brand.subLabel)
            Text(app.loadError ?? "正在加载会话…")
                .font(.system(size: 14))
                .foregroundColor(Brand.subLabel)
            if app.loadError != nil {
                Button("重试") { Task { await app.loadChats() } }
                    .font(.system(size: 15))
                    .foregroundColor(Brand.green)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Brand.cellBg)
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

