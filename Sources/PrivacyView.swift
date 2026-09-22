import SwiftUI

/* ============================================================
   隐私 / 消息通知（照微信那两页的逻辑和排布做）
   · 隐私：加我时需要验证、允许陌生人看朋友圈、添加我的方式（微信号/手机号/群聊/二维码）
   · 消息通知：新消息通知、声音、振动、显示消息详情、免打扰时段
   ============================================================ */

struct PrivacyView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var p = PrivacySettings()

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("隐私"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 8) {
                    GroupCard {
                        row(Tr("加我为朋友时需要验证"), $p.needVerify, "needVerify")
                        HairLine(inset: 16)
                        row(Tr("允许陌生人查看朋友圈"), $p.strangerMoments, "strangerMoments")
                    }
                    .padding(.top, 8)

                    Text(Tr("添加我的方式")).font(pf(13)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 12)
                    GroupCard {
                        row(Tr("微信号"), $p.addByWx, "addByWx")
                        HairLine(inset: 16)
                        row(Tr("手机号"), $p.addByPhone, "addByPhone")
                        HairLine(inset: 16)
                        row(Tr("群聊"), $p.addByGroup, "addByGroup")
                        HairLine(inset: 16)
                        row(Tr("二维码"), $p.addByQR, "addByQR")
                    }

                    Text(Tr("关掉之后，别人就不能用这个方式找到你、加你好友。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { p = await API.shared.privacy() }
    }

    private func row(_ title: String, _ value: Binding<Bool>, _ key: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { value.wrappedValue },
                set: { v in
                    value.wrappedValue = v
                    Task { await API.shared.setPrivacy(key, v) }
                }
            ))
            .labelsHidden().tint(C.green)
        }
        .padding(.horizontal, 16).frame(height: 50)
    }
}

struct NotifyView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var n = NotifySettings()
    @State private var muteOn = false
    @ObservedObject private var push = PushCenter.shared

    /// 系统那一层到底允不允许通知（微信「接收新消息通知」那一行显示的就是这个）
    private var sysText: String { push.authorized ? Tr("已开启") : Tr("已关闭") }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("新消息通知"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 8) {
                    /* 微信那一行在最上面：点一下直接跳到 iOS 设置里的通知页 */
                    GroupCard {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Text(Tr("接收新消息通知")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Text(sysText)
                                    .font(pf(15))
                                    .foregroundColor(push.authorized ? C.subLabel : C.red)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 8)

                    if !push.authorized {
                        Text(Tr("系统通知还没开：点上面那行去 iOS 设置里打开「允许通知」，不然 App 在后台收不到提醒。"))
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 22)
                    }

                    GroupCard {
                        row(Tr("App 内提醒"), $n.on, "on")
                        HairLine(inset: 16)
                        row(Tr("声音"), $n.sound, "sound")
                        HairLine(inset: 16)
                        row(Tr("振动"), $n.vibrate, "vibrate")
                        HairLine(inset: 16)
                        row(Tr("通知显示消息详情"), $n.showDetail, "showDetail")
                    }
                    .padding(.top, 8)

                    GroupCard {
                        HStack(spacing: 10) {
                            Text(Tr("免打扰")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            Toggle("", isOn: $muteOn).labelsHidden().tint(C.green)
                        }
                        .padding(.horizontal, 16).frame(height: 50)
                        if muteOn {
                            HairLine(inset: 16)
                            HStack(spacing: 10) {
                                DatePicker("", selection: Binding(
                                    get: { Self.time(n.muteStart, 22, 0) },
                                    set: { n.muteStart = Self.hhmm($0) }), displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                Text("—").foregroundColor(C.subLabel)
                                DatePicker("", selection: Binding(
                                    get: { Self.time(n.muteEnd, 7, 0) },
                                    set: { n.muteEnd = Self.hhmm($0) }), displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).frame(height: 50)
                        }
                    }

                    Text(Tr("免打扰时段里收到消息不响不震，进 App 还是能看到小红点。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            n = await API.shared.notifySettings()
            muteOn = !(n.muteStart.isEmpty || n.muteEnd.isEmpty)
            if !muteOn { n.muteStart = ""; n.muteEnd = "" }
            PushCenter.shared.start()          // 顺手问一次系统权限，那一行显示的就是最新状态
        }
        .onChange(of: muteOn) { on in
            if on { n.muteStart = "22:00"; n.muteEnd = "07:00" }
            else { n.muteStart = ""; n.muteEnd = "" }
            Task { await API.shared.setNotify(["muteStart": n.muteStart, "muteEnd": n.muteEnd]) }
        }
    }

    private func row(_ title: String, _ value: Binding<Bool>, _ key: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { value.wrappedValue },
                set: { v in
                    value.wrappedValue = v
                    Task { await API.shared.setNotify([key: v]) }
                }
            ))
            .labelsHidden().tint(C.green)
        }
        .padding(.horizontal, 16).frame(height: 50)
    }

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    static func time(_ s: String, _ h: Int, _ m: Int) -> Date {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if let d = f.date(from: s) { return d }
        var c = DateComponents(); c.hour = h; c.minute = m
        return Calendar.current.date(from: c) ?? Date()
    }
}

/* ---------------- 通用（外观 / 界面语言 / 聊天背景）---------------- */

struct GeneralView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showTheme = false
    @State private var showLang = false
    @State private var showBg = false
    @State private var showBgPick = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("通用"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        row(Tr("外观"),
                            app.appearance == "dark" ? Tr("深色")
                                : (app.appearance == "light" ? Tr("浅色") : Tr("跟随系统"))) { showTheme = true }
                        HairLine(inset: 16)
                        row(Tr("界面语言"), Lang.name) { showLang = true }
                        HairLine(inset: 16)
                        row(Tr("聊天背景"),
                            (app.me?.chatBackground ?? "auto") == "auto" ? Tr("恢复默认") : Tr("自定义")) { showBg = true }
                    }
                    .padding(.top, 8)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .confirmationDialog(Tr("外观"), isPresented: $showTheme, titleVisibility: .visible) {
            Button(Tr("跟随系统")) { app.setAppearance("auto") }
            Button(Tr("浅色")) { app.setAppearance("light") }
            Button(Tr("深色")) { app.setAppearance("dark") }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(Tr("界面语言"), isPresented: $showLang, titleVisibility: .visible) {
            Button("简体中文") { setLang("zh") }
            Button("English") { setLang("en") }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(Tr("聊天背景"), isPresented: $showBg, titleVisibility: .visible) {
            Button(Tr("从相册选一张")) { showBgPick = true }
            Button(Tr("恢复默认")) {
                Task {
                    await API.shared.changeBackground("auto")
                    app.me = try? await API.shared.me()
                    app.show(Tr("已恢复默认背景"))
                }
            }
            Button(Tr("取消"), role: .cancel) { }
        }
        .sheet(isPresented: $showBgPick) {
            PhotoPicker { image in changeBg(image) }
        }
    }

    private func row(_ title: String, _ value: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Text(title).font(pf(17)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Text(value).font(pf(15)).foregroundColor(C.subLabel)
                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func setLang(_ code: String) {
        Lang.code = code
        app.show(code == "en" ? "Language switched to English" : "界面语言已切成中文")
        dismiss()
        /* 不在运行中重绘界面（重绘这条路试过两次都会闪退）：
           语言已经存下来了，重开 App 就是新语言。 */
    }

    private func changeBg(_ image: UIImage) {
        Task {
            if let url = try? await API.shared.uploadOriginal(image: image) {   // 聊天背景用原图
                await API.shared.changeBackground(url)
                app.me = try? await API.shared.me()
                app.show(Tr("聊天背景换好了"))
            }
        }
    }
}

/* ---------------- 设置数据的模型 + 接口 ---------------- */

struct PrivacySettings {
    var needVerify = true
    var strangerMoments = false
    var addByWx = true
    var addByPhone = true
    var addByGroup = true
    var addByQR = true
}

struct NotifySettings {
    var on = true
    var sound = true
    var vibrate = true
    var showDetail = true
    var muteStart = ""
    var muteEnd = ""
}
