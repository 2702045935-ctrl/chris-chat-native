import SwiftUI

/* ============================================================ 收藏 */

struct FavoritesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [[String: Any]] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "收藏", back: { dismiss() })
            List {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                        .listRowBackground(C.cardBg)
                } else if items.isEmpty {
                    Text("还没有收藏。聊天里长按消息「收藏」就会出现在这里。")
                        .font(pf(14))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(C.cardBg)
                }
                ForEach(items.indices, id: \.self) { i in
                    let item = items[i]
                    let kind = (item["kind"] as? String) ?? "text"
                    let content = (item["content"] as? String) ?? ""
                    HStack(spacing: 12) {
                        if kind == "image" {
                            RemoteImage(path: content)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Text(content)
                                .font(pf(15))
                                .foregroundColor(C.label)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(C.cardBg)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(C.cardBg)
            .refreshable { await load() }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .task { await load() }
    }

    private func load() async {
        items = await API.shared.favorites()
        loading = false
    }
}

/* ============================================================ 表情 */

struct StickerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    @State private var pending = ""

    private let perPage = 32
    private var pages: [[String]] {
        stride(from: 0, to: emojiAll.count, by: perPage).map { start in
            Array(emojiAll[start..<min(start + perPage, emojiAll.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "表情", back: { dismiss() })
            Text("点一个表情，挑个好友发过去")
                .font(pf(13))
                .foregroundColor(C.subLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(emojiAll.indices, id: \.self) { i in
                        Button {
                            pending = emojiAll[i]
                            picking = true
                        } label: {
                            Text(emojiAll[i])
                                .font(pf(30))
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(RoundedRectangle(cornerRadius: 8).fill(C.cardBg))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                Spacer().frame(height: 24)
            }
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .confirmationDialog("发给谁？", isPresented: $picking, titleVisibility: .visible) {
            ForEach(app.chats.prefix(12)) { chat in
                Button("发给 \(chat.name)") {
                    send(to: chat.id)
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private func send(to chatId: String) {
        guard !pending.isEmpty else { return }
        let text = pending
        pending = ""
        Task {
            _ = try? await API.shared.send(chatId: chatId, kind: "text", content: text)
            await app.loadChats()
            app.show("表情已发出")
        }
    }
}

/* ============================================================ 卡包 / 作品 */

struct WalletCardView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "卡包", back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        row("零钱", "¥\(String(format: "%.2f", app.me?.balance ?? 0))")
                        HairLine(inset: 16)
                        row("建设银行储蓄卡", "尾号 2125")
                        HairLine(inset: 16)
                        row("单笔转账限额", "¥20000")
                    }
                    .padding(.top, 8)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(pf(17)).foregroundColor(C.label)
            Spacer()
            Text(value).font(pf(15)).foregroundColor(C.subLabel)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

struct WorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "作品", back: { dismiss() })
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "rectangle.stack")
                    .font(pf(34))
                    .foregroundColor(C.subLabel)
                Text("还没有作品")
                    .font(pf(15))
                    .foregroundColor(C.subLabel)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }
}
