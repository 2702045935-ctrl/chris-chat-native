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
    @State private var openRow: String?
    /// 下拉二楼：会话列表滚到最上面之后再往下拉，露出二楼；上滑回去
    @State private var topOffset: CGFloat = 0
    /// 二楼已经「停住」了（手指松开也保持在二楼，微信就是这样）
    @State private var floorOpen = false
    /// 手指往下拖的距离（只在自己滚到最顶上时才算数）
    @State private var dragPull: CGFloat = 0
    /// 拉开多少才算是「要停在二楼」（微信也是拉过一半就翻过去）
    private let floorOpenAt: CGFloat = 58

    /// 二楼露出多少：0 = 完全收起，1 = 全部露出。跟着手指走（拉的越多露的越多）
    private var floorProgress: CGFloat {
        if floorOpen { return 1 }
        /* 两个来源取大的：
           ① 滚动偏移（滚到顶还继续下拉时的橡皮筋）；
           ② 手指拖动量（更稳，不再依赖橡皮筋一定能读到） */
        let byOffset = max(0, topOffset)
        let byDrag = (topOffset <= 0.5) ? max(0, dragPull) : 0
        return min(1, max(byOffset, byDrag) / 130)
    }
    /// 二楼收起（上滑 / 点完里面的项都走这里）
    private func closeFloor() {
        dragPull = 0
        floorOpen = false
    }
    /// 「搜索」整页
    @State private var showSearch = false

    private struct ChatsTopKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    /// 二楼：微信那种面板（搜索框 + 最近使用的小程序 + 我的小程序）。
    /// 面板高度 = 会话列表这一块的高度（底部 4 个 tab 还在，微信就是这样，不是盖满整屏）
    private func secondFloorView(_ panelH: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            /* 顶上这个搜索框就是微信二楼那一条：整宽、圆角、灰底 */
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(C.searchIcon)
                Text(Tr("搜索"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.searchBg))
            .padding(.horizontal, 12)
            .padding(.top, 10)

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
            .padding(.top, 28)

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
                Text(Tr("我的小程序"))
                    .font(pf(14.5, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 4)
                Text(Tr("更多")).font(pf(13)).foregroundColor(C.subLabel)
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
        case "收付款": app.show(Tr("收付款在「我 → 服务 → 收付款」里"))
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
                    /* 顶栏左上角：贾维斯的小脸（和微信「小微」一个位置）。
                       点这张脸 = 直接进贾维斯的对话（列表里那一条已经拿掉）。 */
                    NavBar(title: navTitle,
                           leftExtra: AnyView(
                            Button {
                                if let jarvis = app.chats.first(where: { $0.botRank == 0 }) {
                                    path.append(jarvis)
                                } else {
                                    Task { await app.loadChats()
                                        if let j = app.chats.first(where: { $0.botRank == 0 }) { path.append(j) } }
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
                    /* 手指往下拖的时候直接算「拉了多远」：滚到最顶上才生效，松手弹回去 */
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { v in
                                guard !floorOpen else { return }
                                if v.translation.height > 0 && topOffset <= 0.5 {
                                    dragPull = min(160, v.translation.height)
                                } else if v.translation.height < -4 {
                                    dragPull = 0
                                }
                            }
                            .onEnded { _ in
                                /* 拉过一半就停在二楼（跟微信一样，松手不会自己缩回去）；
                                   只拉一点点就弹回会话列表 */
                                if max(dragPull, max(0, topOffset)) >= floorOpenAt {
                                    dragPull = 0
                                    withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                                        floorOpen = true
                                    }
                                } else {
                                    dragPull = 0
                                }
                            }
                    )
                    .onPreferenceChange(ChatsTopKey.self) { y in
                        topOffset = y
                    }
                }
            }
            /* 第一页面（会话列表）的底色跟通讯录统一：都用后台的「页面底色」pageBg，
               以前这里用的是 navBg，深色下比通讯录浅一档（#18181A vs #0B0B0D）。 */
            .background(C.chatsPageBg.ignoresSafeArea(edges: .bottom))
            /* 下拉二楼：露出来的时候盖在最上面（上滑/点一下里面的项就回去） */
            .overlay(alignment: .top) {
                /* 二楼跟着手指走：拉 130pt 就完全露出，拉过一半松手就停在二楼（微信那种手感） */
                GeometryReader { geo in
                    secondFloorView(geo.size.height)
                        .offset(y: (floorProgress - 1) * geo.size.height)
                        .opacity(floorProgress > 0.02 ? 1 : 0)
                        .allowsHitTesting(floorProgress > 0.5)
                        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: floorProgress)
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { path.append(chat) }
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
            Button(Tr("取消"), role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        .sheet(item: $botCardChat) { c in
            BotCardView(chat: c).environmentObject(app)
        }
        .task {
            // 进页面先拉一次，之后每 4 秒自动刷新一次（这样别人发消息不用切页就能看到）
            while !Task.isCancelled {
                await app.loadChats()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        /* 点了推送通知 → 直接进那个人的聊天（服务器在通知里带了 chatId） */
        .onReceive(NotificationCenter.default.publisher(for: .chrisOpenChat)) { note in
            guard let chatId = note.userInfo?["chatId"] as? String, !chatId.isEmpty else { return }
            Task {
                await app.loadChats()
                if let c = app.chats.first(where: { $0.id == chatId }) {
                    path.append(c)
                } else {
                    app.show(Tr("找不到这个会话"))
                }
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
