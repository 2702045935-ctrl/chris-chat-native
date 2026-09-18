import SwiftUI
import UIKit

/* ============================================================ 全局状态 */

@MainActor
final class AppState: ObservableObject {
    @Published var booting = true
    @Published var me: User?
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
        await refreshAll()
        Realtime.shared.start()
    }

    func login(phone: String, code: String) async throws {
        me = try await API.shared.loginPhone(phone: phone, code: code)
        await refreshAll()
        Realtime.shared.start()
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
            C.loginBg.ignoresSafeArea()
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
            C.loginBg.ignoresSafeArea()
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
        .background(C.loginBg)
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

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var focus: Field?

    private enum Field: Hashable { case user, pass, phone, code, regUser, regNick, regPass, regCap }
    private enum Tab { case login, register }

    @State private var tab: Tab = .login
    @State private var useCode = false
    @State private var username = ""
    @State private var password = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var regUser = ""
    @State private var regNick = ""
    @State private var regPass = ""
    @State private var regCap = ""
    @State private var capId = ""
    @State private var capSvg = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showServer = false
    @State private var server = API.shared.server
    @State private var appName = "CHRIS Chat"
    @State private var logoPath: String?

    var body: some View {
        ZStack {
            C.loginBg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    tabs
                    card
                    if let e = error {
                        Text(e).font(pf(13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                    mainButton
                    linkRow
                    serverRow
                }
                .padding(.horizontal, 22)
                .padding(.top, max(30, L.safeTop + 22))
                .padding(.bottom, max(22, L.safeBottom))
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
        .onAppear {
            server = API.shared.server
            Task {
                if let b = await API.shared.branding() {
                    if let n = b.appName, !n.isEmpty { appName = n }
                    if let lg = b.logo, !lg.isEmpty { logoPath = lg }
                }
            }
        }
    }

    /* ---------- 顶部：图标 + 名字 ---------- */
    private var header: some View {
        VStack(spacing: 12) {
            Group {
                if let p = logoPath {
                    RemoteImage(path: p, icon: "message.fill", mode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                } else if let img = AppIconImage.image {
                    Image(uiImage: img).resizable()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(C.loginGreen)
                        .frame(width: 72, height: 72)
                        .overlay(Image(systemName: "message.fill").font(pf(32)).foregroundColor(.white))
                }
            }
            Text(appName).font(pf(20, .semibold)).foregroundColor(C.loginText)
            Text(tab == .login ? "登录后同步你的聊天记录" : "注册一个属于你的微信号")
                .font(pf(13)).foregroundColor(C.loginGray)
        }
        .padding(.bottom, 22)
    }

    /* ---------- 登录 / 注册 ---------- */
    private var tabs: some View {
        HStack(spacing: 28) {
            tabButton("登录", .login)
            tabButton("注册", .register)
        }
        .padding(.bottom, 14)
    }
    private func tabButton(_ title: String, _ t: Tab) -> some View {
        Button {
            tab = t; error = nil; focus = nil
            if t == .register && capSvg.isEmpty { loadCaptcha() }
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(pf(15, tab == t ? .semibold : .regular))
                    .foregroundColor(tab == t ? C.loginText : C.loginGray)
                RoundedRectangle(cornerRadius: 2)
                    .fill(tab == t ? C.loginGreen : Color.clear)
                    .frame(width: 20, height: 2.5)
            }
        }
    }

    /* ---------- 卡片 ---------- */
    private var card: some View {
        VStack(spacing: 0) {
            if tab == .login {
                if useCode {
                    field("", .phone, $phone, "手机号", .numberPad)
                    HairLine(color: C.navLine)
                    HStack(spacing: 8) {
                        TextField("验证码", text: $code)
                            .font(pf(15)).focused($focus, equals: .code).keyboardType(.numberPad)
                        Button("获取验证码") { sendCode() }
                            .font(pf(13.5)).foregroundColor(C.loginGreen)
                    }
                    .frame(height: 54).padding(.horizontal, 14)
                } else {
                    field("", .user, $username, "微信号 / 用户名", .default)
                    HairLine(color: C.navLine)
                    secureField("", .pass, $password, "密码")
                }
            } else {
                field("", .regUser, $regUser, "用户名（3-24 位字母/数字/下划线）", .default)
                HairLine(color: C.navLine)
                field("", .regNick, $regNick, "昵称", .default)
                HairLine(color: C.navLine)
                secureField("", .regPass, $regPass, "密码（至少 6 位）")
                HairLine(color: C.navLine)
                HStack(spacing: 10) {
                    TextField("图形验证码", text: $regCap)
                        .font(pf(15)).focused($focus, equals: .regCap)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                    CaptchaView(svg: capSvg)
                        .frame(width: 96, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.navLine, lineWidth: 0.5))
                        .onTapGesture { loadCaptcha() }
                }
                .frame(height: 54).padding(.horizontal, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dyn(0xFFFFFF, 0x1C1C1E)))
    }

    private func field(_ label: String, _ f: Field, _ text: Binding<String>, _ ph: String, _ kb: UIKeyboardType) -> some View {
        TextField(ph, text: text)
            .font(pf(15))
            .focused($focus, equals: f)
            .keyboardType(kb)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .frame(height: 54)
            .padding(.horizontal, 14)
    }
    private func secureField(_ label: String, _ f: Field, _ text: Binding<String>, _ ph: String) -> some View {
        SecureField(ph, text: text)
            .font(pf(15))
            .focused($focus, equals: f)
            .frame(height: 54)
            .padding(.horizontal, 14)
    }

    /* ---------- 主按钮 ---------- */
    private var mainButton: some View {
        Button { submit() } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                Text(busy ? "请稍候…" : (tab == .login ? "登 录" : "注 册"))
                    .font(pf(16, .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(busy ? C.loginGreen.opacity(0.6) : C.loginGreen))
        }
        .disabled(busy)
        .padding(.top, 20)
    }

    private var linkRow: some View {
        Button {
            if tab == .login { useCode.toggle() } else { tab = .login }
            error = nil; focus = nil
        } label: {
            Text(tab == .login ? (useCode ? "用账号密码登录" : "用手机验证码登录") : "已有账号，去登录")
                .font(pf(13)).foregroundColor(C.loginGreen)
        }
        .padding(.top, 16)
    }

    private var serverRow: some View {
        Button { showServer = true } label: {
            Text("服务器 \(server)（点这里可改）")
                .font(pf(11)).foregroundColor(C.loginGray.opacity(0.75))
        }
        .padding(.top, 22)
    }

    /* ---------- 动作 ---------- */
    private func loadCaptcha() {
        Task {
            do {
                let c = try await API.shared.captcha()
                capId = c.id; capSvg = c.svg
            } catch { }
        }
    }

    private func sendCode() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.count < 5 { error = "请填写手机号"; return }
        error = nil
        Task {
            do {
                let dev = try await API.shared.phoneCode(phone: p)
                if let c = dev { code = c; app.show("验证码：\(c)") } else { app.show("验证码已发送") }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "发送失败"
            }
        }
    }

    private func submit() {
        busy = true; error = nil
        Task {
            do {
                if tab == .register {
                    let u = regUser.trimmingCharacters(in: .whitespaces)
                    if u.count < 3 { throw APIError.message("用户名至少 3 位") }
                    if regPass.count < 6 { throw APIError.message("密码至少 6 位") }
                    if regCap.isEmpty { throw APIError.message("请填写图形验证码") }
                    _ = try await API.shared.register(username: u, nickname: regNick.isEmpty ? u : regNick,
                                                     password: regPass, captchaId: capId, captcha: regCap)
                    try await app.login(username: u, password: regPass)
                    app.show("注册成功，欢迎加入")
                } else if useCode {
                    let p = phone.trimmingCharacters(in: .whitespaces)
                    if p.isEmpty || code.isEmpty { throw APIError.message("请填写手机号和验证码") }
                    try await app.login(phone: p, code: code)
                } else {
                    let u = username.trimmingCharacters(in: .whitespaces)
                    if u.isEmpty || password.isEmpty { throw APIError.message("请填写账号和密码") }
                    try await app.login(username: u, password: password)
                }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "操作失败"
                if tab == .register { loadCaptcha() }
            }
            busy = false
        }
    }
}
