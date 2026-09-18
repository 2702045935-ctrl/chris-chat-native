import SwiftUI
import UIKit

/* ============================================================ 全局状态 */

@MainActor
final class AppState: ObservableObject {
    @Published var booting = true
    @Published var me: User? {
        didSet { rememberLastUser() }        // 谁登录（或改了头像）就记住谁，登录页圆圈用它
    }
    /// 这台设备上最后登录的人（登录页圆圈显示他的头像 / 名字）
    @Published var lastAvatar: String = UserDefaults.standard.string(forKey: "chris.lastAvatar") ?? ""
    @Published var lastName: String = UserDefaults.standard.string(forKey: "chris.lastName") ?? ""
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
        switch ev.type {
        case "message":
            coalesce { [weak self] in await self?.loadChats() }
        case "chat":
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
            // 连不上（不在家 / 电脑没开）时先留着登录状态
        }
        booting = false
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

    /// 记住这台设备上最后登录的人（登录页的圆圈用它显示头像）
    func rememberLastUser() {
        guard let me = me else { return }
        lastAvatar = me.avatar ?? ""
        lastName = me.nickname ?? me.username ?? ""
        UserDefaults.standard.set(lastAvatar, forKey: "chris.lastAvatar")
        UserDefaults.standard.set(lastName, forKey: "chris.lastName")
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
        if let list = try? await API.shared.contacts() { contacts = list }
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
                    Realtime.shared.start()
                }
            }
        }
        .onChange(of: realtime.event) { ev in
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

    enum Way: String, Identifiable { case phone, password; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)

                    // App Logo（你代码里是灰色圆形占位；后台配了 logo 就用 logo，没配就是灰圆）
                    Group {
                        /* 优先显示「这台设备上最后登录的人」的头像 —— 谁登录过就显示谁 */
                        if !app.lastAvatar.isEmpty {
                            RemoteImage(path: app.lastAvatar, icon: "person.fill", mode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                        } else if let p = logoPath {
                            RemoteImage(path: p, icon: "message.fill", mode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                        } else if let img = AppIconImage.image {
                            Image(uiImage: img).resizable()
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .frame(width: 80, height: 80)
                                .foregroundColor(.gray.opacity(0.2))
                        }
                    }
                    Text(appName)
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 16)
                    Text("欢迎回来，请选择登录方式")
                        .font(.system(size: 14))
                        .foregroundColor(LoginTheme.sub ?? .secondary)
                        .padding(.top, 20)

                    Spacer(minLength: 48)

                    // 微信登录按钮
                    Button {
                        if isAgree { loginWithWechat() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "message.fill")
                                .resizable()
                                .frame(width: 24, height: 24)
                            Text("微信登录")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(isAgree ? LoginTheme.accent : LoginTheme.disabledAccent)
                        .cornerRadius(16)
                    }
                    .disabled(!isAgree)

                    // 手机号登录 ｜ 账号密码登录（保持你代码的样式，做成可点，否则没法登录）
                    HStack(spacing: 6) {
                        Button("手机号登录") { sheet = .phone }
                        Text("｜").foregroundColor(LoginTheme.disabledGray)
                        Button("账号密码登录") { sheet = .password }
                    }
                    .font(.system(size: 14))
                    .foregroundColor(LoginTheme.sub ?? Color(hexString: "#636366"))
                    .padding(.top, 24)

                    Spacer(minLength: 32)

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

                    Spacer()

                    Text("V1.0.0")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hexString: "#AEAEB2"))
                        .padding(.top, 60)
                        .padding(.bottom, 20)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: UIScreen.main.bounds.height - 120, alignment: .top)
            }
            .background(Color.clear)
            .navigationTitle("账号登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { focus = nil } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
        .sheet(isPresented: $showPair) { PairSheet() }
        .sheet(isPresented: $showTerms) { TermsSheet(kind: termsKind) }
        .sheet(item: $sheet) { w in
            if w == .phone { PhoneLoginView() } else { AccountLoginSheet(mode: w) }
        }
        /* 登录页背景：后台配了背景图就用它（压一层薄薄的底色保证文字看得清），否则用系统背景 */
        .background(
            ZStack {
                if !LoginTheme.bgImage.isEmpty {
                    RemoteImage(path: LoginTheme.bgImage, icon: "photo", mode: .fill)
                        .ignoresSafeArea()
                    Color(.systemBackground).opacity(0.30).ignoresSafeArea()
                } else {
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
        )
        .onAppear {
            Task {
                if let b = await API.shared.branding() {
                    LoginTheme.apply(b)
                    if let n = b.login?.appName ?? b.appName, !n.isEmpty { appName = n }
                    if let lg = b.login?.logo ?? b.logo, !lg.isEmpty { logoPath = lg }
                }
            }
        }
    }

    func loginWithWechat() {
        // 按最新要求：点「微信登录」直接进入账号密码登录页
        sheet = .password
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
        }
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
