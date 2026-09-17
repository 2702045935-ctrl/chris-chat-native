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
    @Published var appName: String = "CHRIS聊天"
    @Published var logo: String = ""
    @Published var toast: String?
    @Published var loadingChats = false
    @Published var loadError: String?

    private var toastTask: Task<Void, Never>?

    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if !Task.isCancelled { await MainActor.run { self?.toast = nil } }
        }
    }

    /// 启动：有本地令牌就自动登录，没有就停在登录页
    func boot() async {
        if let info = await API.shared.branding(), let n = info.appName, !n.isEmpty {
            appName = n
            logo = info.logo ?? ""
        }
        if API.shared.token.isEmpty {
            booting = false
            return
        }
        do {
            let s = try await API.shared.session()
            if s.ok, let user = s.user {
                me = user
                await refreshAll()
            } else {
                API.shared.clearToken()
            }
        } catch {
            // 网络不通时也让他进登录页
            API.shared.clearToken()
        }
        booting = false
    }

    func login(username: String, password: String) async throws {
        let user = try await API.shared.login(username: username, password: password)
        me = user
        await refreshAll()
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
        if let list = try? await API.shared.contacts() {
            contacts = list
        }
    }

    func loadMoments() async {
        if let list = try? await API.shared.moments() {
            moments = list
        }
    }

    func logout() async {
        await API.shared.logout()
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
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.78)))
                        .padding(.bottom, 110)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .task { await app.boot() }
        .onChange(of: scenePhase) { phase in
            if phase == .active && app.me != nil {
                Task { await app.loadChats() }
            }
        }
    }
}

struct LaunchView: View {
    var body: some View {
        ZStack {
            Brand.cellBg.ignoresSafeArea()
            VStack(spacing: 16) {
                if let img = AppIconImage.image {
                    Image(uiImage: img)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                Text("正在连接…").font(.system(size: 14)).foregroundColor(Brand.subLabel)
            }
        }
    }
}

/* ============================================================ 登录页 */

struct LoginView: View {
    @EnvironmentObject var app: AppState

    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showServer = false
    @State private var server = API.shared.server

    var body: some View {
        ZStack {
            Brand.cellBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 78)

                    if let img = AppIconImage.image {
                        Image(uiImage: img)
                            .resizable()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    Text(app.appName)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(Brand.label)
                        .padding(.top, 14)

                    Spacer().frame(height: 44)

                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: "person")
                                .font(.system(size: 16))
                                .foregroundColor(Brand.subLabel)
                                .frame(width: 22)
                            TextField("用户名", text: $username)
                                .font(.system(size: 17))
                                .foregroundColor(Brand.label)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .frame(height: 52)
                        }
                        .padding(.horizontal, 16)

                        Rectangle().fill(Brand.divider).frame(height: 0.5).padding(.leading, 48)

                        HStack(spacing: 10) {
                            Image(systemName: "lock")
                                .font(.system(size: 16))
                                .foregroundColor(Brand.subLabel)
                                .frame(width: 22)
                            SecureField("密码", text: $password)
                                .font(.system(size: 17))
                                .foregroundColor(Brand.label)
                                .frame(height: 52)
                        }
                        .padding(.horizontal, 16)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Brand.fieldBg))
                    .padding(.horizontal, 28)

                    if let error = error {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(Brand.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.top, 12)
                    }

                    Button {
                        submit()
                    } label: {
                        Text(busy ? "登录中…" : "登  录")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8).fill(busy ? Brand.green.opacity(0.6) : Brand.green))
                    }
                    .disabled(busy)
                    .padding(.horizontal, 28)
                    .padding(.top, 20)

                    Button {
                        showServer = true
                    } label: {
                        Text("服务器：\(server)")
                            .font(.system(size: 13))
                            .foregroundColor(Brand.subLabel)
                    }
                    .padding(.top, 22)

                    Spacer().frame(height: 80)
                }
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

    private func submit() {
        let u = username.trimmingCharacters(in: .whitespaces)
        if u.isEmpty || password.isEmpty {
            error = "请输入账号和密码"
            return
        }
        error = nil
        busy = true
        Task {
            do {
                try await app.login(username: u, password: password)
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
                Section(footer: Text("在电脑上运行 CHRIS聊天，手机连同一个 Wi-Fi，用电脑的 IP 填在这里。")) {
                    EmptyView()
                }
            }
            .navigationTitle("服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { onSave() }
                }
            }
        }
    }
}
