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

/* ============================================================
   状态（我 → ＋状态）——照微信那套：
     · 上面一条输入区：左边是挑中的状态图标，右边「说点什么」写一句（最多 30 字）
     · 下面按后台配的分类，一组一张卡，一格一个状态
     · 右上角「就这样」保存；已经设了状态的，底部可以「结束状态」
   状态 24 小时后自己消失（服务端算的），点自己那一条能看到「谁看过我」。
   ============================================================ */

struct StatusView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cats: [StatusCategory] = []
    @State private var picked: StatusItem? = nil
    @State private var pickedColor = ""
    @State private var caption = ""
    @State private var saving = false
    @FocusState private var typing: Bool
    /// 我的状态详情（还剩几小时 + 谁看过）
    @State private var myStatus: API.MyStatus? = nil

    /// 现在有没有状态（有的话底部给「结束状态」）
    private var hasMood: Bool {
        !((app.me?.moodText ?? "").isEmpty && (app.me?.moodIcon ?? "").isEmpty)
    }

    private let cols = [GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("状态"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(Tr("就这样"))
                        .font(pf(15, .medium))
                        .foregroundColor(picked == nil ? C.subLabel : C.green)
                        .padding(.horizontal, 16)
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)
                .disabled(picked == nil || saving)
            }

            ScrollView {
                VStack(spacing: 10) {
                    composeRow
                    if hasMood, let ms = myStatus { myStatusCard(ms) }
                    ForEach(cats.indices, id: \.self) { i in
                        section(cats[i])
                    }
                    if hasMood { endRow }
                    Spacer().frame(height: 30)
                }
                .padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            await load()
            myStatus = try? await API.shared.myStatus()
        }
    }

    /* ---------------------------------------------------------- 上面那条输入区 */

    /// 已经设了状态时显示：还剩几小时 + 谁看过我
    private func myStatusCard(_ ms: API.MyStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(ms.moodIcon ?? "").font(pf(18))
                Text(ms.moodText ?? "").font(pf(15, .medium)).foregroundColor(C.label)
                Spacer(minLength: 6)
                if let h = ms.hoursLeft {
                    Text(h <= 0 ? Tr("马上过期") : (Tr("还剩 ") + "\(h)" + Tr(" 小时")))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                }
            }
            if let views = ms.views, !views.isEmpty {
                Text(Tr("谁看过我的状态") + "（\(views.count)）")
                    .font(pf(12.5)).foregroundColor(C.subLabel)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(views) { v in
                            VStack(spacing: 4) {
                                Avatar(path: v.avatar ?? "", size: 36, radius: 18)
                                Text(v.name ?? "").font(pf(11)).foregroundColor(C.subLabel).lineLimit(1)
                            }
                            .frame(width: 46)
                        }
                    }
                }
            } else {
                Text(Tr("还没有人看过")).font(pf(12.5)).foregroundColor(C.subLabel)
            }
        }
        .padding(14)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var composeRow: some View {
        HStack(spacing: 10) {
            moodBox
            TextField("", text: $caption, prompt: Text(Tr("说点什么…")).foregroundColor(C.subLabel))
                .font(pf(14.5))
                .foregroundColor(C.label)
                .focused($typing)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Capsule().fill(C.cardBg))
                .onChange(of: caption) { v in
                    if v.count > 30 { caption = String(v.prefix(30)) }
                }
        }
        .padding(.horizontal, 12)
    }

    private var moodBox: some View {
        let icon = picked?.icon ?? ""
        let on = picked != nil
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? AnyShapeStyle(tileGradient(picked?.color ?? pickedColor))
                         : AnyShapeStyle(C.cardBg))
                .frame(width: 44, height: 44)
            if on {
                Text(icon.isEmpty ? "🙂" : icon).font(pf(22))
            } else {
                Text("＋").font(pf(20)).foregroundColor(C.subLabel)
            }
        }
    }

    /* ---------------------------------------------------------- 一组状态 */

    private func section(_ c: StatusCategory) -> some View {
        let title = c.name ?? ""
        let items = c.items ?? []
        let catColor = MoodColor.clean(c.color)
        return VStack(alignment: .leading, spacing: 9) {
            Text(Tr(title))
                .font(pf(13))
                .foregroundColor(C.subLabel)
                .padding(.leading, 15)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(items, id: \.self) { it in
                    tile(it, fallback: catColor)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 12)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func tile(_ it: StatusItem, fallback: String) -> some View {
        let own = MoodColor.clean(it.color)
        let base = own.isEmpty ? (fallback.isEmpty ? "#6F8A38" : fallback) : own
        let on = (picked?.id ?? "-") == (it.id ?? "?")
        return Button { pick(it, base: base) } label: {
            VStack(spacing: 4) {
                Text(it.icon ?? "🙂").font(pf(24))
                Text(Tr(it.label ?? "状态"))
                    .font(pf(12))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(tileGradient(base))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white, lineWidth: on ? 2 : 0))
        }
        .buttonStyle(.plain)
    }

    /// 格子的底色：主色 + 自动调亮的第二个色做渐变
    private func tileGradient(_ raw: String) -> LinearGradient {
        let c1 = MoodColor.clean(raw)
        let base = c1.isEmpty ? "#6F8A38" : c1
        let c2 = MoodColor.shift(base, to: true)
        return LinearGradient(colors: [Color(hexString: base),
                                       Color(hexString: c2.isEmpty ? base : c2)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var endRow: some View {
        Button { endMood() } label: {
            Text(Tr("结束状态"))
                .font(pf(15.5))
                .foregroundColor(C.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(C.cardBg)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    /* ---------------------------------------------------------- 动作 */

    private func load() async {
        cats = (try? await API.shared.statusCategories()) ?? []
        if hasMood {
            pickedColor = MoodColor.clean(app.me?.moodColor)
            caption = app.me?.moodCaption ?? ""
        }
    }

    /// 挑一个：微信挑完就把光标放到「说点什么」，不想写就直接点「就这样」
    private func pick(_ it: StatusItem, base: String) {
        picked = it
        pickedColor = base
        typing = true
    }

    private func save() {
        guard let it = picked, !saving else { return }
        saving = true
        Task {
            await API.shared.setMood(it, caption: caption, fallbackColor: pickedColor)
            app.me = try? await API.shared.me()
            app.show(Tr("状态更新了"))
            saving = false
            dismiss()
        }
    }

    private func endMood() {
        Task {
            await API.shared.setMood(nil)
            app.me = try? await API.shared.me()
            app.show(Tr("状态已取消"))
            dismiss()
        }
    }
}

/* ============================================================
   我的状态详情（微信里点自己那条状态进来的）
   大卡片（图标 + 状态名 + 说点什么 + 还剩 X 小时）+「谁看过我」+ 结束状态
   ============================================================ */

struct StatusDetailView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: MyStatus? = nil
    @State private var editing = false

    private var icon: String { info?.moodIcon ?? app.me?.moodIcon ?? "" }
    private var label: String { info?.moodLabel ?? app.me?.moodLabel ?? app.me?.moodText ?? "" }
    private var note: String { info?.moodCaption ?? app.me?.moodCaption ?? "" }
    private var c1: String {
        let mine = MoodColor.clean(info?.moodColor)
        return mine.isEmpty ? MoodColor.clean(app.me?.moodColor) : mine
    }
    private var c2: String {
        let mine = MoodColor.clean(info?.moodColor2)
        return mine.isEmpty ? MoodColor.clean(app.me?.moodColor2) : mine
    }
    private var viewers: [StatusViewer] { info?.views ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的状态"), back: { dismiss() }) {
                Button { editing = true } label: {
                    Text(Tr("更改状态"))
                        .font(pf(15))
                        .foregroundColor(C.green)
                        .padding(.horizontal, 16)
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 12) {
                    bigCard
                    viewersCard
                    Spacer().frame(height: 20)
                }
                .padding(.top, 12)
            }
            .background(C.pageBg)

            endButton
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $editing) { StatusView() }
        .task { await reload() }
        .onChange(of: editing) { on in
            if !on { Task { await reload() } }
        }
    }

    private var bigCard: some View {
        let base = c1.isEmpty ? "#5B7F42" : c1
        let second = c2.isEmpty ? MoodColor.shift(base, to: true) : c2
        return VStack(spacing: 10) {
            Text(icon.isEmpty ? "🙂" : icon).font(pf(44))
            if !label.isEmpty {
                Text(Tr(label)).font(pf(17, .medium)).foregroundColor(.white).lineLimit(1)
            }
            if !note.isEmpty {
                Text(note).font(pf(13.5)).foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            Text(leftText).font(pf(11.5)).foregroundColor(.white.opacity(0.82))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .background(LinearGradient(colors: [Color(hexString: base),
                                            Color(hexString: second.isEmpty ? base : second)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var leftText: String {
        let h = info?.hoursLeft ?? 0
        if h <= 0 { return Tr("24 小时后自动结束（不到 1 小时）") }
        return "24 小时后自动结束 · 还剩 \(h) 小时"
    }

    private var viewersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(Tr("谁看过我"))
                    .font(pf(14, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
                Text("\(info?.viewerCount ?? viewers.count) 人")
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 15)
            .frame(height: 46)
            HairLine(inset: 15)
            if viewers.isEmpty {
                Text(Tr("还没有人看过你的状态"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
            } else {
                ForEach(viewers, id: \.self) { v in
                    viewerRow(v)
                }
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func viewerRow(_ v: StatusViewer) -> some View {
        HStack(spacing: 10) {
            Avatar(path: v.avatar ?? "", size: 34, radius: 17, circle: true)
            Text(v.name ?? "好友")
                .font(pf(15))
                .foregroundColor(C.label)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(TimeFmt.list(v.at))
                .font(pf(12))
                .foregroundColor(C.subLabel)
                .fixedSize()
        }
        .padding(.horizontal, 15)
        .frame(height: 54)
    }

    private var endButton: some View {
        Button { endIt() } label: {
            Text(Tr("结束状态"))
                .font(pf(15.5))
                .foregroundColor(C.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(C.cardBg)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, max(10, L.safeBottom))
    }

    private func reload() async {
        info = try? await API.shared.myStatus()
        app.me = try? await API.shared.me()
    }

    private func endIt() {
        Task {
            await API.shared.endMyStatus()
            app.me = try? await API.shared.me()
            app.show(Tr("状态已取消"))
            dismiss()
        }
    }
}

/* ============================================================
   好友的状态（名片页 / 聊天气泡那一条点进来的）
   好友那边只看得到「图标 + 状态名 + 说点什么 + 还剩几个小时」
   ============================================================ */

struct FriendStatusView: View {
    @Environment(\.dismiss) private var dismiss
    let user: User

    private var base: String {
        let c = MoodColor.clean(user.moodColor)
        return c.isEmpty ? "#5B7F42" : c
    }
    private var second: String {
        let c = MoodColor.clean(user.moodColor2)
        return c.isEmpty ? MoodColor.shift(base, to: true) : c
    }
    private var label: String {
        let l = (user.moodLabel ?? "").trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? (user.moodText ?? "") : l
    }
    private var note: String { user.moodCaption ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("状态"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        Text(user.moodIcon ?? "🙂").font(pf(46))
                        if !label.isEmpty {
                            Text(Tr(label)).font(pf(17, .medium)).foregroundColor(.white)
                        }
                        if !note.isEmpty {
                            Text(note).font(pf(13.5)).foregroundColor(.white.opacity(0.92))
                                .multilineTextAlignment(.center)
                        }
                        Text(leftText).font(pf(11.5)).foregroundColor(.white.opacity(0.82))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 18)
                    .background(LinearGradient(colors: [Color(hexString: base),
                                                        Color(hexString: second.isEmpty ? base : second)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 12)
                    Spacer().frame(height: 20)
                }
                .padding(.top, 12)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private var leftText: String {
        let exp = Double(user.moodExpiresAt ?? 0)
        guard exp > 0 else { return Tr("24 小时内有效") }
        let left = (exp - Date().timeIntervalSince1970 * 1000) / 3600000
        if left <= 0 { return Tr("已经结束了") }
        if left < 1 { return Tr("24 小时内有效（不到 1 小时）") }
        return "24 小时内有效 · 还剩 \(Int(left.rounded())) 小时"
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
