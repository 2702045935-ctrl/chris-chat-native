import SwiftUI
import UIKit

/* ============================================================ 底部四个标签 */

struct MainTabView: View {
    @EnvironmentObject var app: AppState
    @State private var tab = 0
    @State private var shownCrash = false
    /* 读一下语言状态：切语言时这一层会重画（不重建整棵树，避免闪退） */
    @ObservedObject private var lang = LangStore.shared
    /* 未实名动钱时的全局提示（和微信一样：聊天不受影响，只有钱的功能要求实名） */
    @ObservedObject private var realNameGate = RealNameGate.shared

    private var unreadTotal: Int {
        app.chats.reduce(0) { $0 + ($1.unread ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if tab == 0 {
                    ChatsView()
                } else if tab == 1 {
                    ContactsView()
                } else if tab == 2 {
                    DiscoverView()
                } else {
                    MeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            /* 登录后同步最近聊天记录：顶上挂一条小小的进度提示（同步是后台做的，不拦着用） */
            /* 登录后同步：微信那种居中的「正在同步最近的聊天记录…」卡片
               （同步很快，卡片是淡入淡出；不拦着用户操作） */
            .overlay {
                if app.syncing || !app.syncText.isEmpty {
                    ZStack {
                        Color.black.opacity(0.16).ignoresSafeArea()
                        VStack(spacing: 14) {
                            if app.syncing { ProgressView().scaleEffect(1.15) }
                            Text(app.syncing ? "正在同步最近的聊天记录…"
                                             : (app.syncText.isEmpty ? "已同步最近的聊天记录" : app.syncText))
                                .font(pf(14))
                                .foregroundColor(C.label)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 22)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(C.cardBg))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(C.hairline, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 4)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }

            if !app.tabBarHidden {
                TabBar(selection: $tab,
                       badge: app.showDot("chats", auto: unreadTotal > 0) ? unreadTotal : 0,
                       contactsDot: app.showDot("contacts", auto: app.friendRequests > 0),
                       momentsDot: app.showDot("discover", auto: app.momentsUnread > 0),
                       meDot: app.showDot("me", auto: false))
                    .transition(.move(edge: .bottom))
            }
        }
        /* 整块内容区的底色跟页面一致（深色下 navBg 是炭黑 #18181A，比页面 #0B0B0D 浅一档，
           状态栏那一条会看出「顶部是炭黑」）。底栏自己用 tabBg，比页面浅一点是对的。 */
        .background(C.pageBg.ignoresSafeArea())
        /* 注意：这里以前有一句 .animation(…, value: app.tabBarHidden)。
           它会让「整块内容区」在标签栏显隐时一起做动画 —— 打开聊天页（藏标签栏）那一下
           「上下缩放」就是这么来的。改成不给容器加动画：标签栏直接让位，页面照常推进来。 */
        /* 真人语音/视频通话：来电、通话界面挂在最外层，任何页面都能弹出来 */
        .overlay(CallOverlay())
        /* 上次崩过的话，进来就把崩溃信息弹出来（截图给我就能定位） */
        .sheet(isPresented: Binding(
            get: { !(UserDefaults.standard.string(forKey: "chris.lastCrash") ?? "").isEmpty && !shownCrash },
            set: { v in shownCrash = true })) {
                CrashLogView()
        }
        /* 接通 / 挂断弹的对话框（颜色圆角和聊天那个框一样），等用户点「确定」或超时自己关 */
        .overlay(CallDialogOverlay())
        /* 扫到收付款码：不管在哪个页面扫的，都在最外层弹确认付款页 */
        .sheet(item: $app.payScan) { info in
            PayConfirmPage(target: info, scanText: app.payScanText)
                .environmentObject(app)
        }
        /* 未实名却动了钱：弹微信那种对话框，点「去实名认证」直接进实名页 */
        .alert("根据国家规定", isPresented: $realNameGate.alert) {
            Button("去实名认证") { realNameGate.openPage = true }
            Button("取消", role: .cancel) { }
        } message: {
            Text("请先完成实名认证，之后才能使用转账、红包、收付款、零钱等功能。聊天不受影响。")
        }
        .sheet(isPresented: $realNameGate.openPage) {
            RealNameView().environmentObject(app)
        }
        /* 全局打开聊天：扫码进群 / 建完群 / 点推送都走这里（整页打开，不受当前在哪个 tab 影响） */
        .fullScreenCover(item: $app.openChat) { c in
            ChatDetailView(chat: c).environmentObject(app)
        }
        /* 点推送通知 → 直接进那个会话（服务器在通知里带了 chatId） */
        .onReceive(NotificationCenter.default.publisher(for: .chrisOpenChat)) { note in
            guard let chatId = note.userInfo?["chatId"] as? String, !chatId.isEmpty else { return }
            Task { @MainActor in
                await app.loadChats()
                if let c = app.chats.first(where: { $0.id == chatId }) {
                    app.openChat = c
                } else {
                    app.show(Tr("找不到这个会话"))
                }
            }
        }
    }
}

struct TabBar: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Binding var selection: Int
    var badge: Int
    /// 「通讯录」上那个小红点（有人加你为好友就亮，微信也是这样）
    var contactsDot: Bool = false
    /// 「发现」上那个小红点（有人发朋友圈就亮）
    var momentsDot: Bool = false
    /// 「我」上那个小红点（后台可以设成一直亮）
    var meDot: Bool = false

    private var items: [(String, String, String)] {
        [
            ("message", "message.fill", C.tabText0),
            ("person.2", "person.2.fill", C.tabText1),
            ("safari", "safari", C.tabText2),
            ("person.crop.circle", "person.crop.circle.fill", C.tabText3)
        ]
    }

    /// 每个图标能单独调大小：ui.json 里写 tabIcon0 / tabIcon1 / tabIcon2 / tabIcon3
    /// （0=微信 1=通讯录 2=发现 3=我）。SF Symbols 各图标自带的留白不一样，
    /// 微信和通讯录那两个本来就更满，所以默认给小一号。
    private func iconFont(_ i: Int) -> Font {
        let def = (i == 0 || i == 1) ? L.tabIcon - 2 : L.tabIcon
        return pf(UIConfig.num("tabIcon\(i)", def))
    }

    /// 底栏四个图标也允许在后台换掉
    private let customKeys = ["tab.chat", "tab.contacts", "tab.discover", "tab.me"]

    /// 自己上传/换过的图标（SVG、图片）用多大：跟内置图标一样吃 tabIcon0…3 的设置，
    /// 这样后台「界面文字」里调大小，两套图标一起变。
    private func customSize(_ i: Int) -> CGFloat {
        UIConfig.num("tabIcon\(i)", L.tabIconBox)
    }

    /* 底栏颜色（对着桌面 vx 文件夹那张参考图做的）：
       选中的是**深色实心**图标 + 深色字，没选中的是灰色描边图标 + 灰字，不用绿色。
       想改颜色：后台 ui.json 里加 tabSelColor / tabUnselColor（#浅色|#深色）。 */
    private var selColor: Color { UIConfig.color("tabSelColor", 0x1A1A1A, 0xEDEDED) }
    private var unselColor: Color { UIConfig.color("tabUnselColor", 0x6B6B6B, 0x8E8E93) }
    /// 选中那格图标大一点点（参考图里就是这样）
    private func tabIconFont(_ i: Int, on: Bool) -> Font {
        let base = UIConfig.num("tabIcon\(i)", (i == 0 || i == 1) ? L.tabIcon - 2 : L.tabIcon)
        return pf(on ? base + 1.5 : base)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                Button {
                    selection = i
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            if let custom = IconOverrides.custom(customKeys[i]) {
                                /* 自己上传的图片图标：当模板图渲染，这样选中变绿、未选中变灰，
                                   和内置图标一个观感（图片本身是透明底的黑图形）。 */
                                if custom.hasPrefix("http") || custom.hasPrefix("/uploads") || custom.hasPrefix("data:") {
                                    RemoteImage(path: custom, template: true)
                                        .frame(width: customSize(i), height: customSize(i))
                                        .foregroundColor(selection == i ? selColor : unselColor)
                                } else {
                                    FlexIcon(custom: custom, size: customSize(i),
                                             color: selection == i ? selColor : unselColor,
                                             symbol: items[i].0)
                                }
                            } else if i == 3, let av = app.me?.avatarPath, !av.isEmpty {
                                /* 「我」这一格不放图标，直接用我自己的头像 */
                                Avatar(path: av, size: UIConfig.num("tabAvatar", 24), radius: 0, circle: true)
                                    .overlay(Circle().stroke(selection == i ? selColor : Color.clear, lineWidth: 1.5))
                            } else {
                                Image(systemName: selection == i ? items[i].1 : items[i].0)
                                    .font(tabIconFont(i, on: selection == i))
                                    .frame(width: L.tabIconBox, height: L.tabIconBox)
                            }
                            if i == 0 && badge > 0 {
                                Text(badge > 99 ? "99+" : "\(badge)")
                                    .font(pf(11, .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill(C.red))
                                    .offset(x: 9, y: -6)
                            }
                            // 发现：有人发朋友圈就一个红点（微信就是这样，不带数字）
                            if i == 2 && momentsDot {
                                Circle()
                                    .fill(C.red)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(C.tabBg, lineWidth: 1.5))
                                    .offset(x: 5, y: -3)
                            }
                            // 通讯录：有人加你好友就一个红点
                            if i == 1 && contactsDot {
                                Circle()
                                    .fill(C.red)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(C.tabBg, lineWidth: 1.5))
                                    .offset(x: 5, y: -3)
                            }
                            // 我：后台设成「一直亮」时显示
                            if i == 3 && meDot {
                                Circle()
                                    .fill(C.red)
                                    .frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(C.tabBg, lineWidth: 1.5))
                                    .offset(x: 5, y: -3)
                            }
                        }
                        Text(items[i].2)
                            .font(pf(UIConfig.num("tabLabel", L.tabLabel),
                                     selection == i ? .medium : .regular))
                    }
                    .foregroundColor(selection == i ? selColor : unselColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: L.tabH)
        .background(
            ZStack {
                C.tabBg.ignoresSafeArea(edges: .bottom)
                VStack(spacing: 0) {
                    Rectangle().fill(C.navLine).frame(height: 0.5)
                    Spacer()
                }
                .ignoresSafeArea(edges: .bottom)
            }
        )
    }
}

/* ============================================================ 顶部导航条 */

struct NavBar<Right: View>: View {
    let title: String
    let back: (() -> Void)?
    let onLongPressTitle: (() -> Void)?
    /// 返回箭头右边可以插一小块内容（聊天页那个未读数字就放这儿）
    let leftExtra: AnyView?
    private let right: Right

    init(title: String,
         back: (() -> Void)? = nil,
         onLongPressTitle: (() -> Void)? = nil,
         leftExtra: AnyView? = nil,
         @ViewBuilder right: () -> Right) {
        self.title = title
        self.back = back
        self.onLongPressTitle = onLongPressTitle
        self.leftExtra = leftExtra
        self.right = right()
    }

    var body: some View {
        ZStack {
            // 加黑程度可以在后台「界面文字」里调：navTitleStroke
            // 0 = 不加（苹方 Semibold 本身）· 0.2 = 加一点 · 0.4 = 更黑
            titleText
            if titleStroke > 0 {
                titleText.offset(x: titleStroke)
            }

            HStack(spacing: 0) {
                if let back = back {
                    Button(action: back) {
                        FlexIcon(custom: IconOverrides.custom("nav.back"), size: 20,
                                 color: C.label, symbol: "chevron.left", weight: .medium)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }
                if let leftExtra = leftExtra {
                    leftExtra
                        .frame(height: L.navH)
                }
                Spacer(minLength: 0)
                right
            }
        }
        .frame(height: L.navH)
    }

    private var titleText: some View {
        Text(title)
            .font(pf(titleSize, weight))
            .foregroundColor(C.label)
            .onLongPressGesture { onLongPressTitle?() }
    }

    /// 顶部标题：默认 17（发现页小一号 16）；想再调就改 ui.json 里的 navTitle
    private var titleSize: CGFloat {
        let base = UIConfig.num("navTitle", 17)
        return title == "发现" ? base - 1 : base
    }
    /// 顶部标题字重：明显加黑（苹方 Semibold，和手机微信一致）
    private var weight: Font.Weight { .semibold }

    /// 描叠偏移（在后台默认 0：只保留苹方 Semibold，不再叠第二遍）
    private var titleStroke: CGFloat { UIConfig.num("navTitleStroke", 0) }
}

extension NavBar where Right == EmptyView {
    init(title: String,
         back: (() -> Void)? = nil,
         onLongPressTitle: (() -> Void)? = nil,
         leftExtra: AnyView? = nil) {
        self.init(title: title, back: back, onLongPressTitle: onLongPressTitle,
                  leftExtra: leftExtra) { EmptyView() }
    }
}

/* ============================================================ 搜索框 */

/// 微信页：纯白、圆角 5、没输入时「放大镜 + 搜索」整组居中（和手机微信一样）
struct SearchBoxCenter: View {
    @Binding var text: String
    var externalFocus: FocusState<Bool>.Binding? = nil
    @FocusState private var localFocus: Bool

    private var focused: Bool { externalFocus?.wrappedValue ?? localFocus }

    private var centered: Bool { text.isEmpty && !focused }

    @ViewBuilder
    private var field: some View {
        let tf = TextField("", text: $text)
            .font(pf(16))
            .foregroundColor(C.label)
            .multilineTextAlignment(centered ? .center : .leading)
        if let externalFocus = externalFocus {
            tf.focused(externalFocus)
        } else {
            tf.focused($localFocus)
        }
    }

    var body: some View {
        HStack(spacing: centered ? 3 : 5) {
            SVGIcon(markup: I.searchSmall, size: 16, color: C.searchIcon)

            ZStack(alignment: centered ? .center : .leading) {
                if text.isEmpty {
                    Text(Tr("搜索"))
                        .font(pf(16))
                        .foregroundColor(C.searchIcon)
                }
                field
            }
            .frame(maxWidth: centered ? 46 : .infinity)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .padding(.leading, centered ? 28 : 9)
        .padding(.trailing, centered ? 18 : 9)
        .frame(height: L.searchBoxH)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(C.searchBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(C.searchBorderChats, lineWidth: 1)
        )
    }
}

/// 通讯录页：圆角 10、带一点阴影、放大镜在左、「搜索」左对齐
struct SearchBoxLeft: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: L.v(5, 1.8, 8)) {
            SVGIcon(markup: I.searchBig, size: 16, color: C.searchIcon2)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(Tr("搜索"))
                        .font(pf(15))
                        .foregroundColor(C.searchIcon2)
                }
                TextField("", text: $text)
                    .font(pf(15))
                    .foregroundColor(C.label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .frame(height: L.searchBoxH)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(C.searchBg)
                .shadow(color: Color.black.opacity(0.04), radius: 1, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(C.searchBorder, lineWidth: 1)
        )
    }
}

/* ============================================================ 通用行 */

/// 发现页 / 我页 / 设置页的一行：图标 + 文字 +（右侧值）+ 箭头
struct MenuRow: View {
    let icon: String
    var iconColor: Color = C.green
    /// 参考图：发现页和我页的行都是左边距 18、图标 22、间距 18 → 文字落在 x=58
    var padLeading: CGFloat = 18
    let title: String
    var detail: String = ""
    var showArrow: Bool = true
    var badge: Bool = false
    var thumb: String = ""
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: L.menuGap) {
                SVGIcon(markup: icon, size: L.menuIcon * 1.13, color: iconColor)
                    .frame(width: L.menuIcon, height: L.menuIcon)

                Text(title)
                    .font(pf(L.menuTextSize))
                    .foregroundColor(C.label)

                Spacer(minLength: 0)

                if !detail.isEmpty {
                    Text(detail).font(pf(15)).foregroundColor(C.subLabel)
                }
                if !thumb.isEmpty {
                    ZStack(alignment: .topTrailing) {
                        RemoteImage(path: thumb)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        if badge {
                            Circle().fill(C.red).frame(width: 9, height: 9).offset(x: 4.5, y: -4.5)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .padding(.trailing, -8)
                }
                if showArrow {
                    Chevron(size: 9, line: 1.6)
                        .padding(.trailing, 3)
                }
            }
            .padding(.leading, padLeading)
            .padding(.trailing, L.menuPadR)
            .frame(height: L.menuH)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }
}

struct MenuPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.gray.opacity(0.16) : Color.clear)
    }
}

struct GroupCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(C.cardBg)
    }
}

/// 组与组之间的缝：参考图里是「细线 + 8px 灰缝 + 细线」三条，不是只有一条
struct GroupGap: View {
    var body: some View {
        VStack(spacing: 0) {
            HairLine()
            Rectangle().fill(C.pageBg).frame(height: L.groupGap)
            HairLine()
        }
    }
}
