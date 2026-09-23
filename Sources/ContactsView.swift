import SwiftUI

struct ContactSection: Identifiable {
    var id: String { letter }
    let letter: String
    let users: [User]
}

struct ContactsView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var path = NavigationPath()
    @State private var bubble: String?
    @State private var bubbleTask: Task<Void, Never>?
    @State private var plusMenu = false
    @State private var showScan = false
    @FocusState private var searchFocused: Bool
    @ObservedObject private var realtime = Realtime.shared

/* 6 个图标底色统一加深一档（原来偏粉嫩，深色更有质感）：
   琥珀 / 石板灰 / 靛蓝 / 靛蓝 / 松绿 / 松绿
   文案走 L()：切成英文时显示英文，中文时显示中文（所以这里是计算属性，不是常量） */
private var funcs: [(String, String, Color, String)] {
    [
        (Tr("新的朋友"), I.newFriends, Color(hex: 0xF5A23D), "newFriends"),
        (Tr("群聊"), I.groups, Color(hex: 0x22AC8B), "groups"),
        (Tr("仅聊天的朋友"), I.chatOnly, Color(hex: 0x8E8E99), "chatOnly"),
        (Tr("标签"), I.tag, Color(hex: 0x4C93DD), "tags"),
        (Tr("服务号"), I.service, Color(hex: 0x4C93DD), "service"),
        (Tr("企业微信联系人"), I.workMate, Color(hex: 0x35A87E), "work"),
        (Tr("我的企业"), I.myWork, Color(hex: 0x35A87E), "myWork")
    ]
}

    private var filtered: [User] {
        let sorted = app.contacts.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !keyword.isEmpty else { return sorted }
        return sorted.filter { $0.name.contains(keyword) || ($0.username ?? "").contains(keyword) }
    }

    private var sections: [ContactSection] {
        var order: [String] = []
        var map: [String: [User]] = [:]
        for u in filtered {
            let k = pinyinInitial(u.name)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(u)
        }
        return order.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { ContactSection(letter: $0, users: map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavBar(title: C.tabText1) {
                    Button {
                        plusMenu = true
                    } label: {
                        Text("＋")
                            .font(pf(19))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }

                SearchBoxCenter(text: $keyword, externalFocus: $searchFocused)
                    .padding(L.searchPad)
                    .background(C.pageBg)

                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if keyword.isEmpty {
                                    VStack(spacing: 0) {
                                        ForEach(funcs.indices, id: \.self) { i in
                                            funcRow(funcs[i])
                                            if i < funcs.count - 1 {
                                                HairLine(inset: L.ctTextX)
                                            }
                                        }
                                    }
                                    .background(C.cardBg)
                                }

                                ForEach(sections) { section in
                                    // 字母分组头（A/B/C…，参考图里就在左边 x16，一行 28 高）
                                    HStack(spacing: 0) {
                                        Text(section.letter)
                                            .font(pf(L.ctHeadSize))
                                            .foregroundColor(Color(hex: 0x737373))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, 16)
                                    .frame(height: L.ctHeadH)
                                    .background(C.cardBg)
                                    .id("letter-\(section.letter)")

                                    ForEach(section.users.indices, id: \.self) { i in
                                        let user = section.users[i]
                                        VStack(spacing: 0) {
                                            if i > 0 { HairLine(inset: L.ctTextX) }
                                            NavigationLink(value: user) {
                                                contactRow(user)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .background(C.cardBg)
                                        .id(user.id)
                                    }
                                }
                            }
                        }
                        .background(C.cardBg)
                        .refreshable { await app.loadContacts() }

                        if keyword.isEmpty && !sections.isEmpty {
                            ContactIndexBar(
                                available: Set(sections.map { $0.letter }),
                                onPick: { L in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        proxy.scrollTo("letter-\(L)", anchor: .top)
                                    }
                                    showBubble(L)
                                },
                                onSearch: {
                                    keyword = ""
                                    searchFocused = true
                                }
                            )
                            .padding(.trailing, 8)
                            .frame(maxHeight: .infinity, alignment: .center)
                        }

                        if let b = bubble {
                            LetterBubble(letter: b)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .offset(y: -56)
                        }
                    }
                }
            }
            .background(C.pageBg.ignoresSafeArea(edges: .bottom))
            /* 顶部（状态栏那一条）跟页面用同一个底色：深色下导航色比页面底色浅，
               不这样会看到顶上一条明显的浅色带（用户要求「颜色要到顶一致」） */
            .background(C.pageBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: User.self) { user in
                ContactCardView(user: user,
                                onOpenChat: { chat in path.append(chat) },
                                onOpenMoments: { id in path.append("moments:" + id) })
            }
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
            .navigationDestination(for: String.self) { key in
                if key.hasPrefix("moments:") {
                    let uid = String(key.dropFirst(8))
                    MomentsView(target: app.contacts.first { $0.id == uid })
                } else if key == "newFriends" {
                    NewFriendsView()
                } else if key == "addFriend" {
                    AddFriendView()
                } else if key == "newGroup" {
                    GroupCreateView { chat in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { path.append(chat) }
                    }
                } else if key == "myQR" {
                    MyQRView()
                } else if key == "groupList" {
                    GroupListView(onOpenChat: { chat in path.append(chat) })
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        /* 右上角那个「＋」：微信点开是这个菜单（发起群聊 / 添加朋友 / 扫一扫） */
        .confirmationDialog("", isPresented: $plusMenu, titleVisibility: .hidden) {
            Button(Tr("发起群聊")) { path.append("newGroup") }
            Button(Tr("添加朋友")) { path.append("addFriend") }
            Button(Tr("扫一扫")) { showScan = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        .task { await app.loadContacts() }
        // 有人加你 / 改资料 / 上下线 → 通讯录立刻刷新
        .onChange(of: realtime.event) { ev in
            if ev.type == "friend" || ev.type == "presence" || ev.type == "profile" || ev.user != nil {
                Task { await app.loadContacts() }
            }
        }
    }

    private func showBubble(_ letter: String) {
        bubble = letter
        bubbleTask?.cancel()
        bubbleTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { bubble = nil }
        }
    }

    /* ---------------------------------------------------------- 顶部功能行 */

    private func funcRow(_ item: (String, String, Color, String)) -> some View {
        Button {
            switch item.3 {
            case "newFriends": path.append("newFriends")
            case "groups": path.append("groupList")
            case "chatOnly": app.show(Tr("仅聊天的朋友：只有聊天记录、没加好友的人会出现在这里"))
            case "tags": app.show(Tr("标签：还没建过标签"))
            case "service": app.show(Tr("服务号：暂时没有关注的服务号"))
            case "work": app.show(Tr("企业微信联系人：还没绑定微信企业"))
            default: app.show(Tr("我的企业：还没创建企业"))
            }
        } label: {
            HStack(spacing: L.ctGap) {
                FuncIcon(markup: item.1, bg: item.2, size: L.ctIcon)
                Text(item.0)
                    .font(pf(L.ctNameSize))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
                /* 「新的朋友」右边：有待处理的好友申请就显示微信同款红点数字 */
                if item.3 == "newFriends" && app.showDot("newFriends", auto: app.friendRequests > 0) {
                    Text(app.friendRequests > 99 ? "99+" : "\(app.friendRequests)")
                        .font(pf(12.5, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, app.friendRequests > 9 ? 6 : 0)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(C.red))
                        .padding(.trailing, 16)
                }
            }
            .padding(.leading, L.ctPadL)
            .frame(height: L.ctRowH)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }

    private func contactRow(_ user: User) -> some View {
        HStack(spacing: L.ctGap) {
            Avatar(path: user.avatarPath, size: L.ctAvatar, radius: 6)
            Text(user.name)
                .font(pf(L.ctNameSize))
                .foregroundColor(C.label)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, L.ctPadL)
        .frame(height: L.ctRowH)
        .contentShape(Rectangle())
    }

    /* ---------------------------------------------------------- 右侧 A-Z */

    private func indexBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            ForEach(sections) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("letter-\(section.letter)", anchor: .top)
                    }
                } label: {
                    Text(section.letter)
                        .font(pf(L.ctIdxSize))
                        // 字号 / 颜色 / 行距都能在后台「界面文字」里调
                        .foregroundColor(UIConfig.color("ctIdxColor", 0x555555, 0x8E8E93))
                        .frame(width: 22, height: L.ctIdxItemH)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 5.7)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/* ============================================================
   个人名片 —— 照网页版 #cardScreen 一条条量出来的（不是原生那套）：
   头部内边距 27/16/29.5 · 头像 64 圆角 6 · 名字 20 · 三行资料 15/行高 22
   标签列 80 · 行高 22 · 行距 8 · 缩略图 48 圆角 3 · 底部按钮两行各 55.6 字 17
   尺寸都能在服务器 data/ui.json 里调（cd 开头那几个键），改完重开 App 就生效。
   ============================================================ */

struct ContactCardView: View {
    let user: User
    var onOpenChat: (Chat) -> Void
    var onOpenMoments: (String) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var full: User?
    @State private var thumbs: [String] = []
    @State private var hasMoments = false
    @State private var busy = false
    @State private var showMore = false
    @State private var showInfo = false
    @State private var showPhone = false
    @State private var showApply = false
    /* 朋友资料（微信「设置备注和标签」那套） */
    @State private var meta: API.FriendMeta?
    @State private var showRemark = false
    @State private var showPerm = false
    @State private var confirmDelete = false
    /// 好友的「状态」（名片上那一小条，点开看大图）
    @State private var showStatus = false
    /// 机器人（AI 助手 / 腾讯新闻）：点「语音通话」走 AI 通话，不是真人 WebRTC
    @State private var aiCall: Chat?

    private var u: User { full ?? user }
    /// 好友有状态才显示那一小条
    private var statusAlive: Bool {
        !((u.moodIcon ?? "").isEmpty && (u.moodText ?? "").isEmpty)
    }
    /// 名片上显示的名字：有备注用备注，没有用昵称
    private var displayName: String {
        if let r = meta?.remark, !r.trimmingCharacters(in: .whitespaces).isEmpty { return r }
        return u.name
    }
    private var phone: String { (u.phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBot: Bool { u.bot == true }
    /// 顶栏那只小眼睛对应的 AI（管家）—— 名片上也用会动的眼睛当头像
    private var isEyesBot: Bool { (u.username ?? "").lowercased() == "housekeeper" }
    private var relation: String {
        if let r = u.relation, !r.isEmpty { return r }
        return u.id == app.me?.id ? "self" : "none"
    }

    /* 名片这一页的颜色（参考图上取的原值） */
    private var sheetBg: Color { scheme == .dark ? Color(hex: 0x1C1C1E) : .white }
    private var scrollBg: Color { scheme == .dark ? Color(hex: 0x111111) : Color(hex: 0xEDEDED) }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }
    private var gray: Color { scheme == .dark ? Color(hex: 0x8E8E93) : Color(hex: 0x737373) }
    private var link: Color { scheme == .dark ? Color(hex: 0x7D90B8) : Color(hex: 0x576B95) }
    private var lineColor: Color { scheme == .dark ? Color(white: 1, opacity: 0.09) : Color(hex: 0xE5E5E5) }

    /// 新版名片页（畅聊/HarmonyOS 语言）的开关：后台 data/ui.json 里
    /// cardStyle = "new" 才走新版；默认 "old" 就是原来这版，随时能切回来。
    var body: some View {
        if UIConfig.text("cardStyle", "old") == "new" {
            ContactCardNew(name: displayName,
                           idLine: "微信号 " + (u.username ?? ""),
                           avatarPath: u.avatarPath,
                           isEyes: isEyesBot,
                           remark: meta?.remark ?? "",
                           phone: phone,
                           momentCount: thumbs.count,
                           onClose: { dismiss() },
                           onMessage: { openChat() },
                           onMoments: hasMoments ? { onOpenMoments(u.id) } : nil)
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        ZStack {
            VStack(spacing: 0) {
                nav
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        infoCard
                        if hasMoments {
                            Rectangle().fill(scrollBg).frame(height: L.cdCardGap)
                            momentsCard
                        }
                        Rectangle().fill(scrollBg).frame(height: L.cdCardGap)
                        acts
                        Spacer(minLength: 0)
                    }
                }
                .background(scrollBg)
            }
            .background(sheetBg.ignoresSafeArea())

        }
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .confirmationDialog("", isPresented: $showMore, titleVisibility: .hidden) {
            if isBot {
                Button(Tr("发消息")) { openChat() }
                Button(Tr("语音通话")) { startAICall() }
            } else {
                /* 和微信那一列一样：设置备注和标签 / 朋友权限 / 星标 / 黑名单 / 删除 / 投诉 */
                Button(Tr("设置备注和标签")) { showRemark = true }
                Button(Tr("朋友权限")) { showPerm = true }
                Button(meta?.star == true ? Tr("取消星标朋友") : Tr("设为星标朋友")) { toggleStar() }
                Button(meta?.block == true ? Tr("移出黑名单") : Tr("加入黑名单")) { toggleBlock() }
                Button(Tr("删除好友"), role: .destructive) { confirmDelete = true }
                Button(Tr("投诉")) { app.show(Tr("已收到你的投诉，我们会尽快处理")) }
            }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(Tr("删除好友？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) { removeFriend() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .sheet(isPresented: $showRemark) {
            FriendRemarkSheet(user: u, meta: meta) { await load() }
                .environmentObject(app)
        }
        .sheet(isPresented: $showPerm) {
            FriendPermSheet(user: u, meta: meta) { await load() }
                .environmentObject(app)
        }
        /* 好友的「状态」：点名片上那一小条，看大的（微信也是这个动作） */
        .sheet(isPresented: $showStatus) {
            FriendStatusView(user: u)
                .environmentObject(app)
        }
        .confirmationDialog("", isPresented: $showInfo, titleVisibility: .hidden) {
            if isBot {
                Button("昵称：\(u.name)") { }
                Button("账号：\(u.username ?? "—")") { }
                if let b = u.bio, !b.isEmpty { Button("简介：\(b)") { } }
            } else {
                Button("昵称：\(u.name)") { }
                Button("微信号：\(u.username ?? "—")") { }
                Button("地区：\((u.region?.isEmpty == false) ? u.region! : "未知")") { }
            }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog("", isPresented: $showPhone, titleVisibility: .hidden) {
            Button("拨打 \(phone)") { dial() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .task { await load() }
        .fullScreenCover(item: $aiCall) { c in
            AICallView(chat: c).environmentObject(app)
        }
        /* 「添加到通讯录」→ 微信那个申请页（可以写验证消息，默认「我是XXX」） */
        .sheet(isPresented: $showApply) {
            FriendApplySheet(user: u) {
                Task {
                    await app.loadContacts()
                    await load()
                }
            }
            .environmentObject(app)
        }
    }

    /* ---------------------------------------------------------- 导航 */

    private var nav: some View {
        NavBar(title: "", back: { dismiss() }) {
            Button { showMore = true } label: {
                FlexIcon(custom: IconOverrides.custom("nav.more"), size: 22,
                         color: ink, symbol: "ellipsis")
                    .frame(width: 44, height: L.navH)
            }
            .buttonStyle(.plain)
        }
        .background(sheetBg)
    }

    /* ---------------------------------------------------------- 头部资料 */

    private var hero: some View {
        HStack(alignment: .top, spacing: L.cdHeroGap) {
            /* AI 助手（管家）名片上的头像 = 会话页顶栏那只一样的小脸，会眨眼会瞟 */
            if isEyesBot {
                JarvisEyesAvatar(size: L.cdAvatar * 0.84)
                    .frame(width: L.cdAvatar, height: L.cdAvatar)
                    .background(RoundedRectangle(cornerRadius: L.cdAvatarRadius, style: .continuous)
                        .fill(sheetBg))
                    .overlay(RoundedRectangle(cornerRadius: L.cdAvatarRadius, style: .continuous)
                        .stroke(lineColor, lineWidth: 0.6))
            } else {
                Avatar(path: u.avatarPath, size: L.cdAvatar, radius: L.cdAvatarRadius)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    /* 设了备注名就显示备注（微信就是这样），真昵称挪到下面一行 */
                    Text(displayName)
                        .font(pf(L.cdNameSize))
                        .foregroundColor(ink)
                        .lineLimit(1)
                    GenderMark(gender: u.gender, size: L.cdGender)
                    Spacer(minLength: 0)
                }
                .frame(height: L.cdNameRowH)

                /* 好友设了状态：名字下面挂一小条（图标 + 状态名），点开能看大的 */
                if statusAlive { statusChip.padding(.top, 3) }

                cardLine(isBot ? ("账号：" + ((u.username?.isEmpty == false) ? u.username! : "—"))
                               : ("昵称：" + ((u.realNickname?.isEmpty == false) ? u.realNickname! : u.name)))
                    .padding(.top, L.cdLineGap)
                if isBot {
                    cardLine("简介：" + ((u.bio?.isEmpty == false) ? u.bio! : "您的私人助理"))
                } else {
                    cardLine("微信号：" + ((u.username?.isEmpty == false) ? u.username! : "—"))
                    cardLine("地区：" + ((u.region?.isEmpty == false) ? u.region! : "未知"))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, L.cdHeroPadTop)
        .padding(.horizontal, L.cdHeroPadH)
        .padding(.bottom, L.cdHeroPadBottom)
        .background(sheetBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(lineColor).frame(height: 0.5)
        }
    }

    private func cardLine(_ text: String) -> some View {
        Text(text)
            .font(pf(L.cdLineSize))
            .foregroundColor(gray)
            .lineLimit(1)
            .frame(height: L.cdLineH, alignment: .leading)
    }

    /// 好友状态那一小条：图标 + 状态名（点开是大的状态卡）
    private var statusChip: some View {
        let c = MoodColor.clean(u.moodColor)
        let cap = (u.moodCaption ?? "").trimmingCharacters(in: .whitespaces)
        let lab = (u.moodLabel ?? "").trimmingCharacters(in: .whitespaces)
        let text = cap.isEmpty ? (lab.isEmpty ? (u.moodText ?? "") : lab) : cap
        return Button { showStatus = true } label: {
            HStack(spacing: 4) {
                Text(u.moodIcon ?? "🙂")
                Text(text).lineLimit(1)
            }
            .font(pf(12))
            .foregroundColor(c.isEmpty ? gray : .white)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(c.isEmpty ? lineColor : Color(hexString: c)))
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 朋友资料 / 电话 */

    private var infoCard: some View {
        VStack(spacing: 0) {
            Button { showInfo = true } label: {
                HStack(spacing: 0) {
                    Text(Tr("朋友资料"))
                        .font(pf(L.cdLineSize))
                        .foregroundColor(ink)
                        .frame(width: L.cdLabelW, alignment: .leading)
                    Spacer(minLength: 0)
                    cardArrow
                }
                .padding(.horizontal, L.cdPadH)
                .frame(height: L.cdRowH)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !phone.isEmpty {
                Spacer().frame(height: L.cdRowGap)
                Button { showPhone = true } label: {
                    HStack(spacing: 0) {
                        Text(Tr("电话"))
                            .font(pf(L.cdLineSize))
                            .foregroundColor(ink)
                            .frame(width: L.cdLabelW, alignment: .leading)
                        Text(phone)
                            .font(pf(L.cdLineSize))
                            .foregroundColor(link)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, L.cdPadH)
                    .frame(height: L.cdRowH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !isBot && relation == "friend" {
                /* 标签（微信在这一栏显示你给他打的标签） */
                Spacer().frame(height: L.cdRowGap)
                Button { showRemark = true } label: {
                    HStack(spacing: 0) {
                        Text(Tr("标签"))
                            .font(pf(L.cdLineSize))
                            .foregroundColor(ink)
                            .frame(width: L.cdLabelW, alignment: .leading)
                        Text(tagText)
                            .font(pf(L.cdLineSize))
                            .foregroundColor(gray)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        cardArrow
                    }
                    .padding(.horizontal, L.cdPadH)
                    .frame(height: L.cdRowH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                /* 朋友权限（聊天 / 朋友圈 / 黑名单） */
                Spacer().frame(height: L.cdRowGap)
                Button { showPerm = true } label: {
                    HStack(spacing: 0) {
                        Text(Tr("朋友权限"))
                            .font(pf(L.cdLineSize))
                            .foregroundColor(ink)
                            .frame(width: L.cdLabelW, alignment: .leading)
                        Text(permText)
                            .font(pf(L.cdLineSize))
                            .foregroundColor(gray)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        cardArrow
                    }
                    .padding(.horizontal, L.cdPadH)
                    .frame(height: L.cdRowH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                /* 更多信息：共同群聊 / 来源 / 添加时间（微信在「朋友资料」里给这几行） */
                Spacer().frame(height: L.cdRowGap)
                Button { showInfo = true } label: {
                    HStack(spacing: 0) {
                        Text(Tr("更多信息"))
                            .font(pf(L.cdLineSize))
                            .foregroundColor(ink)
                            .frame(width: L.cdLabelW, alignment: .leading)
                        Text(moreText)
                            .font(pf(L.cdLineSize))
                            .foregroundColor(gray)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        cardArrow
                    }
                    .padding(.horizontal, L.cdPadH)
                    .frame(height: L.cdRowH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, L.cdRowsPadV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sheetBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(lineColor).frame(height: 0.5)
        }
    }

    /* ---------------------------------------------------------- 朋友圈那一行 */

    private var momentsCard: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(Tr("朋友圈"))
                .font(pf(L.cdLineSize))
                .foregroundColor(ink)
                .frame(width: L.cdLabelW, height: L.cdLineH, alignment: .leading)

            HStack(spacing: L.cdThumbGap) {
                ForEach(thumbs.prefix(5).indices, id: \.self) { i in
                    /* 缩略图只是让你扫一眼，点了不弹大图 —— 整行都是「进朋友圈」（微信就是这样） */
                    RemoteImage(path: thumbs[i])
                        .frame(width: L.cdThumb, height: L.cdThumb)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
            }

            Spacer(minLength: 0)

            cardArrow
                .padding(.top, max(0, (L.cdThumb - 18) / 2))
        }
        .padding(.top, L.cdThumbRowTop)
        .padding(.horizontal, L.cdPadH)
        .padding(.bottom, L.cdThumbRowBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpenMoments(u.id) }
        .background(sheetBg)
        .overlay(alignment: .top) { Rectangle().fill(lineColor).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(lineColor).frame(height: 0.5) }
    }

    private var cardArrow: some View {
        Path { p in
            p.move(to: CGPoint(x: 1.2, y: 1.2))
            p.addLine(to: CGPoint(x: 7, y: 9))
            p.addLine(to: CGPoint(x: 1.2, y: 16.8))
        }
        .stroke(Color(hex: 0xB2B2B2),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        .frame(width: 9, height: 18)
        .padding(.trailing, 3)
    }

    /* ---------------------------------------------------------- 底部按钮 */

    private struct CardAct {
        var title: String
        var key: String
    }

    private var actList: [CardAct] {
        /* 机器人（AI 助手 / 腾讯新闻）：发消息 + AI 语音通话，别的按钮对它们没意义 */
        if isBot {
            return [CardAct(title: "发消息", key: "msg"),
                    CardAct(title: "语音通话", key: "aicall")]
        }
        switch relation {
        case "friend", "self":
            return [CardAct(title: "发消息", key: "msg"),
                    CardAct(title: "音视频通话", key: "call")]
        case "incoming":
            return [CardAct(title: "同意好友申请", key: "agree"),
                    CardAct(title: "发消息", key: "msg")]
        case "requested":
            return [CardAct(title: "已发送好友申请", key: "pending")]
        default:
            return [CardAct(title: "添加到通讯录", key: "add")]
        }
    }

    private var acts: some View {
        VStack(spacing: 0) {
            ForEach(actList.indices, id: \.self) { i in
                if i > 0 {
                    Rectangle().fill(lineColor).frame(height: 0.5)
                }
                Button { run(actList[i]) } label: {
                    HStack(spacing: L.cdActGap) {
                        if actList[i].key == "msg" {
                            SVGIcon(markup: I.cardChat, size: L.cdIcChatH, color: link)
                                .frame(width: L.cdIcChatW, height: L.cdIcChatH)
                        } else if actList[i].key == "call" {
                            SVGIcon(markup: I.cardVideo, size: L.cdIcVideoH, color: link)
                                .frame(width: L.cdIcVideoW, height: L.cdIcVideoH)
                        }
                        Text(actList[i].title)
                            .font(pf(L.cdActSize))
                            .foregroundColor(link)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: L.cdActH)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .background(sheetBg)
        .overlay(alignment: .top) { Rectangle().fill(lineColor).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(lineColor).frame(height: 0.5) }
    }

    /* ---------------------------------------------------------- 干活 */

    private func run(_ act: CardAct) {
        switch act.key {
        case "msg":
            openChat()
        case "aicall":
            startAICall()
        case "call":
            /* 真人语音通话（WebRTC）。id 就是对方的用户 id，直接呼叫 */
            if CallCenter.shared.phase != .idle {
                app.show(Tr("正在通话中"))
            } else {
                CallCenter.shared.start(peerId: u.id, name: u.nickname ?? u.username ?? "对方",
                                        avatar: u.avatar ?? "", video: false)
            }
        case "add":
            showApply = true
        case "agree":
            busy = true
            Task {
                if let all = try? await API.shared.contactsFull(),
                   let req = all.incoming.first(where: { $0.id == u.id }),
                   let rid = req.requestId {
                    await API.shared.respondFriend(rid, accept: true)
                    app.show(Tr("已同意，现在可以聊天了"))
                    await app.loadContacts()
                    await load()
                } else {
                    app.show(Tr("到「通讯录 → 新的朋友」里同意"))
                }
                busy = false
            }
        default:
            app.show(Tr("已经发过申请了，等对方通过"))
        }
    }

    private func openChat(then after: (() -> Void)? = nil) {
        busy = true
        Task {
            if let chat = try? await API.shared.openDirect(userId: u.id) {
                onOpenChat(chat)
                after?()
            } else {
                app.show(Tr("打不开聊天"))
            }
            busy = false
        }
    }

    private var tagText: String {
        let tags = (meta?.tags ?? []).filter { !$0.isEmpty }
        return tags.isEmpty ? Tr("未设置") : tags.joined(separator: "、")
    }

    private var permText: String {
        if meta?.block == true { return Tr("已加入黑名单") }
        if meta?.noMoments == true { return Tr("不看他的朋友圈") }
        if meta?.hideMyMoments == true { return Tr("不让他看我的朋友圈") }
        return Tr("聊天、朋友圈")
    }

    private var moreText: String {
        var bits: [String] = []
        if let g = u.mutualGroups, g > 0 { bits.append("共同群聊 \(g) 个") }
        if let s = meta?.source, !s.isEmpty { bits.append(s == "me" ? "我添加的" : "他添加的我") }
        bits.append("添加时间 " + (addedText.isEmpty ? "—" : addedText))
        return bits.joined(separator: " · ")
    }

    /// 添加时间：2026-09-22T05:50:45.320Z → 2026年9月22日
    private var addedText: String {
        guard let s = meta?.addedAt, s.count >= 10 else { return "" }
        let y = s.prefix(4), m = s.dropFirst(5).prefix(2), d = s.dropFirst(8).prefix(2)
        return "\(Int(y) ?? 0)年\(Int(m) ?? 0)月\(Int(d) ?? 0)日"
    }

    /// 跟机器人打电话：先找到（或建好）和它的会话，再打开 AI 通话界面
    private func startAICall() {
        busy = true
        Task {
            if let chat = try? await API.shared.openDirect(userId: u.id) {
                aiCall = chat
            } else {
                app.show(Tr("打不开对话"))
            }
            busy = false
        }
    }

    private func dial() {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { return }
        UIApplication.shared.open(url)
    }

    private func load() async {
        if let fresh = try? await API.shared.user(id: user.id) { full = fresh }
        /* 朋友资料：备注名 / 标签 / 星标 / 朋友权限（微信「设置备注和标签」那套） */
        if relation == "friend" || relation == "self" {
            if let m = try? await API.shared.friendMeta(userId: user.id) { meta = m }
        }
        if let list = try? await API.shared.moments(limit: 6, userId: user.id) {
            var images: [String] = []
            for m in list {
                for src in (m.images ?? []) where images.count < 5 {
                    images.append(src)
                }
            }
            thumbs = images
            hasMoments = !list.isEmpty
        }
    }

    /* ---------------------------------------------------------- 朋友资料的几个动作 */

    private func toggleStar() {
        let next = !(meta?.star == true)
        Task {
            await API.shared.setFriendMeta(userId: u.id, star: next)
            await load()
            app.show(next ? Tr("已设为星标朋友") : Tr("已取消星标"))
        }
    }

    private func toggleBlock() {
        let next = !(meta?.block == true)
        Task {
            await API.shared.setFriendMeta(userId: u.id, block: next)
            await load()
            app.show(next ? Tr("已加入黑名单，他发不了消息给你") : Tr("已移出黑名单"))
        }
    }

    private func removeFriend() {
        Task {
            if let err = await API.shared.removeFriend(userId: u.id) {
                app.show(err)
                return
            }
            /* 先退回去、再刷通讯录：反过来的话这个人的数据先从列表里没了，
               这一页的路径值就失效了，dismiss() 会退不动（用户反馈的「删除后不跳转」）。 */
            dismiss()
            await app.loadContacts()
            app.show(Tr("已删除好友"))
        }
    }
}

/* 性别图标：微信那对蓝色小图标（男 ♂ / 女 ♀），照网页版的 SVG 画 */
struct GenderMark: View {
    let gender: String?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if gender == "male" {
                male
            } else if gender == "female" {
                female
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }

    private var blue: Color { Color(hex: 0x10AEFF) }

    private var male: some View {
        ZStack {
            Path { p in
                p.addEllipse(in: CGRect(x: 4, y: 8.8, width: 11.2, height: 11.2))
            }
            .stroke(blue, lineWidth: 1.5)
            Path { p in
                p.move(to: CGPoint(x: 13.6, y: 10.4))
                p.addLine(to: CGPoint(x: 20, y: 4))
                p.move(to: CGPoint(x: 15, y: 4))
                p.addLine(to: CGPoint(x: 20, y: 4))
                p.addLine(to: CGPoint(x: 20, y: 9))
            }
            .stroke(blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }

    private var female: some View {
        ZStack {
            Path { p in
                p.addEllipse(in: CGRect(x: 6.4, y: 3.2, width: 11.2, height: 11.2))
            }
            .stroke(blue, lineWidth: 1.5)
            Path { p in
                p.move(to: CGPoint(x: 12, y: 14.4))
                p.addLine(to: CGPoint(x: 12, y: 21))
                p.move(to: CGPoint(x: 9, y: 18.4))
                p.addLine(to: CGPoint(x: 15, y: 18.4))
            }
            .stroke(blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}
