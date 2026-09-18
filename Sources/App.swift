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

/* ============================================================ 登录页（按设计稿）
   ← 返回 + 标题「账号登录」
   图标 + App 名 → 欢迎语 →【微信登录】大按钮 → 其他登录选项 → 协议 → 版本号 */

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var focus: Field?

    private enum Field: Hashable { case phone, code, user, pass }
    private enum Way { case none, phone, password }

    @State private var way: Way = .none
    @State private var phone = ""
    @State private var code = ""
    @State private var username = ""
    @State private var password = ""
    @State private var agreed = false
    @State private var busy = false
    @State private var error: String?
    @State private var showPair = false
    @State private var showTerms = false
    @State private var termsKind = 0            // 0=用户协议 1=隐私政策
    @State private var showServer = false
    @State private var server = API.shared.server
    @State private var appName = "CHRIS Chat"
    @State private var logoPath: String?

    var body: some View {
        ZStack {
            C.loginBg.ignoresSafeArea()
            VStack(spacing: 0) {
                navBar
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        logoBlock
                        Text("欢迎回来，请选择登录方式")
                            .font(pf(14)).foregroundColor(C.loginGray)
                            .padding(.top, 26)
                        wechatButton
                        otherWays
                        if way != .none { formArea; submitButton }
                        if let e = error {
                            Text(e).font(pf(13)).foregroundColor(C.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 12)
                        }
                        agreeRow
                        versionText
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, max(20, L.safeBottom))
                }
            }
        }
        .sheet(isPresented: $showPair) { PairSheet() }
        .sheet(isPresented: $showTerms) { TermsSheet(kind: termsKind) }
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

    /* ---------- 顶部导航栏 ---------- */
    private var navBar: some View {
        ZStack {
            Text("账号登录").font(pf(17, .semibold)).foregroundColor(C.loginText)
            HStack {
                Button {
                    if way != .none { way = .none }        // 从「其他方式」退回选择页
                    focus = nil
                    error = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(pf(20, .medium))
                        .foregroundColor(C.loginText)
                        .frame(width: 44, height: 52)
                }
                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 52)
    }

    /* ---------- 图标 + 名字 ---------- */
    private var logoBlock: some View {
        VStack(spacing: 12) {
            Group {
                if let p = logoPath {
                    RemoteImage(path: p, icon: "message.fill", mode: .fill)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else if let img = AppIconImage.image {
                    Image(uiImage: img).resizable()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(C.loginGreen).frame(width: 84, height: 84)
                        .overlay(Image(systemName: "message.fill").font(pf(36)).foregroundColor(.white))
                }
            }
            Text(appName).font(pf(20, .semibold)).foregroundColor(C.loginText)
        }
        .padding(.top, 28)
    }

    /* ---------- 微信登录（核心大按钮）---------- */
    private var wechatButton: some View {
        Button {
            focus = nil; error = nil
            if !agreed { error = "请先阅读并同意《用户协议》和《隐私政策》"; return }
            showPair = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "message.fill").font(pf(17, .semibold))
                Text("微信登录").font(pf(17, .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(C.loginGreen))
        }
        .padding(.top, 30)
    }

    /* ---------- 其他登录选项 ---------- */
    private var otherWays: some View {
        HStack(spacing: 14) {
            Text("其他登录选项").font(pf(13)).foregroundColor(C.loginGray)
            Button("手机号登录") {
                way = (way == .phone ? .none : .phone); error = nil; focus = nil
            }
            .font(pf(13, .medium)).foregroundColor(C.loginGreen)
            Text("|").font(pf(12)).foregroundColor(C.loginGray.opacity(0.5))
            Button("账号密码登录") {
                way = (way == .password ? .none : .password); error = nil; focus = nil
            }
            .font(pf(13, .medium)).foregroundColor(C.loginGreen)
        }
        .padding(.top, 22)
    }

    /* ---------- 展开的表单 ---------- */
    private var formArea: some View {
        VStack(spacing: 0) {
            if way == .phone {
                TextField("手机号", text: $phone)
                    .font(pf(15)).keyboardType(.numberPad).focused($focus, equals: .phone)
                    .frame(height: 54).padding(.horizontal, 14)
                HairLine(color: C.navLine)
                HStack(spacing: 8) {
                    TextField("验证码", text: $code)
                        .font(pf(15)).keyboardType(.numberPad).focused($focus, equals: .code)
                    Button("获取验证码") { sendCode() }
                        .font(pf(13.5)).foregroundColor(C.loginGreen)
                }
                .frame(height: 54).padding(.horizontal, 14)
            } else {
                TextField("微信号 / 用户名", text: $username)
                    .font(pf(15)).focused($focus, equals: .user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                    .frame(height: 54).padding(.horizontal, 14)
                HairLine(color: C.navLine)
                SecureField("密码", text: $password)
                    .font(pf(15)).focused($focus, equals: .pass)
                    .frame(height: 54).padding(.horizontal, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.dyn(0xFFFFFF, 0x1C1C1E)))
        .padding(.top, 18)
    }

    private var submitButton: some View {
        Button { submit() } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().progressViewStyle(.circular).tint(.white) }
                Text(busy ? "请稍候…" : "登 录").font(pf(16, .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(busy ? C.loginGreen.opacity(0.6) : C.loginGreen))
        }
        .disabled(busy)
        .padding(.top, 14)
    }

    /* ---------- 协议 ---------- */
    private var agreeRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { agreed.toggle() } label: {
                Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                    .font(pf(16)).foregroundColor(agreed ? C.loginGreen : C.loginGray)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("我已阅读并同意")
                    .font(pf(12.5)).foregroundColor(C.loginGray)
                HStack(spacing: 4) {
                    Button("《用户协议》") { termsKind = 0; showTerms = true }
                        .font(pf(12.5)).foregroundColor(C.loginGreen)
                    Button("《隐私政策》") { termsKind = 1; showTerms = true }
                        .font(pf(12.5)).foregroundColor(C.loginGreen)
                }
            }
            Spacer()
        }
        .padding(.top, 30)
    }

    /* ---------- 版本号 ---------- */
    private var versionText: some View {
        VStack(spacing: 6) {
            Text("版本 \(AppInfo.version)（build \(AppInfo.build)）")
                .font(pf(11)).foregroundColor(C.loginGray.opacity(0.7))
            Button { showServer = true } label: {
                Text("服务器 \(server)")
                    .font(pf(11)).foregroundColor(C.loginGray.opacity(0.55))
            }
        }
        .padding(.top, 34)
    }

    /* ---------- 动作 ---------- */
    private func sendCode() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.count < 5 { error = "请填写手机号"; return }
        error = nil
        Task {
            do {
                if let dev = try await API.shared.phoneCode(phone: p) {
                    code = dev
                    app.show("验证码：\(dev)")
                } else {
                    app.show("验证码已发送")
                }
            } catch { self.error = (error as? APIError)?.errorDescription ?? "发送失败" }
        }
    }

    private func submit() {
        guard agreed else { error = "请先阅读并同意《用户协议》和《隐私政策》"; return }
        busy = true; error = nil
        Task {
            do {
                if way == .phone {
                    let p = phone.trimmingCharacters(in: .whitespaces)
                    if p.isEmpty || code.isEmpty { throw APIError.message("请填写手机号和验证码") }
                    try await app.login(phone: p, code: code)
                } else {
                    let u = username.trimmingCharacters(in: .whitespaces)
                    if u.isEmpty || password.isEmpty { throw APIError.message("请填写账号和密码") }
                    try await app.login(username: u, password: password)
                }
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "登录失败"
            }
            busy = false
        }
    }
}

/* ---------- 「微信登录」→ 设备确认登录 ---------- */
struct PairSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var status = "正在生成…"
    @State private var fail = false
    @State private var timer: Timer?

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Text("在已登录的设备上确认，这台设备就能进入")
                    .font(pf(14)).foregroundColor(C.loginGray)
                    .multilineTextAlignment(.center).padding(.top, 20)

                Text(code.isEmpty ? "······" : code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .foregroundColor(C.loginText)
                    .tracking(6)

                Text(fail ? "这个码过期了，点下面重新生成" : "打开另一台设备（网页版/App）→ 我 → 设置 → 设备确认登录，输入上面的数字")
                    .font(pf(12.5)).foregroundColor(C.loginGray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if fail {
                    Button("重新生成") { start() }
                        .font(pf(15, .semibold)).foregroundColor(C.loginGreen)
                } else {
                    ProgressView().padding(.top, 4)
                    Text(status).font(pf(12)).foregroundColor(C.loginGray)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(C.loginBg.ignoresSafeArea())
            .navigationTitle("微信登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { stop(); dismiss() } }
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        fail = false
        status = "正在生成…"
        Task {
            do {
                let r = try await API.shared.pairStart()
                code = r.code
                status = "等待确认…"
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
                await app.refreshAll()
                Realtime.shared.start()
                dismiss()
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
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind == 0 ? "用户协议" : "隐私政策").font(pf(19, .semibold))
                    Text("""
                    1. 本应用是自建的即时通讯软件，账号与数据都保存在你自己的服务器上。
                    2. 请勿使用本应用传播违法违规内容；一经发现，管理员有权封禁账号。
                    3. 你的昵称、头像、朋友圈等资料仅用于本应用内的展示，不会提供给第三方。
                    4. 聊天内容保存在你自己的服务器数据库中，用于在登录设备之间同步。
                    5. 修改密码后，之前的登录令牌会立即失效，需要重新登录。
                    6. 如不同意以上条款，请不要使用本应用。
                    """)
                    .font(pf(14)).foregroundColor(C.loginText)
                    .lineSpacing(6)
                }
                .padding(20)
            }
            .background(C.loginBg.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("好") { dismiss() } }
            }
        }
    }
}
