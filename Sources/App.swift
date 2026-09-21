import SwiftUI
import LocalAuthentication
import UIKit

/* ============================================================ 全局状态 */

@MainActor
final class AppState: ObservableObject {
    @Published var booting = true
    @Published var me: User? {
        didSet {
            rememberLastUser()               // 谁登录（或改了头像）就记住谁，登录页圆圈用它
            /* 一登录就开始「红点兜底」轮询；退出登录就停 */
            if me != nil { startDotWatch() } else { dotTask?.cancel() }
        }
    }
    /// 这台设备上最后登录的人（登录页圆圈显示他的头像 / 名字）
    @Published var lastAvatar: String = UserDefaults.standard.string(forKey: "chris.lastAvatar") ?? ""
    @Published var lastName: String = UserDefaults.standard.string(forKey: "chris.lastName") ?? ""
    /// 登录过、可以一键切换的账号（最多 3 个）
    @Published var accounts: [SavedAccount] = AccountStore.load()
    /// 待处理的好友申请数量（通讯录红点用它）
    @Published var friendRequests = 0
    /// 后台配的红点规则（哪个位置该不该亮）
    @Published var badges: [String: String] = [:]

    /// 这个位置要不要显示红点：auto = 看真实数据；on = 一直亮；off = 不显示
    func showDot(_ key: String, auto: Bool) -> Bool {
        switch badges[key] ?? "auto" {
        case "on": return true
        case "off": return false
        default: return auto
        }
    }

    func loadBadges() async {
        badges = await API.shared.badgeConfig()
    }
    @Published var chats: [Chat] = []
    @Published var contacts: [User] = []
    @Published var moments: [Moment] = []
    /// 朋友圈有没有新的（别人发了就 > 0，「发现」上挂红点）
    @Published var momentsUnread = 0
    /// 服务器上配的默认聊天背景（自己没设时用它，和网页版一致）
    @Published var defaultChatBackground = ""
    @Published var toast: String?
    @Published var loadingChats = false
    @Published var loadError: String?
    /// 服务器上的界面配置变了就 +1，整个界面重建一次（不用重装 App）
    @Published var uiVersion = 0
    /// 点进二级页面（聊天、名片、朋友圈、设置…）时把底部 4 个 tab 收起来。
    /// 用「层数」而不是布尔：从第三层返回第二层时，底栏不能错误地冒出来。
    @Published var tabBarDepth = 0
    var tabBarHidden: Bool { tabBarDepth > 0 }
    /// 外观：auto=跟随系统 · light=浅色 · dark=深色（存在本机，和网页版那个「切换外观」一样）
    @Published var appearance: String = UserDefaults.standard.string(forKey: "chris.appearance") ?? "auto"
    func setAppearance(_ v: String) {
        appearance = v
        UserDefaults.standard.set(v, forKey: "chris.appearance")
    }
    var preferredScheme: ColorScheme? {
        appearance == "light" ? .light : (appearance == "dark" ? .dark : nil)
    }
    private var lastUIConfig = ""
    private var refreshTask: Task<Void, Never>?

    /// 把短时间内的很多次推送合并成一次刷新（比如一下子涌进来几百条消息）
    private func coalesce(_ work: @escaping () async -> Void) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await work()
            self?.refreshTask = nil
        }
    }

    /// 长连接推过来的事情，安排界面去刷新
    func handle(_ ev: PushEvent) {
        // 自己的资料变了（换封面 / 换头像 / 改昵称 / 改状态 / 换聊天背景）
        if let u = ev.user, u.id == me?.id || me == nil {
            me = u
            coalesce { [weak self] in
                await self?.loadChats()
                await self?.loadContacts()
            }
            return
        }
        if let b = ev.balance, var me = me {
            me.balance = b
            self.me = me
        }
        if !ev.announce.isEmpty && ev.type == "announce" {
            show("系统公告：" + ev.announce)
        }
        if let n = ev.momentUnread { momentsUnread = n }      // ready 里带的朋友圈未读数
        if let n = ev.friendRequests {
            /* 长连接重连（手机刚从后台回来）时把「新的朋友」红点补上；
               数字变了就把通讯录重拉一次，行里那个红点数字也跟着新 */
            let changed = n != friendRequests
            friendRequests = n
            if changed { coalesce { [weak self] in await self?.loadContacts() } }
        }
        switch ev.type {
        case "message", "chat":
            coalesce { [weak self] in await self?.loadChats() }
        case "transfer":
            /* 转账状态变了（对方收款 / 24 小时自动退回）：
               付款方这边弹一句提示，会话列表跟着刷一遍 */
            if ev.transferStatus == "received", ev.transferFromId == me?.id,
               let a = ev.transferAmount {
                show("对方已收款 ¥" + money(a))
            }
            coalesce { [weak self] in await self?.loadChats() }
        case "moment":
            momentsUnread = max(1, momentsUnread)          // 有人发朋友圈：先点红点，再拉一次
            coalesce { [weak self] in await self?.loadMoments() }
        case "friend", "presence", "profile":
            coalesce { [weak self] in await self?.loadContacts() }
        default:
            break
        }
    }

    private var toastTask: Task<Void, Never>?

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func boot() async {
        await refreshUI(force: true)
        await loadBadges()
        if API.shared.token.isEmpty {
            booting = false
            return
        }
        do {
            let s = try await API.shared.session()
            if s.ok, let user = s.user {
                me = user
                rememberLastUser()      // 登录页那个圆圈用「最后登录的人」的头像
                await refreshAll()
                Realtime.shared.start()
            } else {
                API.shared.clearToken()
            }
        } catch {
            /* 连不上服务器（电脑没开 / 不在同一个 Wi-Fi）：不要把人踢回登录页，
               先用本地缓存的资料进 App，等服务器回来了再自动同步。 */
            if let cached = AppState.cachedUser() { me = cached }
        }
        booting = false
    }

    /// 本地缓存的当前用户（离线进 App 用）
    static func cachedUser() -> User? {
        guard let s = UserDefaults.standard.string(forKey: "chris.lastUserJSON"),
              let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(User.self, from: d)
    }

    /// 拉服务器上的 data/ui.json：改了数字/颜色，App 重开或回到前台就生效
    func refreshUI(force: Bool = false) async {
        let cfg = await API.shared.uiConfig()
        let stamp = String(describing: cfg.ui.sorted { $0.key < $1.key })
            + "|icons:" + String(describing: cfg.icons.sorted { $0.key < $1.key })
        if force || stamp != lastUIConfig {
            lastUIConfig = stamp
            UIConfig.apply(cfg.ui)
            IconOverrides.map = cfg.icons
            uiVersion += 1
        }
        // 服务器上配的默认聊天背景（自己没设时用）
        if let b = await API.shared.branding() {
            defaultChatBackground = b.chatBackground ?? ""
        }
    }

    func login(username: String, password: String) async throws {
        me = try await API.shared.login(username: username, password: password)
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
    }

    func login(phone: String, code: String) async throws {
        me = try await API.shared.loginPhone(phone: phone, code: code)
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
    }

    /// 身份证自助解封成功后走这里：等同于登录成功（解封接口会把登录态一起发下来）
    func finishLogin(_ user: User) async {
        me = user
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
    }

    /* ---------------- 红点兜底 ----------------
       推送偶尔会漏（手机在后台、长连接正在重连、被系统掐了）。
       所以除了推送，还有两层：
       ① 长连接重连时服务器在 ready 里带上 friendRequests；
       ② 回到前台 + 每 25 秒轻量问一次 /api/badge-counts。
       这样「有人加你好友」最迟 25 秒内通讯录一定出红点。 */
    private var dotTask: Task<Void, Never>?
    func startDotWatch() {
        dotTask?.cancel()
        dotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshDotCounts()
            }
        }
    }
    func refreshDotCounts() async {
        guard me != nil, let d = await API.shared.badgeCounts() else { return }
        if d.friendRequests != friendRequests {
            friendRequests = d.friendRequests
            await loadContacts()          // 让「新的朋友」行里的数字也跟上
        }
        if d.momentUnread != momentsUnread { momentsUnread = d.momentUnread }
    }

    /// 记住这台设备上最后登录的人（登录页的圆圈用它显示头像）
    func rememberLastUser() {
        guard let me = me else { return }
        lastAvatar = me.avatar ?? ""
        lastName = me.nickname ?? me.username ?? ""
        UserDefaults.standard.set(lastAvatar, forKey: "chris.lastAvatar")
        UserDefaults.standard.set(lastName, forKey: "chris.lastName")
        /* 缓存一份完整资料：连不上服务器时用它先进 App，不把人踢回登录页 */
        if let d = try? JSONEncoder().encode(me), let s = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: "chris.lastUserJSON")
        }
        /* 记进「登录过的账号」列表：最多 3 个，登录页可以左右滑 */
        if let u = me.username, !u.isEmpty, !API.shared.token.isEmpty {
            accounts = AccountStore.upsert(username: u,
                                           nickname: me.nickname ?? u,
                                           avatar: me.avatar ?? "",
                                           token: API.shared.token)
        }
    }

    func refreshAll() async {
        await loadChats()
        await loadContacts()
        await loadMoments()
    }

    func loadChats() async {
        loadingChats = true
        defer { loadingChats = false }
        do {
            chats = try await API.shared.chats()
            loadError = nil
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "加载失败"
        }
    }

    func loadContacts() async {
        if let r = try? await API.shared.contactsFull() {
            contacts = r.friends
            friendRequests = r.incoming.count        // 别人加你好友 → 通讯录亮红点
        }
    }

    func loadMoments() async {
        if let feed = try? await API.shared.momentsFeed() {
            moments = feed.moments
            momentsUnread = feed.unread
        }
    }

    func logout() async {
        await API.shared.logout()
        Realtime.shared.stop()
        me = nil
        chats = []
        contacts = []
        moments = []
    }

    /// 一键登录：用这台设备上保存的登录令牌直接进去（登录页点头像就用这个）
    func quickLogin(token: String? = nil) async -> Bool {
        if let t = token, !t.isEmpty { API.shared.setToken(t) }
        guard !API.shared.token.isEmpty else { return false }
        guard let s = try? await API.shared.session(), s.ok, let user = s.user else {
            API.shared.clearToken()      // 令牌过期/失效：清掉，让用户重新输密码
            return false
        }
        me = user
        rememberLastUser()
        await refreshAll()
        Realtime.shared.start()
        return true
    }

    func contact(for id: String) -> User? {
        if me?.id == id { return me }
        return contacts.first { $0.id == id }
    }
}

/* ============================================================ 入口 */

@main
struct CHRISApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(app.preferredScheme)   // 跟随系统 / 强制浅色 / 强制深色
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var realtime = Realtime.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if app.booting {
                    LaunchView()
                } else if app.me == nil {
                    LoginView()
                } else {
                    MainTabView()
                }

                if let text = app.toast {
                    VStack {
                        Spacer()
                        Text(text)
                            .font(pf(14))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.78)))
                            .padding(.bottom, L.tabH + L.safeBottom + 40)
                    }
                    .allowsHitTesting(false)
                }
            }
            .id(app.uiVersion)
            // 根视图也铺一层底色：万一哪个页面没铺满，顶上也不会露出系统窗口的白色
            .background(C.pageBg.ignoresSafeArea())
            .onAppear { L.width = geo.size.width }
            .onChange(of: geo.size.width) { w in L.width = w }
        }
        .task { await app.boot() }
        .onChange(of: scenePhase) { phase in
            if phase == .active && app.me != nil {
                Task {
                    await app.refreshUI()
                    await app.loadChats()
                    await app.loadContacts()      // 回到前台也要重拉好友申请，不然通讯录红点不亮
                    await app.refreshDotCounts()
                    Realtime.shared.start()
                }
            }
        }
        .onChange(of: realtime.event) { ev in
            /* 后台换了图标/界面配置：服务器会推一条 type=ui，收到就立刻重拉，
               这样不用划掉 App 重开也能看到新图标。 */
            if ev.type == "ui" {
                Task { await app.refreshUI(force: true) }
                return
            }
            app.handle(ev)
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 14) {
                if let img = AppIconImage.image {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 66, height: 66)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                Text("正在连接…").font(pf(13)).foregroundColor(C.loginGray)
            }
        }
    }
}

/* ============================================================ 登录页 */

/* 旧的微信风登录页（保留但不再使用；新的是下面那个简洁版 LoginView） */
struct LoginViewOld: View {
    @EnvironmentObject var app: AppState
    @FocusState private var focus: Field?

    private enum Field: Hashable { case phone, code, user, pass }

    @State private var usePassword = false
    @State private var country = "中国大陆 (+86)"
    @State private var phone = ""
    @State private var code = ""
    @State private var username = ""
    @State private var password = ""
    @State private var syncHistory = true
    @State private var busy = false
    @State private var error: String?
    @State private var codeSent = false
    @State private var showServer = false
    @State private var server = API.shared.server

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                nav
                ScrollView {
                    VStack(spacing: 0) {
                        panel
                        if let error = error {
                            Text(error)
                                .font(pf(13.5))
                                .foregroundColor(C.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 12)
                        }
                        if !usePassword {
                            Text("仅上述手机号用于登录验证")
                                .font(pf(13.5))
                                .foregroundColor(C.loginGray)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 12.6)
                        }
                        Button {
                            usePassword.toggle()
                            error = nil
                            focus = nil
                        } label: {
                            Text(usePassword ? "用手机号登录" : "其他方式登录")
                                .font(pf(16))
                                .foregroundColor(C.loginLink)
                        }
                        .padding(.top, 18.5)
                        Spacer(minLength: 40)
                    }
                    .padding(.top, 25.2)
                    .frame(minHeight: 700, alignment: .top)
                }
                foot
            }
        }
        .sheet(isPresented: $showServer) {
            ServerSheet(server: $server) {
                API.shared.setServer(server)
                server = API.shared.server
                showServer = false
                app.show("服务器已改成 \(server)")
            }
        }
    }

    private var nav: some View {
        ZStack {
            Text(usePassword ? "账号密码登录" : "手机号登录")
                .font(pf(18, .semibold))
                .foregroundColor(C.loginText)
            HStack {
                Button {
                    focus = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(pf(22, .regular))
                        .foregroundColor(C.loginText)
                        .frame(width: 44, height: 52)
                }
                Spacer()
            }
        }
        .frame(height: 52)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            if !usePassword {
                loginRow(label: "国家/地区") {
                    Spacer()
                    Text(country).font(pf(16)).foregroundColor(C.loginGray)
                    Chevron(size: 9, line: 1.6, color: C.loginGray)
                }
                HairLine(color: C.navLine)
                loginRow(label: "手机号") {
                    Text("+86").font(pf(17)).foregroundColor(C.loginText)
                    TextField("", text: $phone)
                        .focused($focus, equals: .phone)
                        .keyboardType(.numberPad)
                        .font(pf(17.5))
                        .foregroundColor(C.loginText)
                        .frame(height: 46)
                }
                HairLine(color: C.navLine)
                loginRow(label: "验证码") {
                    TextField("", text: $code)
                        .focused($focus, equals: .code)
                        .keyboardType(.numberPad)
                        .font(pf(17.5))
                        .foregroundColor(C.loginText)
                        .frame(height: 46)
                    Button {
                        sendCode()
                    } label: {
                        Text(codeSent ? "已发送" : "获取验证码")
                            .font(pf(15))
                            .foregroundColor(codeSent ? C.loginGray : C.loginLink)
                            .padding(.vertical, 6)
                    }
                }
            } else {
                loginRow(label: "账号") {
                    TextField("", text: $username)
                        .focused($focus, equals: .user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(pf(17.5))
                        .foregroundColor(C.loginText)
                        .frame(height: 46)
                }
                HairLine(color: C.navLine)
                loginRow(label: "密码") {
                    SecureField("", text: $password)
                        .focused($focus, equals: .pass)
                        .font(pf(17.5))
                        .foregroundColor(C.loginText)
                        .frame(height: 46)
                }
            }
        }
        .background(C.loginCard)
    }

    private func loginRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10.9) {
            Text(label)
                .font(pf(17))
                .foregroundColor(C.loginText)
                .frame(width: 74, alignment: .leading)
            content()
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var foot: some View {
        VStack(spacing: 0) {
            Button {
                syncHistory.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: syncHistory ? "checkmark.circle.fill" : "circle")
                        .font(pf(15))
                        .foregroundColor(syncHistory ? C.loginGreen : C.loginGray)
                    Text("登录后同步最近的聊天记录")
                        .font(pf(13.5))
                        .foregroundColor(C.loginGray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .padding(.bottom, 12.6)

            Button {
                submit()
            } label: {
                Text(busy ? "登录中…" : "同意并继续")
                    .font(pf(17, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8).fill(busy ? C.loginGreen.opacity(0.6) : C.loginGreen))
            }
            .disabled(busy)

            Button {
                showServer = true
            } label: {
                Text("服务器 \(server)（长按可改）")
                    .font(pf(11))
                    .foregroundColor(C.loginGray.opacity(0.7))
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, max(16, L.safeBottom))
        .background(Color(.systemBackground))
    }

    private func sendCode() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.count < 5 { error = "请填写手机号"; return }
        error = nil
        Task {
            do {
                let dev = try await API.shared.phoneCode(phone: p)
                codeSent = true
                if let c = dev { code = c; app.show("验证码：\(c)") } else { app.show("验证码已发送") }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "发送失败"
            }
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            do {
                if usePassword {
                    let u = username.trimmingCharacters(in: .whitespaces)
                    if u.isEmpty || password.isEmpty { throw APIError.message("请填写账号和密码") }
                    try await app.login(username: u, password: password)
                } else {
                    let p = phone.trimmingCharacters(in: .whitespaces)
                    if p.isEmpty || code.isEmpty { throw APIError.message("请填写手机号和验证码") }
                    try await app.login(phone: p, code: code)
                }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "登录失败"
            }
            busy = false
        }
    }
}

struct ServerSheet: View {
    @Binding var server: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("电脑的局域网地址（IP:端口）")) {
                    TextField("192.168.2.7:5443（加密）", text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.numbersAndPunctuation)
                }
                Section(footer: Text("电脑上运行 CHRIS聊天，手机连同一个 Wi-Fi，用电脑的 IP 填这里。")) {
                    EmptyView()
                }
            }
            .navigationTitle("服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("保存") { onSave() } }
            }
        }
    }
}

/* ============================================================ 简洁版登录 / 注册页
   和网页版一致的极简风格：图标 + 名称 → 登录/注册两个 Tab → 一张卡片 → 一个绿色按钮。
   注册带图形验证码（服务器给的是 SVG，用 CaptchaView 把点阵字画出来）。 */

struct CaptchaView: View {
    let svg: String
    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 160.0, sy = size.height / 64.0
            let groups = CaptchaView.parseGroups(svg)
            for g in groups {
                let color = Color(hexString: g.fill)
                for r in g.rects {
                    var p = Path(roundedRect: CGRect(x: r.x * sx, y: r.y * sy,
                                                     width: r.w * sx, height: r.h * sy),
                                 cornerRadius: r.rx * min(sx, sy))
                    if g.angle != 0 {
                        var t = CGAffineTransform(translationX: g.cx * sx, y: g.cy * sy)
                        t = t.rotated(by: g.angle * .pi / 180)
                        t = t.translatedBy(x: -g.cx * sx, y: -g.cy * sy)
                        p = p.applying(t)
                    }
                    ctx.fill(p, with: .color(color))
                }
            }
        }
        .background(Color.white)
    }

    struct Rect { var x, y, w, h, rx: CGFloat }
    struct Group { var fill: String; var angle: CGFloat; var cx, cy: CGFloat; var rects: [Rect] }

    static func parseGroups(_ svg: String) -> [Group] {
        var out: [Group] = []
        let ns = svg as NSString
        guard let gRe = try? NSRegularExpression(pattern: "<g\\s+fill=\"([^\"]+)\"([^>]*)>([\\s\\S]*?)</g>") else { return out }
        let rRe = try? NSRegularExpression(pattern: "<rect\\s+x=\"([-\\d.]+)\"\\s+y=\"([-\\d.]+)\"\\s+width=\"([-\\d.]+)\"\\s+height=\"([-\\d.]+)\"(?:\\s+rx=\"([-\\d.]+)\")?")
        let tRe = try? NSRegularExpression(pattern: "rotate\\(\\s*([-\\d.]+)\\s+([-\\d.]+)\\s+([-\\d.]+)\\s*\\)")
        gRe.enumerateMatches(in: svg, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let fill = ns.substring(with: m.range(at: 1))
            let attrs = ns.substring(with: m.range(at: 2))
            let body = ns.substring(with: m.range(at: 3))
            var angle: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
            if let tRe = tRe, let tm = tRe.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) {
                let a = attrs as NSString
                angle = CGFloat(Double(a.substring(with: tm.range(at: 1))) ?? 0)
                cx = CGFloat(Double(a.substring(with: tm.range(at: 2))) ?? 0)
                cy = CGFloat(Double(a.substring(with: tm.range(at: 3))) ?? 0)
            }
            var rects: [Rect] = []
            let bs = body as NSString
            rRe?.enumerateMatches(in: body, range: NSRange(location: 0, length: bs.length)) { rm, _, _ in
                guard let rm = rm else { return }
                func num(_ i: Int, _ d: Double) -> CGFloat { CGFloat(Double(bs.substring(with: rm.range(at: i))) ?? d) }
                rects.append(Rect(x: num(1, 0), y: num(2, 0), w: num(3, 0), h: num(4, 0), rx: num(5, 0)))
            }
            if !rects.isEmpty { out.append(Group(fill: fill, angle: angle, cx: cx, cy: cy, rects: rects)) }
        }
        return out
    }
}

/* ============================================================ 登录页（按设计稿）
   ← 返回 + 标题「账号登录」
   图标 + App 名 → 欢迎语 →【微信登录】大按钮 → 其他登录选项 → 协议 → 版本号 */

/* ============================================================
   登录页（按你给的 WechatLoginIOSView 代码原样实现）
   说明：你代码里有两处 iOS 上不能用，我按同款外观等价替换了：
     · .toggleStyle(.checkbox) 是 macOS 专有 → iOS 用同外观的自定义方框勾选
     · Text.rich(TextSpan{...}) 不是 SwiftUI 的类型 → 用 Text 拼接 / Markdown 链接，样式一致
   「微信登录」按钮：没有微信 SDK，接到自建的「设备确认登录」（点它出 6 位数字，在已登录设备上确认）
   ============================================================ */

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var focus: Field?

    private enum Field: Hashable { case phone, code, user, pass, regUser, regNick, regPass, regCap }

    @State private var isAgree = false
    @State private var showPair = false
    @State private var showTerms = false
    @State private var termsKind = 0
    @State private var sheet: Way? = nil
    @State private var appName = "我的App"
    @State private var logoPath: String?
    /// 登录页背景图（后台配的）—— 用 @State 才能刷新生效
    @State private var bgImage = ""
    /// 后台配置一拉到就 +1，让配色/背景跟着重绘一次
    @State private var themeTick = 0
    /// 一键登录进行中
    @State private var quickBusy = false
    /// 出错提示（比如一键登录的登录态过期了）
    @State private var error: String?
    /// 当前滑到第几个账号
    @State private var avatarIndex = 0

    enum Way: String, Identifiable { case phone, password; var id: String { rawValue } }

    var body: some View {
        ZStack {
            loginBackground
            /* 这里原来套的是 NavigationStack —— 它会自带一层不透明的系统背景，
               把后面的登录页背景图整个盖掉，所以后台换了背景图手机上永远看不到。
               换成 App 自己的 NavBar（透明背景），背景图就能透出来了。 */
            VStack(spacing: 0) {
                NavBar(title: "账号登录")
                    // 头像区：登录过的账号最多 3 个，可以左右滑；点一下就用那个账号一键登录
                    // （放在滚动区外面，横向滑动才不会被上下滚动抢走手势）
                    avatarPager
                        .padding(.top, 34)
                        .padding(.horizontal, 20)
                    ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                    Text(appName)
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 16)
                    Text("登录后同步最近的聊天记录")
                        .font(.system(size: 13))
                        .foregroundColor(LoginTheme.sub ?? .secondary)
                        .padding(.top, 18)

                    Spacer(minLength: 44)

                    // 主按钮：没勾协议点不动，就算点到也会给提示
                    Button {
                        guard requireAgree() else { return }
                        loginWithWechat()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "message.fill")
                                .resizable()
                                .frame(width: 22, height: 22)
                            Text("微信登录")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(isAgree ? LoginTheme.accent : LoginTheme.disabledAccent)
                        .cornerRadius(14)
                    }
                    .disabled(!isAgree)

                    /* 其他三种登录方式并成一行，不再堆两行：
                       手机号登录 · 账号密码登录 · 人脸（没勾协议一样进不去） */
                    HStack(spacing: 9) {
                        Button("手机号登录") {
                            guard requireAgree() else { return }
                            sheet = .phone
                        }
                        Text("·").foregroundColor(LoginTheme.disabledGray)
                        Button("账号密码登录") {
                            guard requireAgree() else { return }
                            sheet = .password
                        }
                        Text("·").foregroundColor(LoginTheme.disabledGray)
                        Button {
                            guard requireAgree() else { return }
                            faceLogin()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "faceid")
                                Text("人脸")
                            }
                        }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(LoginTheme.accent)
                    .padding(.top, 20)

                    if let e = error {
                        Text(e)
                            .font(.system(size: 13))
                            .foregroundColor(C.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                    }

                    Spacer(minLength: 26)

                    // 协议勾选
                    HStack(alignment: .top, spacing: 8) {
                        Button { isAgree.toggle() } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isAgree ? LoginTheme.accent : LoginTheme.disabledGray, lineWidth: 1.4)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(isAgree ? LoginTheme.accent : Color.clear))
                                .frame(width: 16, height: 16)
                                .overlay(isAgree
                                         ? Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                         : nil)
                        }
                        .padding(.top, 1)

                        Text(.init("我已阅读并同意 [《用户协议》](terms://0) 和 [《隐私政策》](terms://1)"))
                            .font(.system(size: 12))
                            .tint(LoginTheme.accent2)
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "terms" {
                                    termsKind = Int(url.host ?? "0") ?? 0
                                    showTerms = true
                                }
                                return .handled
                            })
                    }

                    /* 安全提示：和网页版登录页保持一致 */
                    HStack(spacing: 5) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text("全程 HTTPS 加密传输，密码只以加密哈希保存")
                            .font(.system(size: 11.5))
                    }
                    .foregroundColor(LoginTheme.sub ?? Color(hexString: "#8A8F99"))
                    .padding(.top, 14)

                    Spacer()

                    Text("V1.0.0")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hexString: "#AEAEB2"))
                        .padding(.top, 60)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: UIScreen.main.bounds.height - 170, alignment: .top)
            }
            .background(Color.clear)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showPair) { PairSheet() }
        .sheet(isPresented: $showTerms) { TermsSheet(kind: termsKind) }
        .sheet(item: $sheet) { w in
            if w == .phone { PhoneLoginView() } else { AccountLoginSheet(mode: w) }
        }
        .onAppear {
            Task {
                if let b = await API.shared.branding() {
                    LoginTheme.apply(b)
                    if let n = b.login?.appName ?? b.appName, !n.isEmpty { appName = n }
                    if let lg = b.login?.logo ?? b.logo, !lg.isEmpty { logoPath = lg }
                    bgImage = b.login?.bgImage ?? ""      // 背景图（用状态存，才能刷新生效）
                    themeTick += 1
                }
            }
        }
        }   // 关掉最外层 ZStack
    }

    /// 登录页背景：后台配了背景图就铺满整屏（压一层很淡的底色保证文字看得清），否则用系统背景
    /// 头像区：最多 3 个登录过的账号，左右滑动切换；点头像 = 用那个账号一键登录
    private var avatarPager: some View {
        VStack(spacing: 8) {
            if app.accounts.isEmpty {
                // 这台设备还没登录过：显示后台 logo / App 图标 / 灰圆
                Group {
                    if let p = logoPath {
                        RemoteImage(path: p, icon: "message.fill", mode: .fill)
                    } else if let img = AppIconImage.image {
                        Image(uiImage: img).resizable()
                    } else {
                        Circle().foregroundColor(.gray.opacity(0.2))
                    }
                }
                .frame(width: 80, height: 80)
                .clipShape(Circle())
            } else {
                HStack(spacing: 6) {
                    if app.accounts.count > 1 {
                        Button { withAnimation { avatarIndex = max(0, avatarIndex - 1) } } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(avatarIndex > 0 ? LoginTheme.accent : LoginTheme.disabledGray)
                                .frame(width: 30, height: 60)
                        }
                        .disabled(avatarIndex <= 0)
                    }
                    TabView(selection: $avatarIndex) {
                    ForEach(Array(app.accounts.enumerated()), id: \.element.id) { idx, acc in
                        Group {
                            if !acc.avatar.isEmpty {
                                RemoteImage(path: acc.avatar, icon: "person.fill", mode: .fill)
                            } else {
                                Circle().fill(LoginTheme.accent.opacity(0.25))
                                    .overlay(Text(String(acc.nickname.prefix(1)))
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundColor(LoginTheme.accent))
                            }
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .onTapGesture { quickLogin(account: acc) }
                        .tag(idx)
                    }
                }
                    .tabViewStyle(.page(indexDisplayMode: app.accounts.count > 1 ? .always : .never))
                    .frame(height: 108)
                    .frame(maxWidth: app.accounts.count > 1 ? .infinity : 96)
                    if app.accounts.count > 1 {
                        Button { withAnimation { avatarIndex = min(app.accounts.count - 1, avatarIndex + 1) } } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(avatarIndex < app.accounts.count - 1 ? LoginTheme.accent : LoginTheme.disabledGray)
                                .frame(width: 30, height: 60)
                        }
                        .disabled(avatarIndex >= app.accounts.count - 1)
                    }
                }

                if app.accounts.count > 1 {
                    Text("← 左右滑动切换账号，点头像直接登录 →")
                        .font(.system(size: 11))
                        .foregroundColor(LoginTheme.sub ?? .secondary)
                } else {
                    Text(quickBusy ? "正在登录…" : "点一下头像，快捷登录")
                        .font(.system(size: 12))
                        .foregroundColor(LoginTheme.accent)
                }
                Text(app.accounts[min(avatarIndex, app.accounts.count - 1)].nickname)
                    .font(.system(size: 13))
                    .foregroundColor(LoginTheme.sub ?? .secondary)
            }
        }
        .onChange(of: app.accounts.count) { _ in clampAvatarIndex() }
    }

    private func clampAvatarIndex() {
        let maxIdx = max(0, app.accounts.count - 1)
        if avatarIndex > maxIdx { avatarIndex = maxIdx }
    }

    private var loginBackground: some View {
        ZStack {
            if !bgImage.isEmpty {
                RemoteImage(path: bgImage, icon: "photo", mode: .fill)
                    .ignoresSafeArea()
                Color(.systemBackground).opacity(0.30).ignoresSafeArea()
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .id(themeTick)
    }

    func loginWithWechat() {
        // 按最新要求：点「微信登录」直接进入账号密码登录页
        sheet = .password
    }

    /// 没勾协议一律不让登：主按钮、手机号登录、账号密码登录、人脸、点头像快捷登录都走这里
    @discardableResult
    private func requireAgree() -> Bool {
        if isAgree { return true }
        error = "请先勾选并同意《用户协议》和《隐私政策》"
        return false
    }

    /// 这台设备上有没有可以「一键登录」的登录态
    private var hasSavedLogin: Bool {
        !API.shared.token.isEmpty || !app.lastAvatar.isEmpty
    }

    /// 点头像一键登录：用保存的令牌直接进去；过期了就提示重新输密码
    /// 人脸识别登录：系统 Face ID 过了以后，用「当前选中的那个账号」的登录态进去
    private func faceLogin() {
        guard !quickBusy else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            error = "这台设备还不能用人脸识别（要先在密码登录里登过一次，且手机支持 Face ID）"
            return
        }
        let list = app.accounts
        guard !list.isEmpty else {
            error = "先用密码或手机号登录一次，之后就能刷脸进"
            return
        }
        let acc = list[min(avatarIndex, list.count - 1)]
        quickBusy = true
        error = nil
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                           localizedReason: "刷脸登录 CHRIS") { ok, _ in
            DispatchQueue.main.async {
                quickBusy = false
                if ok { quickLogin(account: acc) }
                else { error = "人脸没认出来，或者你取消了" }
            }
        }
    }

    private func quickLogin(account: SavedAccount? = nil) {
        guard requireAgree() else { return }
        guard !quickBusy else { return }
        quickBusy = true
        error = nil
        Task {
            let saved = account.map { AccountStore.token(for: $0.username) } ?? ""
            let ok = await app.quickLogin(token: saved.isEmpty ? nil : saved)
            quickBusy = false
            if !ok { error = "登录状态已过期，请重新输入密码登录" }
        }
    }
}

/* ---------- 手机号登录 / 账号密码登录（点开后的表单页） ---------- */
struct AccountLoginSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field: Hashable { case phone, code, user, pass }

    var mode: LoginView.Way

    @State private var phone = ""
    @State private var code = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showReg = false
    @State private var showUnban = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if mode == .phone {
                        row { TextField("手机号", text: $phone).keyboardType(.numberPad).focused($focus, equals: .phone) }
                        HairLine(color: C.navLine)
                        row {
                            TextField("验证码", text: $code).keyboardType(.numberPad).focused($focus, equals: .code)
                            Button("获取验证码") { sendCode() }
                                .font(.system(size: 14)).foregroundColor(C.loginGreen)
                        }
                    } else {
                        row { TextField("微信号 / 用户名", text: $username).focused($focus, equals: .user)
                            .textInputAutocapitalization(.never).autocorrectionDisabled(true) }
                        HairLine(color: C.navLine)
                        row { SecureField("密码", text: $password).focused($focus, equals: .pass) }
                    }
                    if let e = error {
                        Text(e).font(.system(size: 13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                    // 账号被禁用：直接给一个自助解封入口（填身份证号，服务器校验合法就解开）
                    if isBanned {
                        Button {
                            showUnban = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.text.rectangle")
                                Text("账号被禁用了？用身份证自助解封")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(LoginTheme.accent2)
                            .cornerRadius(14)
                        }
                        .padding(.top, 12)
                    }
                    Button { submit() } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                            Text(busy ? "请稍候…" : "登 录").font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(LoginTheme.accent)
                        .cornerRadius(16)
                    }
                    .disabled(busy)
                    .padding(.top, 20)

                    if mode == .password {
                        Button("还没有账号？去注册") { showReg = true }
                            .font(.system(size: 13)).foregroundColor(LoginTheme.accent2)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(mode == .phone ? "手机号登录" : "账号密码登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
            }
            .sheet(isPresented: $showReg) { RegisterSheet() }
            .sheet(isPresented: $showUnban) {
                UnbanSheet(preUser: username, prePass: password)
            }
        }
    }

    private var isBanned: Bool {
        let e = error ?? ""
        return e.contains("禁用") || e.contains("封禁")
    }

    private func row<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .font(.system(size: 15))
            .frame(height: 54).padding(.horizontal, 14)
            .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
    }

    private func sendCode() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.count < 5 { error = "请填写手机号"; return }
        error = nil
        Task {
            do {
                if let dev = try await API.shared.phoneCode(phone: p) {
                    code = dev; app.show("验证码：\(dev)")
                } else { app.show("验证码已发送") }
            } catch { self.error = (error as? APIError)?.errorDescription ?? "发送失败" }
        }
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                if mode == .phone {
                    let p = phone.trimmingCharacters(in: .whitespaces)
                    if p.isEmpty || code.isEmpty { throw APIError.message("请填写手机号和验证码") }
                    try await app.login(phone: p, code: code)
                } else {
                    let u = username.trimmingCharacters(in: .whitespaces)
                    if u.isEmpty || password.isEmpty { throw APIError.message("请填写账号和密码") }
                    try await app.login(username: u, password: password)
                }
                dismiss()
            } catch { self.error = (error as? APIError)?.errorDescription ?? "登录失败" }
            busy = false
        }
    }
}

/* ---------- 注册（图形验证码用 CaptchaView 画） ---------- */
/* ---------- 身份证自助解封 ---------- */
struct UnbanSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let preUser: String
    let prePass: String

    @State private var username = ""
    @State private var password = ""
    @State private var idCard = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("账号被管理员禁用后，可以在这里用身份证号自己解开。号码要真实合法（18 位，最后一位可能是 X）。同一张身份证只能绑定一个账号，解封动作会写进后台审计日志。")
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 14)

                    field { TextField("被封的账号（用户名 / 手机号）", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled(true) }
                    HairLine(color: C.navLine)
                    field { SecureField("该账号的密码", text: $password) }
                    HairLine(color: C.navLine)
                    field { TextField("身份证号（18 位）", text: $idCard)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled(true) }

                    if let e = error {
                        Text(e).font(.system(size: 13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                    }

                    Button { submit() } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                            Text(busy ? "正在核验…" : "提交并解封").font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(LoginTheme.accent)
                        .cornerRadius(16)
                    }
                    .disabled(busy)
                    .padding(.top, 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("身份证自助解封")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
            }
        }
        .onAppear {
            if username.isEmpty { username = preUser }
            if password.isEmpty { password = prePass }
        }
    }

    private func field<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 8) { c() }
            .font(.system(size: 15))
            .frame(height: 54).padding(.horizontal, 14)
            .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
    }

    private func submit() {
        let u = username.trimmingCharacters(in: .whitespaces)
        let idc = idCard.trimmingCharacters(in: .whitespaces).uppercased()
        if u.isEmpty { error = "请填写被封的账号"; return }
        if password.isEmpty { error = "请填写账号密码"; return }
        if idc.count != 18 { error = "身份证要 18 位，最后一位可以是 X"; return }
        busy = true; error = nil
        Task {
            do {
                let user = try await API.shared.unban(username: u, password: password, idCard: idc)
                await app.finishLogin(user)
                app.show("解封成功，已登录")
                dismiss()
            } catch { self.error = (error as? APIError)?.errorDescription ?? "解封失败" }
            busy = false
        }
    }
}

struct RegisterSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var nickname = ""
    @State private var password = ""
    @State private var cap = ""
    @State private var capId = ""
    @State private var capSvg = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("用户名（3-24 位字母/数字/下划线）", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                    .frame(height: 54).padding(.horizontal, 14)
                HairLine(color: C.navLine)
                TextField("昵称", text: $nickname).frame(height: 54).padding(.horizontal, 14)
                HairLine(color: C.navLine)
                SecureField("密码（至少 6 位）", text: $password).frame(height: 54).padding(.horizontal, 14)
                HairLine(color: C.navLine)
                HStack(spacing: 10) {
                    TextField("图形验证码", text: $cap).autocorrectionDisabled(true)
                    CaptchaView(svg: capSvg)
                        .frame(width: 96, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.navLine, lineWidth: 0.5))
                        .onTapGesture { loadCaptcha() }
                }
                .font(.system(size: 15))
                .frame(height: 54).padding(.horizontal, 14)

                if let e = error {
                    Text(e).font(.system(size: 13)).foregroundColor(C.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }
                Button { submit() } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                        Text(busy ? "请稍候…" : "注 册").font(.system(size: 16, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(LoginTheme.accent).cornerRadius(16)
                }
                .disabled(busy)
                .padding(.top, 20)
                Spacer()
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } } }
        }
        .onAppear { loadCaptcha() }
    }

    private func loadCaptcha() {
        Task {
            if let c = try? await API.shared.captcha() { capId = c.id; capSvg = c.svg }
        }
    }
    private func submit() {
        if username.count < 3 { error = "用户名至少 3 位"; return }
        if password.count < 6 { error = "密码至少 6 位"; return }
        if cap.isEmpty { error = "请填写图形验证码"; return }
        busy = true; error = nil
        Task {
            do {
                _ = try await API.shared.register(username: username, nickname: nickname.isEmpty ? username : nickname,
                                                 password: password, captchaId: capId, captcha: cap)
                try await app.login(username: username, password: password)
                app.show("注册成功")
                dismiss()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "注册失败"
                loadCaptcha()
            }
            busy = false
        }
    }
}

/* ---------- 「微信登录」→ 设备确认登录（出 6 位数字，在已登录设备上确认） ---------- */
struct PairSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var status = "正在生成…"
    @State private var fail = false
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("在已登录的设备上确认，这台设备就能进入")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 24)

                Text(code.isEmpty ? "······" : code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .tracking(6)

                Text(fail
                     ? "这个码过期了，点下面重新生成"
                     : "打开另一台已登录的设备 → 我 → 设置 → 设备确认登录，输入上面的数字")
                    .font(.system(size: 12.5)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)

                if fail {
                    Button("重新生成") { start() }
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(C.loginGreen)
                } else {
                    ProgressView()
                    Text(status).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle("微信登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("取消") { stop(); dismiss() } } }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        fail = false; status = "正在生成…"
        Task {
            do {
                let r = try await API.shared.pairStart()
                code = r.code; status = "等待确认…"
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in poll() }
            } catch {
                fail = true
                status = (error as? APIError)?.errorDescription ?? "生成失败"
            }
        }
    }
    private func poll() {
        guard !code.isEmpty else { return }
        Task {
            guard let r = try? await API.shared.pairStatus(code: code) else { return }
            switch r.status {
            case "approved":
                stop()
                if let t = r.token, !t.isEmpty { API.shared.setToken(t) }
                await app.refreshAll(); Realtime.shared.start(); dismiss()
            case "expired":
                stop(); fail = true
            default:
                status = "等待确认…"
            }
        }
    }
    private func stop() { timer?.invalidate(); timer = nil }
}

/* ---------- 用户协议 / 隐私政策 ---------- */
struct TermsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var kind: Int

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind == 0 ? "用户协议" : "隐私政策").font(.system(size: 19, weight: .semibold))
                    /* 内容由后台「🎨 登录页 → 用户协议 / 隐私政策」配置 */
                    Text(LoginTheme.text(kind: kind))
                    .font(.system(size: 14)).lineSpacing(6)
                }
                .padding(20)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("好") { dismiss() } } }
        }
    }
}

/* ============================================================
   手机号登录（按你给的 PhoneLoginView 代码原样实现）
   同样只有两处 iOS 上不能用、做了同款外观的等价替换：
     · .toggleStyle(.checkbox) 是 macOS 专有 → 同外观方框勾选
     · Text.rich(TextSpan{...}) 不是 SwiftUI 类型 → 等价富文本写法
   业务动作接的是真的接口：发验证码 → 服务器；点登录 → 登录并进入 App
   ============================================================ */

struct PhoneLoginView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var isAgree = false
    @State private var countDown = 0
    @State private var timer: Timer?
    @State private var error: String?
    @State private var busy = false
    @State private var showTerms = false
    @State private var termsKind = 0
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Spacer(minLength: 30)
                    Text("手机号登录")
                        .font(.system(size: 24, weight: .semibold))

                    // 手机号输入框
                    TextField("请输入手机号", text: $phone)
                        .keyboardType(.numberPad)
                        .font(.system(size: 16))
                        .padding(16)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .focused($focused)

                    // 验证码行
                    HStack(spacing: 12) {
                        TextField("请输入验证码", text: $code)
                            .keyboardType(.numberPad)
                            .font(.system(size: 16))
                            .padding(16)
                            .background(Color(.systemGray6))
                            .cornerRadius(12)

                        Button {
                            sendCode()
                        } label: {
                            Text(countDown > 0 ? "\(countDown)s" : "获取验证码")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 100, height: 52)
                                .background(countDown > 0 ? LoginTheme.disabledGray : LoginTheme.accent2)
                                .cornerRadius(12)
                        }
                        .disabled(countDown > 0 || phone.count != 11)
                    }

                    // 登录按钮
                    Button {
                        phoneLogin()
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                            Text("登录")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(canSubmit ? LoginTheme.accent2 : LoginTheme.disabledGray)
                        .cornerRadius(16)
                    }
                    .disabled(!canSubmit)

                    if let e = error {
                        Text(e).font(.system(size: 13)).foregroundColor(C.red)
                    }

                    // 协议勾选
                    HStack(alignment: .top, spacing: 8) {
                        Button { isAgree.toggle() } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isAgree ? LoginTheme.accent2 : LoginTheme.disabledGray, lineWidth: 1.4)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(isAgree ? LoginTheme.accent2 : Color.clear))
                                .frame(width: 16, height: 16)
                                .overlay(isAgree
                                         ? Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                         : nil)
                        }
                        .padding(.top, 1)

                        Text(.init("我已阅读并同意 [《用户协议》](terms://0) 和 [《隐私政策》](terms://1)"))
                            .font(.system(size: 12))
                            .tint(LoginTheme.accent2)
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "terms" {
                                    termsKind = Int(url.host ?? "0") ?? 0
                                    showTerms = true
                                }
                                return .handled
                            })
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                }
            }
        }
        .sheet(isPresented: $showTerms) { TermsSheet(kind: termsKind) }
        .onDisappear {
            timer?.invalidate()
        }
    }

    var canSubmit: Bool {
        isAgree && phone.count == 11 && code.count >= 4 && !busy
    }

    func sendCode() {
        error = nil
        Task {
            do {
                if let dev = try await API.shared.phoneCode(phone: phone) {
                    code = dev
                    app.show("验证码：\(dev)")
                } else {
                    app.show("验证码已发送")
                }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "发送失败"
            }
        }
        countDown = 60
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if countDown > 0 {
                countDown -= 1
            } else {
                t.invalidate()
            }
        }
    }

    func phoneLogin() {
        busy = true
        error = nil
        Task {
            do {
                try await app.login(phone: phone, code: code)
                dismiss()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "登录失败"
            }
            busy = false
        }
    }
}

