import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject var app: AppState
    @State private var path = NavigationPath()
    /// 后台配的发现页（加一行、改个名，重开 App 或切回本页就变）
    @State private var items: [DiscoverItem] = []
    @State private var loaded = false
    /// 扫一扫（发现页 → 扫一扫）
    @State private var showScan = false
    @ObservedObject private var realtime = Realtime.shared

    private var latestThumb: String {
        for m in app.moments {
            if let img = m.images?.first, !img.isEmpty { return img }
        }
        return ""
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavBar(title: C.tabText2)
                    .measure("discover.nav")
                ScrollView {
                    VStack(spacing: 0) {
                        // 行数、名字、图标、颜色、分组全部来自后台配置
                        ForEach(grouped.indices, id: \.self) { gi in
                            GroupCard {
                                ForEach(grouped[gi].indices, id: \.self) { ri in
                                    let item = grouped[gi][ri]
                                    if ri > 0 { rowLine }
                                    MenuRow(icon: (item.svg?.isEmpty == false) ? item.svg! : I.moments,
                                            iconColor: Color(hexString: item.color ?? "#4A90D9", fallback: 0x4A90D9),
                                            title: item.label,
                                            badge: item.action == "moments" && app.showDot("momentsRow", auto: !latestThumb.isEmpty),
                                            thumb: item.action == "moments" ? latestThumb : "",
                                            onTap: { open(item) })
                                }
                            }
                            GroupGap()
                        }

                        Spacer().frame(height: 20)
                    }
                }
                .background(C.pageBg)
            }
            .background(C.pageBg.ignoresSafeArea(edges: .bottom))
            /* 顶部（状态栏那一条）跟页面同一个底色，深色下才不会顶出一条浅色带 */
            .background(C.pageBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                if key == "moments" {
                    MomentsView()
                } else if key == "nearby" {
                    NearbyPageView()
                } else if key == "shake" {
                    ShakePageView()
                } else if key == "live" {
                    LiveListView()
                } else if key == "games" {
                    GamesPageView()
                } else if key == "channels" {
                    ChannelsView()
                } else if key == "news" {
                    ComingSoonView(title: "腾讯新闻")
                } else if key.hasPrefix("soon:") {
                    ComingSoonView(title: String(key.dropFirst(5)))
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        // 别人发了新朋友圈 → 发现页那个小图也跟着换
        .onChange(of: realtime.event) { ev in
            if ev.type == "moment" || ev.user != nil { Task { await app.loadMoments() } }
            if ev.type == "ui" { Task { await loadItems() } }
        }
        .task {
            if !loaded { await loadItems() }
        }
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
    }

    /// 按 group 分组：同一组排在一张卡片里（和网页版一致）
    private var grouped: [[DiscoverItem]] {
        var out: [[DiscoverItem]] = []
        var last: Int? = nil
        for it in items {
            let g = it.group ?? 1
            if last == nil || g != last! { out.append([]); last = g }
            out[out.count - 1].append(it)
        }
        return out
    }

    private func loadItems() async {
        if let list = try? await API.shared.discover(), !list.isEmpty {
            items = list
            loaded = true
        } else if items.isEmpty {
            // 拉不到就先用内置那套，别让页面空着
            items = DiscoverItem.builtin
        }
    }

    private func open(_ item: DiscoverItem) {
        switch item.action ?? "soon" {
        case "moments": path.append("moments")
        case "news": path.append("news")
        case "nearby": path.append("nearby")
        case "shake": path.append("shake")
        case "live": path.append("live")
    case "games": path.append("games")
    case "channels": path.append("channels")
    case "scan": showScan = true
    default: path.append("soon:" + item.label)
        }
    }

    private var gap: some View {
        Rectangle().fill(C.pageBg).frame(height: L.groupGap)
    }

    private var rowLine: some View {
        HairLine(inset: L.menuLineInset)
    }
}

/* App 拉不到后台配置时用的兜底（和微信发现页一样的那几行） */
extension DiscoverItem {
    static var builtin: [DiscoverItem] {
        [
            DiscoverItem(id: "d01", label: "朋友圈", icon: "i.moments", svg: I.moments,
                         color: "#4A90D9", action: "moments", group: 1, enabled: true),
            DiscoverItem(id: "d02", label: "视频号", icon: "i.channels", svg: I.channels,
                         color: "#F2943B", action: "soon", group: 2, enabled: true),
            DiscoverItem(id: "d03", label: "直播", icon: "i.live", svg: I.live,
                         color: "#F4525B", action: "soon", group: 2, enabled: true),
            DiscoverItem(id: "d04", label: "扫一扫", icon: "i.scan", svg: I.scan,
                         color: "#3D83E7", action: "soon", group: 3, enabled: true),
            DiscoverItem(id: "d05", label: "摇一摇", icon: "i.shake", svg: I.shake,
                         color: "#4489EA", action: "soon", group: 3, enabled: true),
            DiscoverItem(id: "d06", label: "看一看", icon: "i.look", svg: I.look,
                         color: "#7275E9", action: "soon", group: 4, enabled: true),
            DiscoverItem(id: "d07", label: "搜一搜", icon: "i.searchRow", svg: I.searchRow,
                         color: "#59C47E", action: "soon", group: 4, enabled: true),
            DiscoverItem(id: "d08", label: "附近", icon: "i.nearby", svg: I.nearby,
                         color: "#3D83E7", action: "soon", group: 5, enabled: true),
            DiscoverItem(id: "d10", label: "游戏", icon: "i.game", svg: I.game,
                         color: "#9A6AE8", action: "soon", group: 7, enabled: true)
        ]
    }

    /// 我页的兜底（和默认配置一致）
    static var builtinMe: [DiscoverItem] {
        [
            DiscoverItem(id: "m01", label: "服务", icon: "i.wallet", svg: I.wallet,
                         color: "#59C47E", action: "service", group: 1, enabled: true),
            DiscoverItem(id: "m02", label: "收藏", icon: "i.star", svg: I.star,
                         color: "#4489EA", action: "favorites", group: 2, enabled: true),
            DiscoverItem(id: "m03", label: "朋友圈", icon: "i.album", svg: I.album,
                         color: "#7275E9", action: "moments", group: 2, enabled: true),
            DiscoverItem(id: "m04", label: "作品", icon: "i.works", svg: I.works,
                         color: "#3D83E7", action: "works", group: 2, enabled: true),
            DiscoverItem(id: "m05", label: "表情", icon: "i.sticker", svg: I.sticker,
                         color: "#F5C144", action: "stickers", group: 3, enabled: true),
            DiscoverItem(id: "m06", label: "设置", icon: "i.gear", svg: I.gear,
                         color: "#3D83E7", action: "settings", group: 4, enabled: true)
        ]
    }
}

struct ComingSoonView: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(pf(17)).foregroundColor(C.label)
            Text("这一页排在下一批").font(pf(14)).foregroundColor(C.subLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.pageBg)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(pf(18, .medium))
                }
            }
            ToolbarItem(placement: .principal) {
                Text(title).font(pf(UIConfig.num("navTitle", 17))).foregroundColor(C.label)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }
}

/* ============================================================ 朋友圈 */

private struct OffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 第二路测量（整个内容块的屏幕坐标），和 OffsetKey 互为备份
private struct OffsetKey2: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MomentsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var target: User? = nil

    /// 滚动量：两路测量各存一份（1pt 条的屏幕 y、整个内容块的屏幕 y），取滚得更多的那个
    @State private var topY: CGFloat = 0
    @State private var blockY: CGFloat = 0
    @State private var baseTop: CGFloat?
    @State private var baseBlock: CGFloat?
    /// 兜底：列表顶上那个哨兵被 LazyVStack 回收了（说明封面已经滚过去）
    @State private var sentinelGone = false
    @State private var moments: [Moment] = []
    @State private var cameraMenu = false
    @State private var showPhoto = false
    @State private var showCamera = false
    @State private var showCoverPhoto = false
    @State private var composerPick = false
    @State private var posting = false
    @State private var draft = ""
    @State private var picked: [UIImage] = []
    @State private var uploading = false
    @State private var commenting: Moment?
    @State private var commentText = ""
    @State private var actionMoment: Moment?
    /// 点开朋友圈的图片：paths = 这条动态的图片，index = 点的那张
    @State private var viewerPaths: [String] = []
    @State private var viewerIndex: Int?
    /// 点头像 → 名片
    @State private var cardUser: User?
    /// 朋友圈往下翻页：还有没有更多 / 正在加载 / 一共多少条
    @State private var hasMoreMoments = false
    /* 发朋友圈：谁可以看 */
    @State private var visibility = "public"
    @State private var showVisibility = false
    @State private var showPick = false
    @State private var pickMode = "partial"
    @State private var visibleTo: Set<String> = []
    @State private var hiddenFrom: Set<String> = []
    @State private var loadingMore = false
    @State private var momentTotal = 0
    /// 下拉刷新：拉出来的距离 / 正在刷新 / 彩球自转角度
    @State private var pullY: CGFloat = 0
    @State private var pulling = false
    @State private var spin: Double = 0
    @State private var spinTask: Task<Void, Never>?
    /// 最后一次拖动的时间：用来兜底收球（手指松开的手势回调有时候不会被叫到）
    @State private var lastDragAt = Date(timeIntervalSince1970: 0)
    @ObservedObject private var realtime = Realtime.shared

    /// 和网页版一致：往下滚过「封面高度 - 52」时，顶部出现「朋友圈」三个字
    /// 两路测量 + LazyVStack 哨兵兜底，哪个先到算哪个
    private var scrolled: CGFloat {
        let a = baseTop.map { $0 - topY } ?? 0
        let b = baseBlock.map { $0 - blockY } ?? 0
        return max(0, max(a, b))
    }
    private var solid: Bool { scrolled > (L.coverH - 52) || sentinelGone }
    private var owner: User? { target ?? app.me }
    private var cover: String { owner?.momentCover ?? "" }

    var body: some View {
        ZStack(alignment: .top) {
            C.pageBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    /* 量往下滚了多少：① 内容最顶端那根 1pt 条的屏幕坐标
                       ② 整个内容块的屏幕坐标 —— 两个一起量，取滚动更多的那份，
                       任何一个在真机上抽风都不会影响「滚过封面出朋友圈三个字」 */
                    Color.clear
                        .frame(height: 1)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: OffsetKey.self,
                                                       value: g.frame(in: .global).minY)
                            }
                        )
                    coverView
                    momentList
                }
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: OffsetKey2.self,
                                               value: g.frame(in: .global).minY)
                    }
                )
            }
            .onPreferenceChange(OffsetKey.self) { y in
                if baseTop == nil { baseTop = y }
                topY = y
            }
            .onPreferenceChange(OffsetKey2.self) { y in
                if baseBlock == nil { baseBlock = y }
                blockY = y
            }
            /* 备用的下拉检测：手指往下拖 + 封面还没滚走（说明在最顶上）→ 拉出彩球。
               这套不依赖几何坐标，真机上一定有效。 */
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        lastDragAt = Date()
                        guard !sentinelGone else { return }        // 已经滚下去了，不算下拉
                        let dy = v.translation.height
                        if dy > 0 {
                            pullY = min(140, dy)
                            if !pulling { spin = Double(pullY) * 3.2 }
                        } else if !pulling {
                            pullY = 0
                        }
                    }
                    .onEnded { _ in
                        lastDragAt = Date()
                        if pullY > 60 && !pulling { startPullRefresh() }
                        if !pulling { pullY = 0 }
                    }
            )
            .ignoresSafeArea(edges: .top)

            /* 看门狗：0.4 秒没有新的拖动就收球。手指松开的手势回调偶尔不会被叫到，
               没有这个的话球会静止留在屏幕上。 */
            .task(id: pullY > 0 || pulling) {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if Task.isCancelled { return }
                    if pulling { continue }
                    if pullY > 0 && Date().timeIntervalSince(lastDragAt) > 0.4 {
                        pullY = 0
                        spin = 0
                        return
                    }
                    if pullY <= 0 { return }
                }
            }

            navBar

            /* 下拉那个彩球：往下拉到一定程度就转圈刷新（和网页版那个球一样） */
            if pullY > 0 || pulling {
                ColorBall(size: 34, spin: spin)
                    .scaleEffect(0.72 + min(1, pullY / 90) * 0.28)
                    .offset(y: min(96, pullY * 0.8) + L.safeTop + 6)
                    .animation(.easeOut(duration: 0.12), value: pullY)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }

            if let i = viewerIndex, !viewerPaths.isEmpty {
                PhotoPager(paths: viewerPaths, startIndex: i) { viewerIndex = nil }
                    .zIndex(40)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .modifier(TapAvatarCard(cardUser: $cardUser))
        .hidesTabBar()
        .onAppear {
            baseTop = nil
            baseBlock = nil
            sentinelGone = false
        }
        .task { await reload() }
        // 别人发朋友圈 / 换了封面，这边立刻跟着变
        .onChange(of: realtime.event) { _ in
            Task {
                app.me = try? await API.shared.me()
                await pollNewMoments()          // 只把新出现的插到最前面，别把翻过的页冲掉
            }
        }
        .task {
            // 兜底：每 8 秒对一次（万一长连接断了）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                app.me = try? await API.shared.me()
                await pollNewMoments()
            }
        }
        .confirmationDialog("发表", isPresented: $cameraMenu, titleVisibility: .visible) {
            Button("拍摄") { showCamera = true }
            Button("从相册选择") { showPhoto = true }
            if target == nil { Button("换封面") { showCoverPhoto = true } }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showPhoto) {
            PhotosPicker(limit: 9) { images in
                picked = Array(images.prefix(9))          // 最多 9 张，顺序就是选图顺序
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { posting = true }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                picked = [image]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { posting = true }
            }
        }
        .sheet(isPresented: $showCoverPhoto) {
            PhotoPicker { image in changeCover(image) }
        }
        .sheet(isPresented: $posting) { publishSheet }
        .alert("评论", isPresented: Binding(
            get: { commenting != nil },
            set: { if !$0 { commenting = nil } }
        )) {
            TextField("说点什么", text: $commentText)
            Button("发送") { submitComment() }
            Button("取消", role: .cancel) { commenting = nil }
        }
        .confirmationDialog("这条动态", isPresented: Binding(
            get: { actionMoment != nil },
            set: { if !$0 { actionMoment = nil } }
        ), titleVisibility: .visible) {
            if let m = actionMoment {
                if m.likedByMe == true {
                    Button("取消赞") { like(m) }
                } else {
                    Button("赞") { like(m) }
                }
                Button("评论") {
                    commentText = ""
                    commenting = m
                }
                if m.mine == true {
                    Button("删除", role: .destructive) { remove(m) }
                }
            }
            Button("取消", role: .cancel) { actionMoment = nil }
        }
    }

    /* ---------------------------------------------------------- 封面 */

    private var coverView: some View {
        ZStack(alignment: .bottom) {
            if cover.isEmpty {
                LinearGradient(colors: [Color(hex: 0x0D3B66), Color(hex: 0x1D6FB8), Color(hex: 0x0099FF)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                RemoteImage(path: cover, icon: "photo")
                    .id(cover)        // 换封面立刻生效
            }

            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.34), Color.black.opacity(0.52)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: L.coverH * 0.62)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            HStack(alignment: .bottom, spacing: 12) {
                Text(app.me?.name ?? "")
                    .font(pf(17, .semibold))
                    .foregroundColor(.white)
                    .shadow(color: Color.black.opacity(0.55), radius: 4, x: 0, y: 1)
                    .padding(.bottom, 24)
                Avatar(path: app.me?.avatarPath ?? "", size: L.coverAvatar, radius: 8)
                    .shadow(color: Color.black.opacity(0.28), radius: 5, x: 0, y: 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .offset(y: 21)
        }
        .frame(height: L.coverH)
        .zIndex(1)
    }

    /* ---------------------------------------------------------- 列表 */

    private var momentList: some View {
        // 必须用 LazyVStack：1500 条动态如果一次性全建出来（每行还有图），手机会直接崩
        LazyVStack(spacing: 0) {
            /* 哨兵：它被 LazyVStack 回收时说明封面已经滚过去了（滚动量测不准时的兜底） */
            Color.clear
                .frame(height: 1)
                .onAppear { sentinelGone = false }
                .onDisappear { sentinelGone = true }
            if moments.isEmpty {
                Text("正在加载朋友圈…")
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .padding(.vertical, 40)
            }
            ForEach(moments) { moment in
                MomentRow(moment: moment,
                          onMore: { actionMoment = moment },
                          onOpenImage: { path in openPhoto(path, in: moment) },
                          onOpenAvatar: { u in cardUser = u })
            }
            // 滑到底自动接着拉：3000 条也能一直往下翻（微信就是这样）
            if hasMoreMoments {
                Text(loadingMore ? "正在加载…" : " ")
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .onAppear {
                        Task { await loadMoreMoments() }
                    }
            } else if momentTotal > 0 {
                Text("没有更多了")
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
        .padding(.top, 60)
        .padding(.horizontal, L.momentPadH)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
        .background(Color.dyn(0xFFFFFF, 0x191919))
        .offset(y: 0)
        .zIndex(0)
    }

    /* ---------------------------------------------------------- 顶部浮条 */

    private var navBar: some View {
        ZStack {
            // 滚过封面后回到中间出现「朋友圈」（网页版就是这样）
            if solid {
                Text("朋友圈")
                    .font(pf(UIConfig.num("navTitle", 17)))
                    .foregroundColor(C.label)
            }

            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    SVGIcon(markup: I.backCover, size: 20, color: solid ? C.label : .white)
                        .frame(width: 44, height: 44)          // 点击区按微信标准 44×44
                        .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
                .contentShape(Rectangle())

                Spacer(minLength: 0)

                Button { cameraMenu = true } label: {
                    SVGIcon(markup: I.camera, size: 26, color: solid ? C.label : .white)
                        .frame(width: 44, height: 44)
                        .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .contentShape(Rectangle())
            }
        }
        .frame(height: L.navH)
        .background(
            Group {
                if solid {
                    Rectangle().fill(.ultraThinMaterial)
                } else {
                    Color.clear
                }
            }
            .ignoresSafeArea(edges: .top)
        )
        .zIndex(10)          // 永远在最上层：不能被下面的滚动层吃掉点击
    }

    /* ---------------------------------------------------------- 发表 / 评论 / 点赞 */

    private func openPhoto(_ path: String, in moment: Moment) {
        let all = moment.images ?? []
        guard !all.isEmpty else { return }
        viewerPaths = all
        viewerIndex = all.firstIndex(of: path) ?? 0
    }

    private var publishSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $draft)
                    .frame(minHeight: 110)
                    .font(pf(17))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.2))
                    )
                if !picked.isEmpty {
                    // 这里按发表后的样子摆（同一套规则）：2/4 张两列，3 张以上三列
                    PickedGrid(images: picked) { i in
                        picked.remove(at: i)                  // 点一下＝删掉这张，顺序不变
                    }
                    Text("最多 9 张 · 顺序就是你选图的先后顺序 · 点缩略图可以删掉")
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                }
                Button {
                    composerPick = true
                } label: {
                    Label("添加图片", systemImage: "photo.on.rectangle")
                        .font(pf(15))
                }
                /* 谁可以看（对应功能清单里的「好友公开 / 私密 / 部分可见 / 不给谁看」） */
                Button {
                    showVisibility = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "eye")
                        Text("谁可以看：\(visibilityName)")
                        Spacer()
                        Chevron(size: 9, line: 1.6)
                    }
                    .font(pf(15))
                    .foregroundColor(C.label)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
                }
                if visibility == "partial" || visibility == "exclude" {
                    Text(visibility == "partial"
                         ? "只给这 \(visibleTo.count) 个人看"
                         : "不给这 \(hiddenFrom.count) 个人看")
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("发表")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $composerPick) {
                PhotosPicker(limit: max(1, 9 - picked.count)) { images in
                    let room = 9 - picked.count
                    if images.count > room {
                        app.show("最多 9 张图，还能再加 \(room) 张")
                        picked.append(contentsOf: images.prefix(room))
                    } else {
                        picked.append(contentsOf: images)
                    }
                }
            }
            .confirmationDialog("谁可以看", isPresented: $showVisibility, titleVisibility: .visible) {
                Button("公开（所有好友可见）") { visibility = "public" }
                Button("私密（仅自己可见）") { visibility = "private" }
                Button("部分可见…") { visibility = "partial"; pickMode = "partial"; showPick = true }
                Button("不给谁看…") { visibility = "exclude"; pickMode = "exclude"; showPick = true }
                Button("取消", role: .cancel) { }
            }
            .sheet(isPresented: $showPick) { friendPickSheet }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { posting = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("发表") { publish() }
                        .disabled(uploading || (draft.isEmpty && picked.isEmpty))
                }
            }
        }
    }

    private var visibilityName: String {
        switch visibility {
        case "private": return "仅自己"
        case "partial": return "部分可见"
        case "exclude": return "不给谁看"
        default: return "公开"
        }
    }

    private var friendPickSheet: some View {
        NavigationStack {
            List {
                ForEach(app.contacts) { u in
                    Button {
                        if pickMode == "partial" {
                            if visibleTo.contains(u.id) { visibleTo.remove(u.id) } else { visibleTo.insert(u.id) }
                        } else {
                            if hiddenFrom.contains(u.id) { hiddenFrom.remove(u.id) } else { hiddenFrom.insert(u.id) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(path: u.avatarPath, size: 38, radius: 6)
                            Text(u.name).font(pf(16)).foregroundColor(C.label)
                            Spacer()
                            let on = pickMode == "partial" ? visibleTo.contains(u.id) : hiddenFrom.contains(u.id)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(on ? C.green : C.subLabel)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(pickMode == "partial" ? "选择可见的好友" : "选择不看的好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("好了") { showPick = false } } }
        }
    }

    /// 松手刷新：彩球转圈，同时把封面 + 动态重新拉一遍
    private func startPullRefresh() {
        pulling = true
        spinTask?.cancel()
        spinTask = Task { @MainActor in
            var angle = spin
            let started = Date()
            while !Task.isCancelled {
                angle += 14
                spin = angle
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Date().timeIntervalSince(started) > 1.0 { break }   // 至少转 1 秒
            }
            if target == nil { app.me = try? await API.shared.me() }    // 封面也一起更新
            await reload()
            pullY = 0                       // 转完收回去（一定收）
            spin = 0
            pulling = false
        }
    }

    private func reload() async {
        if let feed = try? await API.shared.momentsFeed(limit: 30, userId: target?.id) {
            moments = feed.moments
            hasMoreMoments = feed.hasMore
            momentTotal = feed.total
        } else {
            moments = app.moments
            hasMoreMoments = false
        }
        // 打开朋友圈 = 看过了：把「发现」上的小红点清掉
        if target == nil {
            await API.shared.markMomentsSeen()
            app.momentsUnread = 0
        }
    }

    /// 往下翻一页（3000 条也能一条条刷到底）
    private func loadMoreMoments() async {
        guard hasMoreMoments, !loadingMore, let last = moments.last else { return }
        loadingMore = true
        if let feed = try? await API.shared.momentsFeed(limit: 30, before: last.createdAt, beforeId: last.id,
                                                        userId: target?.id) {
            let known = Set(moments.map { $0.id })
            moments.append(contentsOf: feed.moments.filter { !known.contains($0.id) })
            hasMoreMoments = feed.hasMore && !feed.moments.isEmpty
        } else {
            hasMoreMoments = false
        }
        loadingMore = false
    }

    /// 轮询 / 收到推送时：只把「新出现的」插到最前面，已经在列表里的和翻过的页都不动
    private func pollNewMoments() async {
        guard let feed = try? await API.shared.momentsFeed(limit: 30, userId: target?.id) else { return }
        let known = Set(moments.map { $0.id })
        let fresh = feed.moments.filter { !known.contains($0.id) }
        if !fresh.isEmpty { moments.insert(contentsOf: fresh, at: 0) }
        momentTotal = feed.total
        if moments.count <= 30 { hasMoreMoments = feed.hasMore }
    }

    private func publish() {
        uploading = true
        Task {
            var urls: [String] = []
            for image in picked {
                if let url = try? await API.shared.upload(image: image) { urls.append(url) }
            }
            do {
                try await API.shared.postMoment(content: draft, images: urls,
                                                visibility: visibility,
                                                visibleTo: Array(visibleTo),
                                                hiddenFrom: Array(hiddenFrom))
                app.show("已发表")
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发表失败")
            }
            draft = ""
            picked = []
            visibility = "public"
            visibleTo = []
            hiddenFrom = []
            uploading = false
            posting = false
            await reload()
            await app.loadMoments()
        }
    }

    private func changeCover(_ image: UIImage) {
        Task {
            uploading = true
            if let url = try? await API.shared.upload(image: image) {
                await API.shared.updateMe(["momentCover": url])
                if let me = try? await API.shared.me() {
                    app.me = me
                }
                app.show("封面换好了")
            }
            uploading = false
        }
    }

    private func like(_ moment: Moment) {
        Task {
            await API.shared.likeMoment(id: moment.id)
            await reload()
        }
    }

    private func submitComment() {
        guard let moment = commenting else { return }
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        commenting = nil
        if text.isEmpty { return }
        Task {
            await API.shared.commentMoment(id: moment.id, text: text)
            await reload()
        }
    }

    private func remove(_ moment: Moment) {
        Task {
            await API.shared.deleteMoment(id: moment.id)
            await reload()
            await app.loadMoments()
            app.show("已删除")
        }
    }
}

struct MomentRow: View {
    let moment: Moment
    var onMore: (() -> Void)? = nil
    /// 点图片 → 看大图
    var onOpenImage: ((String) -> Void)? = nil
    /// 点头像 → 名片
    var onOpenAvatar: ((User) -> Void)? = nil

    private var images: [String] { moment.images ?? [] }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Avatar(path: moment.author?.avatarPath ?? "", size: L.momentAvatar, radius: 5)
                .contentShape(Rectangle())
                .onTapGesture { if let u = moment.author { onOpenAvatar?(u) } }

            VStack(alignment: .leading, spacing: 0) {
                Text(moment.author?.name ?? "")
                    .font(pf(18.3, .medium))
                    .foregroundColor(C.link)

                if let content = moment.content, !content.isEmpty {
                    Text(content)
                        .font(pf(18.3))
                        .foregroundColor(C.label)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }

                if !images.isEmpty {
                    grid
                        .padding(.top, 13)
                }

                HStack(spacing: 14) {
                    Text(TimeFmt.ago(moment.createdAt))
                        .font(pf(14.5))
                        .foregroundColor(Color.dyn(0xA5A5A5, 0x8A8A8E))

                    Spacer()

                    Button {
                        onMore?()
                    } label: {
                        HStack(spacing: 2.6) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle()
                                    .fill((moment.likedByMe == true) ? Color(hex: 0xFF6B6B) : Color.dyn(0x7F7F7F, 0xD8D8D8))
                                    .frame(width: 3.4, height: 3.4)
                            }
                        }
                        .frame(width: 28, height: 19)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.dyn(0xF0F0F0, 0x3A3A3C)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 10)

                let likes = moment.likes ?? []
                let comments = moment.comments ?? []
                if !likes.isEmpty || !comments.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !likes.isEmpty {
                            Text(likes.compactMap { $0.nickname }.joined(separator: "、"))
                                .font(pf(15))
                                .foregroundColor(C.link)
                        }
                        ForEach(comments.indices, id: \.self) { i in
                            let c = comments[i]
                            Text((c.nickname ?? "") + "：" + (c.content ?? ""))
                                .font(pf(15))
                                .foregroundColor(C.label)
                        }
                    }
                    .padding(.top, 9)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 15)
        .padding(.bottom, 12)
    }

    private var grid: some View {
        MomentImageGrid(images: images,
                        avail: L.width - L.momentPadH * 2 - L.momentAvatar - 9,
                        onTap: { i in if i < images.count { onOpenImage?(images[i]) } })
    }
}

/* 下拉刷新那个彩色球（和网页版 .ptr-ball 一模一样：七色渐变 + 左上高光 + 投影） */
struct ColorBall: View {
    var size: CGFloat = 34
    var spin: Double = 0

    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(
                gradient: Gradient(colors: [
                    Color(hex: 0xFF6B6B), Color(hex: 0xFFD166), Color(hex: 0x5FD07A),
                    Color(hex: 0x4AB6FF), Color(hex: 0xA06DE0), Color(hex: 0xFF6BD6),
                    Color(hex: 0xFF6B6B)
                ]),
                center: .center))
            Circle().fill(RadialGradient(
                gradient: Gradient(colors: [.white.opacity(0.95), .white.opacity(0)]),
                center: UnitPoint(x: 0.37, y: 0.3), startRadius: 0.5, endRadius: size * 0.36))
                .padding(size * 0.14)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(spin))
        .shadow(color: Color.black.opacity(0.28), radius: 7, y: 4)
    }
}

/* ============================================================
  朋友圈图片排列（严格按规格）：
   1 张 → 不进九宫格，按原图比例自适应（比例限制 3:4 ~ 2:1，超出的居中裁切，最高 300）
   2 / 4 张 → 2 列；3 张 → 3 列；5~9 张 → 统一 3 列
   正方形缩略图居中裁切 · 间隙 6 · 圆角 4 · 顺序 = 发的人选图顺序
   ============================================================ */
struct MomentImageGrid: View {
    let images: [String]
    var avail: CGFloat
    var onTap: (Int) -> Void

    private let gap: CGFloat = 6
    private let radius: CGFloat = 4

    var body: some View {
        if images.count == 1 {
            MomentSingleImage(path: images[0], avail: avail, radius: radius) { onTap(0) }
        } else {
            let cols = (images.count == 2 || images.count == 4) ? 2 : 3
            let maxW = avail * (cols == 2 ? (images.count == 4 ? 0.52 : 0.62) : 0.74)
            let cell = (maxW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let rows = stride(from: 0, to: images.count, by: cols).map { start in
                Array(start..<min(start + cols, images.count))
            }
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(rows[r], id: \.self) { i in
                            Button { onTap(i) } label: {
                                RemoteImage(path: images[i], icon: "photo")
                                    .frame(width: cell, height: cell)
                                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if rows[r].count < cols { Spacer(minLength: 0) }
                    }
                }
            }
        }
    }
}

/// 单张图：等原图加载出来，按它的宽高比摆（极端比例裁切，小图不放大）
/// 发表页里已经选好的图：和发出去以后一模一样的摆法（点一下删掉）
struct PickedGrid: View {
    let images: [UIImage]
    var onTap: (Int) -> Void

    private let gap: CGFloat = 6
    private let radius: CGFloat = 4

    var body: some View {
        if images.count == 1 {
            let img = images[0]
            let a = min(max(img.size.width / max(1, img.size.height), 0.75), 2.0)
            let limit = a >= 1 ? (L.width - 32) : (L.width - 32) * 0.62
            let w = min(limit, img.size.width)
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: w, height: min(w / a, 300))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { onTap(0) }
        } else {
            let cols = (images.count == 2 || images.count == 4) ? 2 : 3
            let maxW = L.width - 32
            let cell = (maxW - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let rows = stride(from: 0, to: images.count, by: cols).map { start in
                Array(start..<min(start + cols, images.count))
            }
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(rows[r], id: \.self) { i in
                            Image(uiImage: images[i])
                                .resizable()
                                .scaledToFill()
                                .frame(width: cell, height: cell)
                                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { onTap(i) }
                        }
                        if rows[r].count < cols { Spacer(minLength: 0) }
                    }
                }
            }
        }
    }
}

struct MomentSingleImage: View {
    let path: String
    var avail: CGFloat
    var radius: CGFloat = 4
    var onTap: () -> Void

    @State private var aspect: CGFloat = 4.0 / 3.0
    @State private var naturalW: CGFloat = 0
    @State private var started = false

    var body: some View {
        let a = min(max(aspect, 0.75), 2.0)                  // 3:4 ~ 2:1
        // 和微信一样：横图能占满内容宽，竖图只占 62%
        let limit = a >= 1 ? avail : avail * 0.62
        let w = naturalW > 0 ? min(limit, naturalW) : limit  // 小图不放大
        let h = min(w / a, 300)                              // 超长图限高裁切
        RemoteImage(path: path, icon: "photo")
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .onAppear { if !started { started = true; Task { await measure() } } }
    }

    private func measure() async {
        if let hit = ImageStore.shared.get(path), hit.size.height > 0 {
            aspect = hit.size.width / hit.size.height
            naturalW = hit.size.width
            return
        }
        guard let url = API.shared.assetURL(path) else { return }
        guard let data = try? await API.shared.imageData(url),
              let img = RemoteImage.downsampled(data, maxSide: 2048), img.size.height > 0 else { return }
        ImageStore.shared.put(path, img)
        aspect = img.size.width / img.size.height
        naturalW = img.size.width
    }
}
