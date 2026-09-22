import SwiftUI
import UniformTypeIdentifiers
import CoreLocation

struct DiscoverView: View {
    @ObservedObject private var lang = LangStore.shared
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
                title: Tr(item.label),
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
            Text(Tr("这一页排在下一批")).font(pf(14)).foregroundColor(C.subLabel)
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
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var target: User? = nil
    /// 「我的朋友圈」（从「我」那一页进来的）：只显示我自己的动态，封面也是我的。
    /// 微信的逻辑就是这样：发现页进去是好友动态，我→朋友圈进去只看自己的。
    var mineOnly: Bool = false

    /// 这一页要拉谁的动态：mineOnly = 只看自己；target = 看某个好友；都没有 = 好友动态时间轴
    private var feedUserId: String? { mineOnly ? app.me?.id : target?.id }
    /// 能不能换封面（自己这一页才行）
    private var coverEditable: Bool { target == nil || mineOnly }

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
    /* 换封面（微信：点封面 → 从相册选择/拍一张 → 拖动调整 → 完成） */
    @State private var coverMenu = false
    @State private var showCoverCamera = false
    @State private var coverDraft: UIImage?
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
    /* 发朋友圈：所在位置 / 提醒谁看（微信发表页那两行） */
    @State private var draftLocation = ""
    @State private var remindIds: Set<String> = []
    @State private var showLocation = false
    /* 九宫格拖动排序：正在拖的那一格 */
    @State private var dragIndex: Int?
    /// 「别误触」的锁：发表完 / 关掉大图后的 0.6 秒里不响应「点图看大图」
    /// （iOS 上弹层收起时手指那一下会漏到下面列表上 —— 用户反馈的「莫名其妙点到一张」就是它）
    @State private var tapLockUntil = Date(timeIntervalSince1970: 0)
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
            /* 手指在朋友圈里滑动时，就别把这一下当成「点开一张图」 */
            .simultaneousGesture(
                DragGesture(minimumDistance: 6).onChanged { _ in
                    tapLockUntil = Date().addingTimeInterval(0.35)
                }
            )
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
                PhotoPager(paths: viewerPaths, startIndex: i) {
                    viewerIndex = nil
                    tapLockUntil = Date().addingTimeInterval(0.6)      // 关大图那一下别又点开一张
                }
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
        .confirmationDialog(Tr("发表"), isPresented: $cameraMenu, titleVisibility: .visible) {
            Button(Tr("拍摄")) { showCamera = true }
            Button(Tr("从相册选择")) { showPhoto = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 点封面图 → 微信那个「更换相册封面」 */
        .confirmationDialog(Tr("更换相册封面"), isPresented: $coverMenu, titleVisibility: .visible) {
            Button(Tr("从手机相册选择")) { showCoverPhoto = true }
            Button(Tr("拍一张")) { showCoverCamera = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        .sheet(isPresented: $showCoverCamera) {
            CameraPicker { image in coverDraft = image }
        }
        /* 选完先「拖动调整」，点完成才真正换（微信就是这样，不会一选就换） */
        .sheet(isPresented: Binding(get: { coverDraft != nil },
                                    set: { if !$0 { coverDraft = nil } })) {
            if let img = coverDraft {
                CoverAdjustSheet(image: img,
                                 frameSize: CGSize(width: L.width, height: L.coverH)) { out in
                    changeCover(out)
                    coverDraft = nil
                }
            }
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
            PhotoPicker { image in coverDraft = image }
        }
        .sheet(isPresented: $posting) { publishSheet }
        .alert("评论", isPresented: Binding(
            get: { commenting != nil },
            set: { if !$0 { commenting = nil } }
        )) {
            TextField("说点什么", text: $commentText)
            Button(Tr("发送")) { submitComment() }
            Button(Tr("取消"), role: .cancel) { commenting = nil }
        }
        .confirmationDialog(Tr("这条动态"), isPresented: Binding(
            get: { actionMoment != nil },
            set: { if !$0 { actionMoment = nil } }
        ), titleVisibility: .visible) {
            if let m = actionMoment {
                if m.likedByMe == true {
                    Button(Tr("取消赞")) { like(m) }
                } else {
                    Button(Tr("赞")) { like(m) }
                }
                Button(Tr("评论")) {
                    commentText = ""
                    commenting = m
                }
                if m.mine == true {
                    Button(Tr("删除"), role: .destructive) { remove(m) }
                }
            }
            Button(Tr("取消"), role: .cancel) { actionMoment = nil }
        }
    }

    /* ---------------------------------------------------------- 封面 */

    private var coverView: some View {
        ZStack(alignment: .bottom) {
            if cover.isEmpty {
                LinearGradient(colors: [Color(hex: 0x0D3B66), Color(hex: 0x1D6FB8), Color(hex: 0x0099FF)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                RemoteImage(path: cover, icon: "photo", maxSide: 2560)
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
        /* 微信：点自己朋友圈顶部这张封面图 → 弹「更换相册封面」 */
        .onTapGesture { if coverEditable { coverMenu = true } }
    }

    /* ---------------------------------------------------------- 列表 */

    private func momentRow(_ moment: Moment) -> some View {
        MomentRow(moment: moment,
                  onMore: { actionMoment = moment },
                  onOpenImage: { path in openPhoto(path, in: moment) },
                  onOpenAvatar: { u in cardUser = u },
                  onDeleteComment: { cid in deleteComment(moment.id, cid) },
                  myId: app.me?.id ?? "",
                  onLike: { like(moment) },
                  onComment: { commentText = ""; commenting = moment },
                  onDeleteMoment: { remove(moment) },
                  onTogglePin: { togglePin(moment) })
    }

    /// 时间轴分组标题：今天 / 昨天 / 前天 / M月d日（往年带年份）
    private func dayLabel(_ s: String?) -> String {
        guard let d = TimeFmt.date(s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return Tr("今天") }
        if cal.isDateInYesterday(d) { return Tr("昨天") }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days == 2 { return Tr("前天") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    private func dayHeader(_ t: String) -> some View {
        HStack {
            Text(t)
                .font(pf(13))
                .foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private var momentList: some View {
        // 必须用 LazyVStack：1500 条动态如果一次性全建出来（每行还有图），手机会直接崩
        LazyVStack(spacing: 0) {
            /* 哨兵：它被 LazyVStack 回收时说明封面已经滚过去了（滚动量测不准时的兜底） */
            Color.clear
                .frame(height: 1)
                .onAppear { sentinelGone = false }
                .onDisappear { sentinelGone = true }
            if moments.isEmpty {
                Text(Tr("正在加载朋友圈…"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .padding(.vertical, 40)
            }
            /* 置顶的那条固定在最上面（带「置顶」标），
               其余按天分组：今天 / 昨天 / 前天 / M月d日 —— 时间轴看着清楚 */
            let pinnedOnes = moments.filter { $0.pinned == true }
            let timeline = moments.filter { $0.pinned != true }
            ForEach(pinnedOnes) { moment in
                momentRow(moment)
            }
            ForEach(Array(timeline.enumerated()), id: \.element.id) { i, moment in
                let day = dayLabel(moment.createdAt)
                if i == 0 || dayLabel(timeline[i - 1].createdAt) != day {
                    dayHeader(day)
                }
                momentRow(moment)
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
                Text(Tr("没有更多了"))
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
                Text(Tr("朋友圈"))
                    .font(pf(UIConfig.num("navTitle", 17)))
                    .foregroundColor(C.label)
            }

            HStack(spacing: 0) {
                /* 返回箭头：和全 App 用同一个（后台「UI 图标」还能换成你自己的），
                   点击区 56×48、层级拉到最上面 —— 以前是自绘 SVG + 44 宽，真机上偶尔点不到 */
                Button { dismiss() } label: {
                    FlexIcon(custom: IconOverrides.custom("nav.back"),
                             size: 20, color: solid ? C.label : .white,
                             symbol: "chevron.left", weight: .medium)
                        .frame(width: 56, height: L.navH)
                        .shadow(color: solid ? .clear : Color.black.opacity(0.55), radius: 2, x: 0, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
        .zIndex(25)          // 永远在最上层：不能被下面的滚动层吃掉点击
        .allowsHitTesting(true)
    }

    /* ---------------------------------------------------------- 发表 / 评论 / 点赞 */

    private func openPhoto(_ path: String, in moment: Moment) {
        guard Date() >= tapLockUntil else { return }      // 刚发表完 / 刚关掉大图：这一下不算
        let all = moment.images ?? []
        guard !all.isEmpty else { return }
        viewerPaths = all
        viewerIndex = all.firstIndex(of: path) ?? 0
    }

    private var publishSheet: some View {
        VStack(spacing: 0) {
            /* 微信发表页：右上角「发表」，什么都没写的时候是灰的、点不动 */
            NavBar(title: Tr("发表"), back: { posting = false }) {
                Button { publish() } label: {
                    Text(uploading ? Tr("发布中…") : Tr("发表"))
                        .font(pf(17, .semibold))
                        .foregroundColor(canPublish ? C.green : C.subLabel)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(!canPublish)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    /* 文字 + 「这一刻的想法…」占位 */
                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(Tr("这一刻的想法…"))
                                .font(pf(17))
                                .foregroundColor(C.subLabel)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $draft)
                            .font(pf(17))
                            .frame(minHeight: 104)
                            .scrollContentBackground(.hidden)
                    }
                    .padding(.horizontal, 12)
                    .background(C.cardBg)

                    /* 九宫格：＋ 永远在第一个空位，图上有 ✕，长按拖动换顺序 */
                    composerGrid
                        .padding(.horizontal, 16)
                        .padding(.top, 14)

                    /* 微信那三行 */
                    VStack(spacing: 0) {
                        HairLine(inset: 16)
                        composerRow(icon: "location", title: Tr("所在位置"),
                                    value: draftLocation.isEmpty ? Tr("不显示位置") : draftLocation) {
                            showLocation = true
                        }
                        HairLine(inset: 16)
                        composerRow(icon: "eye", title: Tr("谁可以看"), value: visibilityName) {
                            showVisibility = true
                        }
                        HairLine(inset: 16)
                        composerRow(icon: "at", title: Tr("提醒谁看"),
                                    value: remindIds.isEmpty ? "" : "\(remindIds.count) 个人") {
                            pickMode = "at"
                            showPick = true
                        }
                    }
                    .background(C.cardBg)
                    .padding(.top, 18)
                }
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { posting = false }
        .hidesTabBar()
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
            .confirmationDialog(Tr("谁可以看"), isPresented: $showVisibility, titleVisibility: .visible) {
                Button(Tr("公开（所有好友可见）")) { visibility = "public" }
                Button(Tr("私密（仅自己可见）")) { visibility = "private" }
                Button(Tr("部分可见…")) { visibility = "partial"; pickMode = "partial"; showPick = true }
                Button(Tr("不给谁看…")) { visibility = "exclude"; pickMode = "exclude"; showPick = true }
                Button(Tr("取消"), role: .cancel) { }
            }
            .sheet(isPresented: $showPick) { friendPickSheet }
            .sheet(isPresented: $showLocation) {
                PlacePickerSheet(text: $draftLocation)
            }
    }

    private var canPublish: Bool {
        !uploading && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !picked.isEmpty)
    }

    /* 九宫格（微信发表页那一块） */
    private var composerGrid: some View {
        let gap: CGFloat = 6
        let side = (L.width - 32 - gap * 2) / 3
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: gap), count: 3),
                         alignment: .leading, spacing: gap) {
            ForEach(picked.indices, id: \.self) { i in
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: picked[i])
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .contentShape(Rectangle())
                        .onDrag {
                            dragIndex = i
                            return NSItemProvider(object: String(i) as NSString)
                        }
                        .onDrop(of: [UTType.text],
                                delegate: MomentGridDrop(index: i, items: $picked, dragIndex: $dragIndex))
                    Button {
                        picked.remove(at: i)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
            if picked.count < 9 {
                Button { composerPick = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(C.searchBg)
                        Image(systemName: "plus")
                            .font(.system(size: 26, weight: .light))
                            .foregroundColor(C.subLabel)
                    }
                    .frame(width: side, height: side)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func composerRow(icon: String, title: String, value: String,
                             tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(C.label)
                    .frame(width: 20)
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                if !value.isEmpty {
                    Text(value).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        if pickMode == "at" {
                            if remindIds.contains(u.id) { remindIds.remove(u.id) } else { remindIds.insert(u.id) }
                        } else if pickMode == "partial" {
                            if visibleTo.contains(u.id) { visibleTo.remove(u.id) } else { visibleTo.insert(u.id) }
                        } else {
                            if hiddenFrom.contains(u.id) { hiddenFrom.remove(u.id) } else { hiddenFrom.insert(u.id) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(path: u.avatarPath, size: 38, radius: 6)
                            Text(u.name).font(pf(16)).foregroundColor(C.label)
                            Spacer()
                            let on = pickMode == "at" ? remindIds.contains(u.id)
                                : (pickMode == "partial" ? visibleTo.contains(u.id) : hiddenFrom.contains(u.id))
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(on ? C.green : C.subLabel)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(pickMode == "at" ? "提醒谁看"
                             : (pickMode == "partial" ? "选择可见的好友" : "选择不看的好友"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(Tr("好了")) { showPick = false } } }
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
            if coverEditable { app.me = try? await API.shared.me() }    // 封面也一起更新
            await reload()
            pullY = 0                       // 转完收回去（一定收）
            spin = 0
            pulling = false
        }
    }

    private func reload() async {
        if let feed = try? await API.shared.momentsFeed(limit: 30, userId: feedUserId) {
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
                                                        userId: feedUserId) {
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
        guard let feed = try? await API.shared.momentsFeed(limit: 30, userId: feedUserId) else { return }
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
                                                hiddenFrom: Array(hiddenFrom),
                                                location: draftLocation)
                /* 「提醒谁看」：给选中的好友各发一条消息，让他们点进来（微信也是这么提醒的） */
                if !remindIds.isEmpty {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let tip = "我在朋友圈提到了你" + (text.isEmpty ? "" : "：" + String(text.prefix(30)))
                    for fid in remindIds {
                        if let chat = try? await API.shared.openDirect(userId: fid) {
                            _ = try? await API.shared.send(chatId: chat.id, text: tip)
                        }
                    }
                    await app.loadChats()
                }
                app.show(Tr("已发表"))
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "发表失败")
            }
            draft = ""
            picked = []
            visibility = "public"
            visibleTo = []
            hiddenFrom = []
            draftLocation = ""
            remindIds = []
            uploading = false
            posting = false
            tapLockUntil = Date().addingTimeInterval(0.6)          // 发表弹层收起那一下别误触到图
            await reload()
            await app.loadMoments()
        }
    }

    private func changeCover(_ image: UIImage) {
        Task {
            uploading = true
            /* 封面用高清通道（长边 2048、画质 0.95）—— 以前走的是聊天图片那条压缩通道，所以糊 */
            if let url = try? await API.shared.uploadCover(image: image) {
                await API.shared.updateMe(["momentCover": url])
                if let me = try? await API.shared.me() {
                    app.me = me
                }
                app.show(Tr("封面换好了"))
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

    /// 置顶 / 取消置顶自己那条动态：置顶的固定排最上面，只能置顶一条
    private func togglePin(_ moment: Moment) {
        let next = !(moment.pinned == true)
        Task {
            await API.shared.pinMoment(id: moment.id, pinned: next)
            await reload()
            app.show(next ? Tr("已置顶，会固定显示在最上面") : Tr("已取消置顶"))
        }
    }

    /// 删自己发的评论（微信：点一下自己的评论 → 删除）
    private func deleteComment(_ momentId: String, _ commentId: String) {
        Task {
            if let err = await API.shared.deleteMomentComment(momentId: momentId, commentId: commentId) {
                app.show(err)
            } else {
                app.show(Tr("评论已删除"))
            }
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
            app.show(Tr("已删除"))
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
    /// 点自己发的评论 → 删除（微信那样）
    var onDeleteComment: ((String) -> Void)? = nil
    /// 我的用户 id（判断哪条评论是我自己发的）
    var myId: String = ""
    /// 点赞 / 评论 / 删除自己的动态（微信「···」旁边那个小横条上的按钮）
    var onLike: (() -> Void)? = nil
    var onComment: (() -> Void)? = nil
    var onDeleteMoment: (() -> Void)? = nil
    /// 置顶 / 取消置顶（只对自己的动态）
    var onTogglePin: (() -> Void)? = nil

    @State private var deletingComment: String?
    /// 微信：点「···」是在按钮**旁边**弹出「赞 | 评论」小横条，不是底部弹层
    @State private var showActions = false

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

                /* 置顶的那条：和微信「置顶」一样在时间旁边标一下 */
                if moment.pinned == true {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.fill").font(.system(size: 10))
                        Text(Tr("置顶")).font(pf(12.5))
                    }
                    .foregroundColor(C.subLabel)
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
                        withAnimation(.easeOut(duration: 0.14)) { showActions.toggle() }
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
                    /* 微信那套：一个红心 + 名字列表 */
                    HStack(alignment: .top, spacing: 4) {
                        Text("♥")
                            .font(pf(13))
                            .foregroundColor(Color(hex: 0xFF6B6B))
                        Text(likes.compactMap { $0.nickname }.joined(separator: "、"))
                            .font(pf(15))
                            .foregroundColor(C.link)
                    }
                }
                ForEach(comments.indices, id: \.self) { i in
                    let c = comments[i]
                    Text((c.nickname ?? "") + "：" + (c.content ?? ""))
                        .font(pf(15))
                        .foregroundColor(C.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        /* 微信：点自己发的评论 → 问你要不要删除 */
                        .onTapGesture {
                            if onDeleteComment != nil, !myId.isEmpty, c.userId == myId {
                                deletingComment = c.id
                            }
                        }
                }
            }
            .padding(.top, 9)
        }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 15)
        .padding(.bottom, 12)
        /* 微信那个小横条：贴着「···」左边弹出来，里面有「赞 | 评论」（自己的动态多一个删除） */
        .overlay(alignment: .bottomTrailing) {
            if showActions {
                actionBar
                    .offset(x: -34, y: -6)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        /* 点自己发的评论 → 删除（微信就是这样） */
        .confirmationDialog(Tr("删除这条评论？"), isPresented: Binding(
            get: { deletingComment != nil },
            set: { if !$0 { deletingComment = nil } }
        ), titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) {
                if let id = deletingComment { onDeleteComment?(id) }
                deletingComment = nil
            }
            Button(Tr("取消"), role: .cancel) { deletingComment = nil }
        }
    }

    private var grid: some View {
        MomentImageGrid(images: images,
                        avail: L.width - L.momentPadH * 2 - L.momentAvatar - 9,
                        onTap: { i in if i < images.count { onOpenImage?(images[i]) } })
    }

    /* 微信那个「赞 | 评论」小横条：深色底、白字白图标，贴着「···」左边 */
    private var actionBar: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                onLike?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "hand.thumbsup")
                        .font(.system(size: 12.5))
                    Text(moment.likedByMe == true ? Tr("取消赞") : Tr("赞"))
                        .font(pf(14.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(Color.white.opacity(0.22)).frame(width: 0.5, height: 18)

            Button {
                withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                onComment?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.right")
                        .font(.system(size: 12.5))
                    Text(Tr("评论")).font(pf(14.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if moment.mine == true, onDeleteMoment != nil {
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 0.5, height: 18)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                    onTogglePin?()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: moment.pinned == true ? "pin.slash" : "pin")
                            .font(.system(size: 12.5))
                        Text(moment.pinned == true ? Tr("取消置顶") : Tr("置顶")).font(pf(14.5))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Color.white.opacity(0.22)).frame(width: 0.5, height: 18)
                Button {
                    withAnimation(.easeOut(duration: 0.12)) { showActions = false }
                    onDeleteMoment?()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.82)))
        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
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
/* ============================================================
   发表页的九宫格拖动排序（微信：按住一张图拖到别的位置就换顺序）
   ============================================================ */
/* ============================================================
   换封面第二步：「拖动调整」
   上下左右拖、双指缩放，框住的那一块就是新封面 —— 点「完成」才保存。
   （微信也是这个流程：选完图不会立刻换，要你拖一下位置）
   ============================================================ */
struct CoverAdjustSheet: View {
    let image: UIImage
    let frameSize: CGSize
    var onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("拖动调整"), back: { dismiss() }) {
                Button {
                    render()
                } label: {
                    Text(Tr("完成"))
                        .font(pf(17, .semibold))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frameSize.width, height: frameSize.height)
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: frameSize.width, height: frameSize.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { v in
                        offset = CGSize(width: baseOffset.width + v.translation.width,
                                        height: baseOffset.height + v.translation.height)
                    }
                    .onEnded { _ in baseOffset = offset }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { m in scale = max(1, min(3, baseScale * m)) }
                    .onEnded { _ in baseScale = scale }
            )

            Text(Tr("拖动挪位置，双指缩放，点「完成」保存"))
                .font(pf(12.5))
                .foregroundColor(C.subLabel)
                .padding(.top, 14)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }

    /// 把「框住的那一块」画成一张图交给服务器
    @MainActor
    private func render() {
        /* 出图分辨率不看设备倍数，直接按「2048 像素宽」渲染 ——
           以前是按屏幕点数 ×3 渲染（比如 393×380 点 → 1179×1140），
           有的机型 / 有的系统版本 ImageRenderer 取到的倍数不对，出图就只有 393×380，
           传上去就是糊的（你的封面文件就是这么来的）。现在固定 2048 宽，怎么都不会糊。 */
        let targetW: CGFloat = 2048
        let targetH = (targetW * frameSize.height / max(1, frameSize.width)).rounded()
        let k = targetW / max(1, frameSize.width)          // 拖动/缩放的位移也要按同样的倍数放大
        let view = Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: targetW, height: targetH)
            .scaleEffect(scale)
            .offset(x: offset.width * k, y: offset.height * k)
            .frame(width: targetW, height: targetH)
            .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let out = renderer.uiImage { onDone(out) }
        dismiss()
    }
}

struct MomentGridDrop: DropDelegate {
    let index: Int
    @Binding var items: [UIImage]
    @Binding var dragIndex: Int?

    func dropEntered(info: DropInfo) {
        guard let from = dragIndex, from != index,
              items.indices.contains(from), items.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index)
        }
        dragIndex = index
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragIndex = nil
        return true
    }
}

/* ============================================================
   发表页「所在位置」：定位一次，反查出位置名（微信就是让你选一个地点）
   ============================================================ */

final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    static let shared = OneShotLocation()
    private let mgr = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation?, Never>?
    private var timeout: Task<Void, Never>?

    func current() async -> CLLocation? {
        /* 一分钟内定位过的位置直接用，省得每次都等 */
        if let l = mgr.location, abs(l.timestamp.timeIntervalSinceNow) < 60 { return l }
        if cont != nil { return mgr.location }        // 已经有一次在定位了，别叠着来
        await withCheckedContinuation { c in
            cont = c
            mgr.delegate = self
            mgr.desiredAccuracy = kCLLocationAccuracyHundredMeters
            let st = mgr.authorizationStatus
            if st == .notDetermined {
                /* 先要权限，等用户在弹窗上点了以后，授权回调里再真正请求位置。
                   以前是「要权限 + 立刻请求位置」一起发 —— 授权还没下来时那一次请求的
                   回调永远不会来，界面就一直卡在「正在定位」。 */
                mgr.requestWhenInUseAuthorization()
            } else if st == .denied || st == .restricted {
                finish(mgr.location)
            } else {
                mgr.requestLocation()
            }
            /* 8 秒还没结果就别让界面一直转：有上次的位置就用上次的，没有就给空 */
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { return }
                self?.finish(self?.mgr.location)
            }
        }
    }

    private func finish(_ loc: CLLocation?) {
        timeout?.cancel()
        timeout = nil
        cont?.resume(returning: loc)
        cont = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        if st == .notDetermined { return }
        if st == .denied || st == .restricted {
            finish(manager.location)
            return
        }
        if cont != nil { manager.requestLocation() }     // 授权刚下来：现在真正请求位置
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(manager.location)
    }
}

struct PlacePickerSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    @State private var places: [String] = []
    @State private var locating = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("所在位置"), back: { dismiss() })
            if locating {
                HStack { Spacer(); ProgressView(Tr("正在定位…")); Spacer() }
                    .frame(height: 90)
                    .background(C.cardBg)
            }
            ScrollView {
                VStack(spacing: 0) {
                    Button {
                        text = ""
                        dismiss()
                    } label: {
                        HStack {
                            Text(Tr("不显示位置")).font(pf(16)).foregroundColor(C.label)
                            Spacer()
                            if text.isEmpty { Image(systemName: "checkmark").foregroundColor(C.green) }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(places, id: \.self) { p in
                        HairLine(inset: 16)
                        Button {
                            text = p
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin.and.ellipse")
                                    .font(.system(size: 15)).foregroundColor(C.subLabel)
                                Text(p).font(pf(16)).foregroundColor(C.label)
                                Spacer()
                                if text == p { Image(systemName: "checkmark").foregroundColor(C.green) }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(C.cardBg)
                .padding(.top, 12)
            }
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            let loc = await OneShotLocation.shared.current()
            guard let loc = loc else { locating = false; return }
            if let marks = try? await CLGeocoder().reverseGeocodeLocation(loc), let m = marks.first {
                var list: [String] = []
                if let name = m.name, !name.isEmpty { list.append(name) }
                if let city = m.locality, !city.isEmpty, !list.contains(city) { list.append(city) }
                if let sub = m.subLocality, !sub.isEmpty, !list.contains(sub) { list.append(sub) }
                if let prov = m.administrativeArea, !prov.isEmpty, !list.contains(prov) { list.append(prov) }
                places = list
            }
            locating = false
        }
    }
}

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
        /* 用 Button 而不是 onTapGesture：手指在图上滑动（滚动朋友圈）时按钮会自动取消，
           以前用手势，滑动经常被当成「点开这张图」，看起来就是莫名其妙弹出一张图 */
        Button { onTap() } label: {
            RemoteImage(path: path, icon: "photo")
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
