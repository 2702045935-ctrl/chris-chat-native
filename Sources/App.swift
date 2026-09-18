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
    @Published var toast: String?
    @Published var loadingChats = false
    @Published var loadError: String?
    /// 服务器上的界面配置变了就 +1，整个界面重建一次（不用重装 App）
    @Published var uiVersion = 0
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
            RootView().environmentObject(app)
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

struct LoginView: View {
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
                    TextField("192.168.2.7:5180", text: $server)
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
