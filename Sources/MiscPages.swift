import SwiftUI

/* ============================================================ 收藏 */

struct FavoritesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [[String: Any]] = []
    @State private var loading = true
    @State private var viewerPaths: [String] = []
    @State private var viewerIndex: Int?
    /* 微信收藏页顶部：搜索框 + 类型筛选 */
    @State private var q = ""
    @State private var kindFilter = "all"

    private var shown: [[String: Any]] {
        let key = q.trimmingCharacters(in: .whitespaces)
        return items.filter { it in
            let kind = (it["kind"] as? String) ?? "text"
            if kindFilter == "image" && kind != "image" { return false }
            if kindFilter == "text" && kind == "image" { return false }
            if key.isEmpty { return true }
            let content = (it["content"] as? String) ?? ""
            return content.localizedCaseInsensitiveContains(key)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.searchIcon)
                TextField(Tr("搜索收藏"), text: $q)
                    .font(pf(14.5))
                if !q.isEmpty {
                    Button { q = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                            .foregroundColor(C.searchIcon)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.searchBg))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            HStack(spacing: 8) {
                chip(Tr("全部"), "all")
                chip(Tr("图片与视频"), "image")
                chip(Tr("文字"), "text")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .background(C.pageBg)
    }

    private func chip(_ title: String, _ key: String) -> some View {
        let on = (kindFilter == key)
        return Button { kindFilter = key } label: {
            Text(title)
                .font(pf(13.5))
                .foregroundColor(on ? .white : C.subLabel)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(on ? C.green : C.cardBg))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("收藏"), back: { dismiss() })
            header
            List {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                        .listRowBackground(C.cardBg)
                } else if items.isEmpty {
                    Text(Tr("还没有收藏。聊天里长按消息「收藏」就会出现在这里。"))
                        .font(pf(14))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(C.cardBg)
                }
                ForEach(shown.indices, id: \.self) { i in
                    let item = shown[i]
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

/* ============================================================
   表情（我 → 表情）—— 按微信那一页做：
   · 我的表情：我添加的表情包（点进去看这一包、可以移除）+ 我添加的单个表情（长按删除）
   · 表情商店：后台配的表情包，点「添加」进我的表情，点「移除」拿掉
   · 最近使用：用过的表情排在前面（表情面板也是先给最近用的）
   ============================================================ */
struct StickerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var shop: [StickerPack] = []
    @State private var mine = StickerMine()
    @State private var openPackId: String?
    @State private var confirmRemove: String?
    @State private var addingPhoto = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("表情"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    /* ---------- 我的表情 ---------- */
                    sectionTitle(Tr("我的表情"))

                    if !mine.recentList.isEmpty {
                        packRow(icon: "🕘", name: Tr("最近使用"), count: mine.recentList.count)
                            .opacity(0.9)
                        HairLine(inset: 56)
                    }

                    if mine.packList.isEmpty && mine.singleList.isEmpty {
                        Text(Tr("还没有添加表情，去下面的「表情商店」加几个"))
                            .font(pf(13.5))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .background(C.cardBg)
                    }

                    ForEach(mine.packList, id: \.self) { p in
                        Button { openPackId = p.id } label: {
                            packRow(icon: p.icon ?? "😀", name: p.name ?? "表情包",
                                    count: (p.stickers ?? []).count)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 56)
                    }

                    /* 我添加的单个表情 */
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Tr("添加的单个表情"))
                                .font(pf(15)).foregroundColor(C.label)
                            Spacer()
                            Button { addingPhoto = true } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                    Text(Tr("添加"))
                                }
                                .font(pf(14)).foregroundColor(C.green)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 44)

                        if !mine.singleList.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                                ForEach(mine.singleList, id: \.self) { s in
                                    Button { confirmRemove = s } label: {
                                        Group {
                                            if s.hasPrefix("http") || s.hasPrefix("/uploads") {
                                                RemoteImage(path: s, maxSide: 400)
                                            } else {
                                                Text(s).font(pf(28))
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 62)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(C.searchBg))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                        }
                    }
                    .background(C.cardBg)

                    Spacer().frame(height: 14)

                    /* ---------- 表情商店 ---------- */
                    sectionTitle(Tr("表情商店"))
                    ForEach(shop, id: \.self) { p in
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Text(p.icon ?? "😀").font(pf(26))
                                    .frame(width: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name ?? "表情包").font(pf(16)).foregroundColor(C.label)
                                    Text("\( (p.stickers ?? []).count ) 个表情")
                                        .font(pf(12.5)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 8)
                                if isAdded(p) {
                                    Button { removePack(p) } label: {
                                        Text(Tr("移除"))
                                            .font(pf(14)).foregroundColor(C.subLabel)
                                            .padding(.horizontal, 12).frame(height: 28)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(C.searchBg))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button { addPack(p) } label: {
                                        Text(Tr("添加"))
                                            .font(pf(14, .medium)).foregroundColor(.white)
                                            .padding(.horizontal, 12).frame(height: 28)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(C.green))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 62)
                            HairLine(inset: 56)
                        }
                        .background(C.cardBg)
                    }

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(isPresented: Binding(get: { openPackId != nil },
                                    set: { if !$0 { openPackId = nil } })) {
            if let p = (mine.packList + shop).first(where: { $0.id == openPackId }) {
                packDetail(p)
            }
        }
        .sheet(isPresented: $addingPhoto) {
            PhotoPicker { image in addSingle(image) }
        }
        .confirmationDialog(Tr("删除这个表情？"), isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        ), titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) {
                if let s = confirmRemove { removeSingle(s) }
                confirmRemove = nil
            }
            Button(Tr("取消"), role: .cancel) { confirmRemove = nil }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t).font(pf(13)).foregroundColor(C.subLabel)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(C.pageBg)
    }

    private func packRow(icon: String, name: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Text(icon).font(pf(24)).frame(width: 40)
            Text(name).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Text("\(count) 个").font(pf(13)).foregroundColor(C.subLabel)
            Chevron(size: 9, line: 1.6)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(C.cardBg)
        .contentShape(Rectangle())
    }

    /// 一个表情包的详情：看这一包有哪些表情，可以「移除」
    private func packDetail(_ p: StickerPack) -> some View {
        VStack(spacing: 0) {
            NavBar(title: p.name ?? "表情包", back: { openPackId = nil })
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach((p.stickers ?? []).indices, id: \.self) { i in
                        let s = (p.stickers ?? [])[i]
                        Group {
                            if s.hasPrefix("http") || s.hasPrefix("/uploads") {
                                RemoteImage(path: s, maxSide: 400)
                            } else {
                                Text(s).font(pf(34))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .background(RoundedRectangle(cornerRadius: 8).fill(C.cardBg))
                    }
                }
                .padding(16)
            }
            Button {
                removePack(p)
                openPackId = nil
            } label: {
                Text(Tr("移除这个表情包"))
                    .font(pf(16)).foregroundColor(C.red)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(C.cardBg)
            }
            .buttonStyle(.plain)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }

    /* ---------------------------------------------------------- 干活 */

    private func load() async {
        if let r = try? await API.shared.stickerShop() {
            shop = r.shop
            mine = r.mine
        }
        loading = false
    }

    private func isAdded(_ p: StickerPack) -> Bool {
        guard let id = p.id else { return false }
        return mine.packList.contains { $0.id == id }
    }

    private func addPack(_ p: StickerPack) {
        guard let id = p.id else { return }
        Task {
            await API.shared.addStickerPack(id)
            await load()
            app.show(Tr("已添加"))
        }
    }

    private func removePack(_ p: StickerPack) {
        guard let id = p.id else { return }
        Task {
            await API.shared.removeStickerPack(id)
            await load()
            app.show(Tr("已移除"))
        }
    }

    private func addSingle(_ image: UIImage) {
        Task {
            guard let url = try? await API.shared.upload(image: image) else { return }
            await API.shared.addSingleSticker(url)
            await load()
            app.show(Tr("已添加到我的表情"))
        }
    }

    private func removeSingle(_ s: String) {
        Task {
            await API.shared.removeSingleSticker(s)
            await load()
            app.show(Tr("已删除"))
        }
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
            NavBar(title: Tr("状态"), back: { dismiss() })

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
            Text(Tr(it.label ?? "状态"))
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
                    Text(Tr("取消当前状态"))
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
            app.show(Tr("状态更新了"))
            dismiss()
        }
    }

    private func clear() {
        Task {
            await API.shared.setMood(nil)
            app.me = try? await API.shared.me()
            app.show(Tr("状态已取消"))
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
            NavBar(title: Tr("卡包"), back: { dismiss() })
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
            NavBar(title: Tr("作品"), back: { dismiss() })
            if loading && works.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if works.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "rectangle.stack").font(pf(34)).foregroundColor(C.subLabel)
                    Text(Tr("还没有作品")).font(pf(15)).foregroundColor(C.subLabel)
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
                        Text(Tr("我的")).font(pf(10.5)).padding(.horizontal, 5).padding(.vertical, 1)
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
