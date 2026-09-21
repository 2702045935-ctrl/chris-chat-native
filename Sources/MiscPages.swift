import SwiftUI

/* ============================================================ 收藏 */

struct FavoritesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [[String: Any]] = []
    @State private var loading = true
    @State private var viewerPaths: [String] = []
    @State private var viewerIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: L("收藏"), back: { dismiss() })
            List {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                        .listRowBackground(C.cardBg)
                } else if items.isEmpty {
                    Text(L("还没有收藏。聊天里长按消息「收藏」就会出现在这里。"))
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
                                .contentShape(Rectangle())
                                .onTapGesture { openPhoto(content) }
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
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .overlay {
            if let i = viewerIndex, !viewerPaths.isEmpty {
                PhotoPager(paths: viewerPaths, startIndex: i) { viewerIndex = nil }
            }
        }
    }

    /// 收藏里的图片也能点开看大图
    private func openPhoto(_ path: String) {
        let all = items.filter { (($0["kind"] as? String) ?? "") == "image" }
            .compactMap { $0["content"] as? String }
        guard !all.isEmpty else { return }
        viewerPaths = all
        viewerIndex = all.firstIndex(of: path) ?? 0
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
    @State private var pendingImage = ""
    @State private var packs: [StickerPack] = []
    @State private var tab = -1

    /// 当前这一页要显示的表情：-1 = 全部；否则是某一个表情包
    private var list: [String] {
        if tab >= 0 && tab < packs.count {
            return packs[tab].stickers ?? []
        }
        var all: [String] = []
        packs.forEach { all.append(contentsOf: $0.stickers ?? []) }
        return all.isEmpty ? emojiAll : all
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: L("表情"), back: { dismiss() })

            // 表情包分类（网页版：全部 + 后台配的每个包）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tabButton(-1, "🙂", "全部")
                    ForEach(packs.indices, id: \.self) { i in
                        tabButton(i, packs[i].icon ?? "😀", packs[i].name ?? "表情包")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(list.indices, id: \.self) { i in
                        let s = list[i]
                        Button {
                            if s.hasPrefix("http") || s.hasPrefix("/uploads") {
                                pendingImage = s
                                pending = ""
                            } else {
                                pending = s
                                pendingImage = ""
                            }
                            picking = true
                        } label: {
                            Group {
                                if s.hasPrefix("http") || s.hasPrefix("/uploads") {
                                    RemoteImage(path: s)
                                } else {
                                    Text(s).font(pf(30))
                                }
                            }
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
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            packs = (try? await API.shared.stickerPacks()) ?? []
        }
        .confirmationDialog(L("发给谁？"), isPresented: $picking, titleVisibility: .visible) {
            ForEach(app.chats.prefix(12)) { chat in
                Button("发给 \(chat.name)") {
                    send(to: chat.id)
                }
            }
            Button(L("取消"), role: .cancel) { }
        }
    }

    private func send(to chatId: String) {
        let text = pending
        let img = pendingImage
        pending = ""
        pendingImage = ""
        guard !text.isEmpty || !img.isEmpty else { return }
        Task {
            _ = try? await API.shared.send(chatId: chatId,
                                           kind: img.isEmpty ? "text" : "image",
                                           content: img.isEmpty ? text : img)
            await app.loadChats()
            app.show(L("表情已发出"))
        }
    }

    private func tabButton(_ index: Int, _ icon: String, _ name: String) -> some View {
        Button {
            tab = index
        } label: {
            HStack(spacing: 4) {
                Text(icon).font(pf(15))
                Text(name).font(pf(13))
            }
            .foregroundColor(tab == index ? .white : C.label)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(tab == index ? C.green : C.cardBg)
            )
        }
        .buttonStyle(.plain)
    }
}

/* ============================================================ 状态（我 → ＋状态） */

struct StatusView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cats: [StatusCategory] = []
    @State private var cat = 0

    private var items: [StatusItem] {
        guard cat < cats.count else { return [] }
        return cats[cat].items ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: L("状态"), back: { dismiss() })

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(cats.indices, id: \.self) { i in
                        Button {
                            cat = i
                        } label: {
                            Text(cats[i].name ?? "分类")
                                .font(pf(13.5))
                                .foregroundColor(cat == i ? .white : C.label)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 15)
                                    .fill(cat == i ? C.green : C.cardBg))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(items.indices, id: \.self) { i in
                        let it = items[i]
                        Button {
                            pick(it)
                        } label: {
                            VStack(spacing: 6) {
                                Text(it.icon ?? "🙂").font(pf(30))
                                Text(it.label ?? "状态")
                                    .font(pf(13))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 96)
                            .background(
                                LinearGradient(colors: [Color(hexString: it.color ?? "#6F8A38"),
                                                        Color(hexString: it.color2 ?? it.color ?? "#6F8A38")],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

                Button {
                    clear()
                } label: {
                    Text(L("取消当前状态"))
                        .font(pf(15))
                        .foregroundColor(C.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(C.cardBg)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 30)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            cats = (try? await API.shared.statusCategories()) ?? []
        }
    }

    private func pick(_ item: StatusItem) {
        Task {
            await API.shared.setMood(item)
            app.me = try? await API.shared.me()
            app.show(L("状态更新了"))
            dismiss()
        }
    }

    private func clear() {
        Task {
            await API.shared.setMood(nil)
            app.me = try? await API.shared.me()
            app.show(L("状态已取消"))
            dismiss()
        }
    }
}

/* ============================================================ 卡包 / 作品 */

struct WalletCardView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: L("卡包"), back: { dismiss() })
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
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
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
    @State private var works: [FeedItem] = []
    @State private var playing: FeedItem?
    @State private var loading = true
    /// 三列方块网格（抖音个人主页那样）
    private let cols = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: L("作品"), back: { dismiss() })
            if loading && works.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if works.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "rectangle.stack").font(pf(34)).foregroundColor(C.subLabel)
                    Text(L("还没有作品")).font(pf(15)).foregroundColor(C.subLabel)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 3) {
                        ForEach(works) { w in
                            Button { playing = w } label: { tile(w) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(item: $playing) { w in
            FeedPlayerSheet(item: w, all: works)
        }
        .task {
            /* 「作品」这一页只放我自己发布的（别人的作品在视频号里刷） */
            let mine = (try? await API.shared.myFeedItems()) ?? []
            works = mine.isEmpty ? ((try? await API.shared.feedItems()) ?? []).filter { $0.mine == true } : mine
            loading = false
        }
    }

    /// 一个方块：有封面就显示封面，没有就用深色底 + 播放图标 + 点赞数
    private func tile(_ w: FeedItem) -> some View {
        ZStack {
            if !(w.cover ?? "").isEmpty {
                RemoteImage(path: w.cover ?? "")
            } else {
                LinearGradient(colors: [Color(hex: 0x2A2A2E), Color(hex: 0x141416)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if (w.cover ?? "").isEmpty {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.85))
            }
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text("\(w.likes ?? 0)").font(pf(11.5, .medium))
                    Spacer(minLength: 0)
                    if w.mine == true {
                        Text(L("我的")).font(pf(10.5)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(C.green))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .contentShape(Rectangle())
    }
}
