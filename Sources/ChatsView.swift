import SwiftUI

struct ChatRow: View {
    let chat: Chat
    /// 点左边那个头像（只有机器人那几行给）：直接弹它自己的名片
    var onTapAvatar: (() -> Void)? = nil

    var body: some View {
        /* 微信的位置是固定的：头像在行高里居中，文字块和右边那列都从离顶 13 的地方开始 */
        HStack(alignment: .top, spacing: 0) {
            avatarBlock
                .padding(.top, avatarTop)
            Spacer().frame(width: L.rowGap)
            textColumn
                .padding(.top, L.rowPadTop)
            Spacer(minLength: 6)
            rightColumn
                .padding(.top, L.rowPadTop)
        }
        .padding(.leading, L.rowPadL)
        .padding(.trailing, L.rowPadR)
        .frame(height: L.rowH)
        .contentShape(Rectangle())
    }

    /// 头像在行高里居中（微信 76 的行、48 的头像 → 上下各 14）
    private var avatarTop: CGFloat { max(0, (L.rowH - L.avatar) / 2) }

    /// 头像：机器人那几行点它能弹名片，普通会话点了进聊天
    private var avatarBlock: some View {
        Group {
            if let tap = onTapAvatar {
                avatar.contentShape(Rectangle()).onTapGesture { tap() }
            } else {
                avatar
            }
        }
    }

    /// 名字在上、预览在下
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: L.rowTextGap) {
            Text(chat.name)
                .font(pf(L.rowNameSize))
                .foregroundColor(C.name)
                .lineLimit(1)
            Text(chat.lastMessage?.preview ?? "")
                .font(pf(L.rowPreviewSize))
                .foregroundColor(C.preview)
                .lineLimit(1)
        }
    }

    /// 右边一列：时间在上，未读徽标在下（微信就是这样，徽标不在头像上）
    private var rightColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(TimeFmt.list(chat.lastMessage?.createdAt ?? chat.updatedAt))
                .font(pf(L.rowTimeSize))
                .foregroundColor(C.time)
                .fixedSize()
            unreadMark
        }
    }

    /// 未读标记：普通会话给数字徽标；免打扰会话只给一个小红点（微信的规则）
    @ViewBuilder
    private var unreadMark: some View {
        if chat.unreadCount > 0 {
            if chat.muted == true {
                UnreadDot()
            } else {
                UnreadBadge(count: chat.unreadCount)
            }
        }
    }

    private var avatar: some View {
        Avatar(path: chat.avatar ?? "", size: L.avatar, radius: 4)
            /* 好友设了状态：头像右下角挂一个小 emoji（微信就是这样） */
            .overlay(alignment: .bottomTrailing) {
                if let icon = chat.moodIcon, !icon.isEmpty {
                    Text(icon)
                        .font(.system(size: 9))
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(C.cardBg))
                        .overlay(Circle().stroke(C.hairline, lineWidth: 0.5))
                        .offset(x: 5, y: 5)
                }
            }
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
    /// 机器人那几行：点头像弹名片（普通会话传 nil）
    var onTapAvatar: (() -> Void)? = nil
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

    /* 会话列表每一行也用「卡片底色」，和通讯录的卡片一个色；
       置顶的仍然用置顶色区分一下 */
    private var rowBg: Color { chat.pinned == true ? C.pinnedBg : C.chatsRowBg }

    var body: some View {
        ZStack(alignment: .trailing) {
            /* ① 行内容：跟着手指往左推 */
            ChatRow(chat: chat, onTapAvatar: onTapAvatar)
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
                .allowsHitTesting(offset != 0)
                .zIndex(2)
        }
        .frame(width: L.width, height: L.rowH, alignment: .leading)
        .clipped()
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            switch mode {
            case .none:
                /* 第一层：标为未读 / 不显示 / 删除，各一个按钮宽 */
                bar("标为未读", Color(hex: 0x07C160), btnW) {
                    onUnread()
                    close()
                }
                bar("不显示", Color(hex: 0xFA9D3C), btnW) {
                    mode = .hideConfirm
                    withAnimation(.easeOut(duration: 0.18)) { offset = -fullW }
                }
                bar("删除", Color(hex: 0xFA5151), btnW) {
                    mode = .delConfirm
                    withAnimation(.easeOut(duration: 0.18)) { offset = -fullW }
                }
            case .hideConfirm:
                /* 第二层：整条撑满，再点一下才真的不显示 */
                bar("不显示该聊天", Color(hex: 0xFA9D3C), fullW) {
                    onHide(false)
                    close()
                }
            case .delConfirm:
                /* 第二层：整条撑满，再点一下才真的删掉 */
                bar("清空记录同时不显示聊天", Color(hex: 0xE75E58), fullW) {
                    onDelete()
                    close()
                }
            }
        }
        .frame(width: max(0, -offset), height: L.rowH, alignment: .trailing)
        .clipped()
    }

    /// 一个可以点的长条（不用 Button：Button 在会滑动的行里容易点不到）
    private func bar(_ title: String, _ bg: Color, _ width: CGFloat,
                     action: @escaping () -> Void) -> some View {
        Text(title)
            .font(pfExact(btnFont))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: max(0, width), height: L.rowH)
            .background(bg)
            .contentShape(Rectangle())
            .onTapGesture { action() }
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
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var path = NavigationPath()
    @State private var plusMenu = false
    @State private var showScan = false
    /// 二楼「收付款」（我 → 服务 → 收付款 那一页）
    @State private var showPayCode = false
    @State private var openRow: String?
    /// 下拉二楼：会话列表滚到最上面之后再往下拉，露出二楼；上滑回去
    @State private var topOffset: CGFloat = 0
    /* ---------------------------------------------------------------
       下拉二楼：照微信官方那套状态机做
         Idle →（拉过二级阈值）CanTwoLevel →（松手）TwoLevelOpening → TwoLeveling
         TwoLeveling →（上滑 / 点里面的项）TwoLevelClosing → Idle
       两个阈值分开：打开用 openAt，往回关用 closeAt（迟滞，不会在边界抖）
       拉的距离直接取 UIScrollView 的 contentOffset（顶部往下拉是负数），
       不再用 SwiftUI 的 DragGesture 去和滚动抢手势 —— 那正是以前「拉不出来」的原因。
       --------------------------------------------------------------- */
    @State private var floorOpen = false          // == TwoLeveling
    @State private var pull: CGFloat = 0           // 手指下拉的距离（点）
    /// 这一把手指最多拉到多少 —— 松手那一下按它判断
    /// （松手时偏移可能已经弹回去了，光看当前值会判断不到）
    @State private var maxPull: CGFloat = 0
    @State private var dragging = false            // 手指正按着（UIScrollView.isDragging）
    @State private var canOpen = false             // == CanTwoLevel（超过二级阈值了）
    /// 二楼这整页露出来时，是不是已经把底部标签栏收起来了（收/放要配对）
    @State private var floorHidTab = false
    /// 打开二级的阈值（微信：refresher-two-level-threshold）
    private let floorOpenAt: CGFloat = 62
    /// 往回关的阈值（微信：refresher-two-level-close-threshold）—— 比打开的小，形成迟滞
    private let floorCloseAt: CGFloat = 34
    /// 先出现「圆点」的距离（微信下拉时先冒一个小圆点，再出内容）
    private let floorDotAt: CGFloat = 16
    /// 震动过没有（微信拉过阈值会「嗡」一下，只有一次）
    @State private var floorHapticDone = false
    /// 拉过二级阈值那一下的震动
    private func floorHaptic() {
        guard !floorHapticDone else { return }
        floorHapticDone = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 二楼露出的比例：0 = 完全收起，1 = 全部露出
    private var floorProgress: CGFloat {
        if floorOpen { return 1 }
        return min(1, pull / floorOpenAt)
    }
    /// 「圆点」阶段：还没到出内容的时候，只有一个小圆点跟着手指（微信就是这样）
    private var dotProgress: CGFloat {
        guard !floorOpen else { return 1 }
        return min(1, pull / floorDotAt)
    }
    /// 手指松开那一下做判断（微信：CanTwoLevel → 打开；否则弹回）
    private func floorRelease() {
        if !floorOpen {
            if maxPull >= floorOpenAt {
                floorHaptic()
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { floorOpen = true }
            } else {
                floorHapticDone = false
            }
        }
        maxPull = 0
    }
    /// 二楼收起（上滑 / 点完里面的项都走这里）
    private func closeFloor() {
        pull = 0
        maxPull = 0
        canOpen = false
        withAnimation(.spring(response: 0.40, dampingFraction: 0.86)) { floorOpen = false }
    }
    /// 「搜索」整页
    @State private var showSearch = false

    private struct ChatsTopKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    /// 二楼：微信那种面板（顶上一块空白页 + 最近使用的小程序 + 我的小程序）。
    /// 面板高度 = 会话列表这一块的高度（底部 4 个 tab 还在，微信就是这样，不是盖满整屏）
    private func secondFloorView(_ panelH: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            /* 顶上这条「搜索小程序」：微信二楼最上面就是这个搜索框（上面留出导航栏那块位置） */
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.searchIcon)
                Text(Tr("搜索小程序"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.searchBg))
            .padding(.horizontal, 16)
            .padding(.top, 50)

            /* 微信的二楼顶上是一块空白的页（没有搜索框），内容从下面这一行开始 */
            HStack(spacing: 6) {
                Text(Tr("最近使用的小程序"))
                    .font(pf(14.5, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(C.arrow)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4),
                      spacing: 18) {
                ForEach(floorItems.indices, id: \.self) { i in
                    let it = floorItems[i]
                    floorTile(it.0, it.1, it.2) { floorRun(it.0) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 16)

            HStack(spacing: 6) {
                Text(Tr("常用的小程序"))
                    .font(pf(14.5, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(C.arrow)
            }
            .padding(.horizontal, 16)
            .padding(.top, 30)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4),
                      spacing: 18) {
                ForEach(myFloorItems.indices, id: \.self) { i in
                    let it = myFloorItems[i]
                    floorTile(it.0, it.1, it.2) { floorRun(it.0) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 16)

            Spacer(minLength: 0)
            /* 最下面这一块：微信二楼里是「最近看过的直播、视频、文章」 */
            VStack(alignment: .leading, spacing: 8) {
                Text(Tr("最近看过的直播、视频、文章等将出现在这里。"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            HStack(spacing: 6) {
                Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                Text(Tr("上滑回到会话列表")).font(pf(12.5))
            }
            .foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: panelH, alignment: .top)
        .background(C.pageBg.ignoresSafeArea())
        .contentShape(Rectangle())
        /* 在二楼里往上滑 = 收回会话列表（微信就是这么退的） */
        .simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { v in
                if v.translation.height < -40 { closeFloor() }
            }
        )
    }

    /// 二楼第一组（常用入口）
    private var floorItems: [(String, String, Color)] {
        [("扫一扫", "qrcode.viewfinder", Color(hex: 0x2AAE67)),
         ("收付款", "yensign.circle.fill", Color(hex: 0xFA9D3C)),
         ("朋友圈", "photo.on.rectangle.angled", Color(hex: 0x1180E0)),
         ("视频号", "play.rectangle.fill", Color(hex: 0xE2A03C))]
    }
    /// 二楼第二组（我的小程序）
    private var myFloorItems: [(String, String, Color)] {
        [("收藏", "star.fill", Color(hex: 0xE2A03C)),
         ("直播", "video.fill", Color(hex: 0xFA5151)),
         ("游戏", "gamecontroller.fill", Color(hex: 0x8A6FE8)),
         ("搜一搜", "magnifyingglass", Color(hex: 0x1180E0)),
         ("摇一摇", "iphone.radiowaves.left.and.right", Color(hex: 0x2AAE67)),
         ("附近", "location.fill", Color(hex: 0x10AEFF)),
         ("刷新会话", "arrow.clockwise", Color(hex: 0x8A8A8E)),
         ("设置", "gearshape.fill", Color(hex: 0x8A8A8E))]
    }

    private func floorRun(_ label: String) {
        switch label {
        case "扫一扫": showScan = true
        case "刷新会话":
            Task { await app.loadChats() }
            app.show(Tr("会话已刷新"))
        case "收付款": showPayCode = true
        case "朋友圈": app.show(Tr("去「发现 → 朋友圈」就能发"))
        case "视频号": app.show(Tr("去「发现 → 视频号」看视频"))
        case "收藏": app.show(Tr("去「我 → 收藏」看收藏的内容"))
        case "直播": app.show(Tr("去「发现 → 直播」看正在播的"))
        case "游戏": app.show(Tr("去「发现 → 游戏」"))
        case "搜一搜": app.show(Tr("点会话页上面的搜索框就能搜"))
        case "摇一摇": app.show(Tr("去「发现 → 摇一摇」"))
        case "附近": app.show(Tr("去「发现 → 附近」"))
        case "设置": app.show(Tr("去「我 → 设置」"))
        default: break
        }
        /* 点完一项就把二楼收回去（微信也是点完就回到会话列表） */
        closeFloor()
    }

    /// 一个小程序格子：圆角方块图标 + 名字（微信那种）
    private func floorTile(_ title: String, _ symbol: String, _ color: Color, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [color.opacity(0.26), color.opacity(0.12)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 54, height: 54)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(color.opacity(0.18), lineWidth: 1)
                        .frame(width: 54, height: 54)
                    Image(systemName: symbol)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundColor(color)
                }
                Text(Tr(title))
                    .font(pf(12))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
    /// 点会话列表里机器人那几行的头像 → 弹它的名片
    @State private var botCardChat: Chat?
    /// 点左上角那两只眼睛 → 打开「小星」自己的对话页（元宝那种，不是普通聊天页）
    @State private var botChat: Chat?

    private var list: [Chat] {
        /* 贾维斯从列表里拿掉（它改成左上角那只小脸，点脸进对话） */
        let base = app.chats.filter { $0.botRank != 0 }
        guard !keyword.isEmpty else { return base }
        return base.filter {
            $0.name.contains(keyword) || (($0.lastMessage?.preview ?? "").contains(keyword))
        }
    }

    /// 和网页版一样：有未读时标题变成「微信(3)」
    private var navTitle: String {
        let total = app.chats.reduce(0) { $0 + ($1.unread ?? 0) }
        /* 顶栏文字后台可改（tabTitle0），有未读时还是「文字(3)」 */
        return total > 0 ? "\(C.tabText0)(\(total))" : C.tabText0
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                /* 微信的逻辑（对着桌面 s 文件夹的参考图）：顶栏固定不动，
                   搜索框和列表一起跟着手指滚 —— 上滑搜索框会滚走，下拉它会跟着下来。 */
                VStack(spacing: 0) {
                    /* 顶栏固定不动 —— 对着桌面 s 文件夹那两张参考图量的：
                       微信在两张图里都在同一行（y 224~252），动的是搜索框和列表。 */
                    /* 顶栏左上角：小星的两只眼睛（和微信「小微」一个位置）。
                       点它 = 进**小星自己的对话页**（元宝那种：AI 不用气泡、旁边就是这双眼睛），
                       不是普通聊天页 —— 列表里那条也已经拿掉。 */
                    NavBar(title: navTitle,
                           leftExtra: AnyView(
                            Button {
                                if let bot = app.chats.first(where: { $0.botRank == 0 }) {
                                    botChat = bot
                                } else {
                                    Task { await app.loadChats()
                                        if let b = app.chats.first(where: { $0.botRank == 0 }) { botChat = b } }
                                }
                            } label: {
                                JarvisEyesAvatar(size: 28).padding(.leading, 12)
                            }
                            .buttonStyle(.plain)
                           )) {
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
                }

                if app.chats.isEmpty {
                    emptyView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            /* 搜索框放进滚动区里：上滑会跟着列表一起滚走，
                               下拉会跟着列表一起下来 —— 微信就是这样（参考图里第二张搜索框已经滚没了）。 */
                            /* 用来读滚动偏移：滚到顶之后再往下拉就露二楼 */
                            GeometryReader { geo in
                                Color.clear.preference(key: ChatsTopKey.self,
                                                       value: geo.frame(in: .named("chatsScroll")).minY)
                            }
                            .frame(height: 0)
                            /* 微信那样：这个框不是就地过滤，点一下进「搜索」整页
                               （上面一排「搜索指定内容」+ 最近搜索） */
                            Button {
                                showSearch = true
                            } label: {
                                SearchBoxCenter(text: .constant(""))
                            }
                            .buttonStyle(.plain)
                            .padding(L.searchPad)
                            /* 和通讯录一样用「页面底色」，两页看着才是同一个色 */
                            .background(C.chatsPageBg)
                            /* 下拉露二楼的时候这条搜索框要淡出：
                               微信拉下来是「最上面一块空白页」，搜索框不能跟着二楼一起冒出来 */
                            .opacity(Double(1 - min(1, floorProgress * 5)))
                            .allowsHitTesting(floorProgress <= 0.01)
                            ForEach(list) { chat in
                                SwipeChatRow(
                                    chat: chat,
                                    onOpen: { path.append(chat) },
                                    /* 只有真的机器人（botRank 0/1/2）点头像才弹「官方账号」名片；
                                       好友/群聊点头像跟整行一样进聊天（微信就是这样） */
                                    onTapAvatar: ((chat.botRank ?? 9) < 9) ? { botCardChat = chat } : nil,
                                    onUnread: { markUnread(chat) },
                                    onHide: { clear in hide(chat, clear: clear) },
                                    onDelete: { remove(chat) }
                                )
                            }
                        }
                    }
                    /* 列表这一块故意不加底色（底色在下面那层 VStack 上）：
                       下拉时消息整体往下走，顶上会空出一条，正好让顶栏那几个字
                       从搜索框底下钻出来以后还能在这里继续跟着手指走。
                       如果这里铺一层实底色，字就会被这块盖住，看起来像「不会跟手」。 */
                    .background(Color.clear)
                    /* 微信的会话列表本来就没有「下拉刷新」（下拉是二楼），
                       这里把系统的下拉刷新去掉：一来更像微信，二来不会和二楼抢同一个下拉手势。
                       要刷新的地方放两处：二楼里的「刷新会话」、以及实时消息本来就会自动更新。 */
                    .coordinateSpace(name: "chatsScroll")
                    /* 用 UIKit 实时拿滚动偏移 + 是否正在拖。
                       顶部继续往下拉时 contentOffset.y 是负数（UIScrollView 的橡皮筋），
                       这个负值就是微信里「拉了多远」，不用再自己抢手势。 */
                    .background(ScrollOffsetProbe(
                        onChange: { y in
                            topOffset = y
                            if !floorOpen {
                                let now = max(0, -y)
                                /* 直接跟着偏移走：拉的时候变大，松手回弹时自然缩回 0 */
                                pull = now
                                maxPull = max(maxPull, now)
                                let over = now >= floorOpenAt
                                if over && !canOpen { floorHaptic() }   // 拉过阈值震一下
                                canOpen = over
                            }
                        },
                        onDragChange: { d in
                            dragging = d
                            if !d { floorRelease() }        // 松手：过阈值就停在二楼
                        })
                    )
                    /* 偏移统一由上面的 ScrollOffsetProbe 提供；这里不再用 PreferenceKey，
                       免得两个来源互相覆盖（以前就是这里不稳，导致二楼拉不下来） */
                }
            }
            /* 第一页面（会话列表）的底色跟通讯录统一：都用后台的「页面底色」pageBg，
               以前这里用的是 navBg，深色下比通讯录浅一档（#18181A vs #0B0B0D）。 */
            /* 微信那个转场：二楼出来的时候，会话列表这一页会略微缩小 + 压暗一点（有层次） */
            .scaleEffect(1 - 0.03 * floorProgress, anchor: .top)
            .brightness(-0.05 * Double(floorProgress))
            .background(C.chatsPageBg.ignoresSafeArea(edges: .bottom))
            /* 下拉二楼：露出来的时候盖在最上面（上滑/点一下里面的项就回去） */
            .overlay(alignment: .top) {
                /* 手指拉多少，二楼就露多少；拉过阈值松手就整页停住。
                   另外按微信那样：还没拉到内容之前先出一个「圆点」。 */
                GeometryReader { geo in
                    let full = max(geo.size.height, UIScreen.main.bounds.height)
                    let reveal = floorOpen ? full : min(full, pull)
                    ZStack(alignment: .top) {
                        /* 圆点阶段（微信：下拉先冒一个圆点，继续拉才出内容） */
                        if !floorOpen && pull > 0 {
                            Circle()
                                .fill(Color.dyn(0xB8B8BD, 0x8E8E93))
                                .frame(width: 7, height: 7)
                                .scaleEffect(0.4 + 0.6 * dotProgress)
                                .opacity(Double(dotProgress) * 0.9)
                                .padding(.top, L.navH + 6)
                                .frame(maxWidth: .infinity)
                        }
                        secondFloorView(reveal)
                            .frame(maxWidth: .infinity, alignment: .top)
                            .clipped()
                            .opacity(reveal > 1 ? 1 : 0)
                            .allowsHitTesting(floorOpen)
                    }
                }
            }
            .sheet(isPresented: $showSearch) {
                SearchPage(onOpenChat: { c in path.append(c) })
                    .environmentObject(app)
            }
            .background(C.chatsPageBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
            .navigationDestination(for: String.self) { key in
                if key == "newGroup" {
                    GroupCreateView { chat in
                        /* 建完群直接进这个群：走最外层整页打开，
                           不往导航栈里 push（push 在「刚 pop 掉建群页」那一下容易被系统丢掉，
                           表现就是「建完群没跳进去，要退出来重新点一下」）。 */
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.openChat = chat }
                    }
                } else if key == "addFriend" {
                    AddFriendView()
                } else if key == "myQR" {
                    MyQRView()
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        .confirmationDialog("", isPresented: $plusMenu, titleVisibility: .hidden) {
            Button(Tr("发起群聊")) { path.append("newGroup") }
            Button(Tr("添加朋友")) { path.append("addFriend") }
            Button(Tr("扫一扫")) { showScan = true }
            Button(Tr("收付款")) { showPayCode = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        /* 小星对话页：整页打开（点左上角那两只眼睛进来） */
        .fullScreenCover(item: $botChat) { c in
            BotChatView(chat: c).environmentObject(app)
        }
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        .sheet(item: $botCardChat) { c in
            BotCardView(chat: c).environmentObject(app)
        }
        .sheet(isPresented: $showPayCode) {
            NavigationStack { PayCodePage() }
                .environmentObject(app)
        }
        .task {
            // 进页面先拉一次，之后每 4 秒自动刷新一次（这样别人发消息不用切页就能看到）
            while !Task.isCancelled {
                await app.loadChats()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        /* 点推送通知进聊天：统一交给最外层的 MainTab 处理（它永远在线，
           在别的 tab 上点通知也能进得去；以前挂在会话页，人不在会话页就收不到）。 */
        /* 二楼是单独的一整页 —— 露出来的时候把底部 4 个 tab 收起来（微信就是这样盖满整屏） */
        .onChange(of: floorOpen) { v in
            if v && !floorHidTab {
                floorHidTab = true
                app.tabBarDepth += 1
            } else if !v && floorHidTab {
                floorHidTab = false
                app.tabBarDepth = max(0, app.tabBarDepth - 1)
            }
        }
        .onDisappear {
            if floorHidTab {
                floorHidTab = false
                app.tabBarDepth = max(0, app.tabBarDepth - 1)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(app.loadError ?? "正在加载会话…")
                .font(pf(14))
                .foregroundColor(C.subLabel)
            if app.loadError != nil {
                Button(Tr("重试")) { Task { await app.loadChats() } }
                    .font(pf(15))
                    .foregroundColor(C.green)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(C.chatsPageBg)
    }

    private func markUnread(_ chat: Chat) {
        Task {
            await API.shared.markUnread(chatId: chat.id)
            await app.loadChats()
            app.show(Tr("已标为未读"))
        }
    }

    private func hide(_ chat: Chat, clear: Bool) {
        Task {
            let err = clear
                ? await API.shared.deleteChat(chatId: chat.id)
                : await API.shared.hideChat(chatId: chat.id)
            await app.loadChats()
            app.show(err ?? (clear ? "已清空记录并设为不显示" : "已不显示该聊天"))
        }
    }

    private func remove(_ chat: Chat) {
        Task {
            let err = await API.shared.deleteChat(chatId: chat.id)
            await app.loadChats()
            app.show(err ?? "已删除")
        }
    }
}
