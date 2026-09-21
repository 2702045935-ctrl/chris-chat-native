import SwiftUI

struct MeView: View {
    @ObservedObject private var lang = LangStore.shared
    @State private var showMyQR = false
    @EnvironmentObject var app: AppState
    @State private var path = NavigationPath()
    /// 后台配的我页下面那几行（加一行、删一行，切回本页就变）
    @State private var items: [DiscoverItem] = []
    @State private var loaded = false
    @ObservedObject private var realtime = Realtime.shared

    private var friendCount: Int { app.contacts.count }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    profileTop
                    GroupGap()

                    // 下面这些行全部来自后台配置（/api/me-page）
                    ForEach(grouped.indices, id: \.self) { gi in
                        GroupCard {
                            ForEach(grouped[gi].indices, id: \.self) { ri in
                                let item = grouped[gi][ri]
                                if ri > 0 { rowLine }
                                MenuRow(icon: (item.svg?.isEmpty == false) ? item.svg! : I.star,
                                        iconColor: Color(hexString: item.color ?? "#4A90D9", fallback: 0x4A90D9),
                title: Tr(item.label),
                                        onTap: { open(item) })
                            }
                            if UIConfig.num("showPromo", 0) > 0 && gi == grouped.count - 1 {
                                rowLine
                                promoRow
                            }
                        }
                        GroupGap()
                    }

                    Spacer().frame(height: 24)
                }
            }
            .background(C.pageBg)
            .ignoresSafeArea(edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                if key == "settings" {
                    SettingsView()
                } else if key == "moments" {
                    MomentsView()
                } else if key == "profile" {
                    ProfileEditView()
                } else if key == "service" {
                    ServiceView()
                } else if key == "favorites" {
                    FavoritesView()
                } else if key == "stickers" {
                    StickerView()
                } else if key == "works" {
                    WorksView()
                } else if key == "status" {
                    StatusView()
                } else if key == "paypwd" {
                    PayPasswordView()
                } else {
                    ComingSoonView(title: String(key.dropFirst(5)))
                }
            }
        }
        // 自己的资料变了（头像 / 昵称 / 封面 / 状态）→ 我页立刻变
        .onChange(of: realtime.event) { ev in
            if ev.user != nil || ev.type == "profile" {
                Task { app.me = try? await API.shared.me() }
            }
            if ev.type == "ui" { Task { await loadItems() } }
        }
        .task { if !loaded { await loadItems() } }
    }

    /// 按 group 分组：同一组排一张卡（和网页版一致）
    private var grouped: [[DiscoverItem]] {
        var out: [[DiscoverItem]] = []
        var last: Int? = nil
        for it in items {
            let g = it.group ?? 1
            if last == nil || g != last! { out.append([]); last = g }
            out[out.count - 1].append(it)
        }
        return out
    }

    private func loadItems() async {
        if let list = try? await API.shared.mePage(), !list.isEmpty {
            items = list
            loaded = true
        } else if items.isEmpty {
            items = DiscoverItem.builtinMe       // 拉不到就用内置那套，别空着
        }
    }

    private func open(_ item: DiscoverItem) {
        switch item.action ?? "soon" {
        case "service": path.append("service")
        case "favorites": path.append("favorites")
        case "moments": path.append("moments")
        case "works": path.append("works")
        case "stickers": path.append("stickers")
        case "settings": path.append("settings")
        default: path.append("soon:" + item.label)
        }
    }

    private var gap: some View {
        Rectangle().fill(C.pageBg).frame(height: L.groupGap)
    }

    private var rowLine: some View {
        HairLine(inset: L.menuLineInset)
    }

    /* ---------------------------------------------------------- 顶部资料卡 */

    private var profileTop: some View {
        VStack(spacing: 0) {
            // 白色的顶：从状态栏最上面就开始铺白（和微信一样）
            // 网页版量出来：头像离内容顶部 67px（.me-profile padding-top: 67px）
            Spacer().frame(height: L.safeTop + 67)

            Button {
                path.append("profile")
            } label: {
            HStack(alignment: .center, spacing: 0) {
                Avatar(path: app.me?.avatarPath ?? "", size: L.v(58, 15.6, 66), circle: true)
                    .frame(width: L.v(58, 15.6, 66), height: L.v(58, 15.6, 66))

                VStack(alignment: .leading, spacing: 0) {
                    Text(app.me?.name ?? "")
                        .font(pf(L.v(17, 4.8, 19.5)))
                        .foregroundColor(C.label)
                Text("微信号：\(app.me?.username ?? "-")")
                        .font(pf(16))
                        .foregroundColor(Color.dyn(0x737373, 0x8F8F8F))
                        .padding(.top, L.v(4, 1.8, 8))
                }
                .padding(.leading, 21.5)

                Spacer(minLength: 0)

                Button {
                    showMyQR = true
                } label: {
                    SVGIcon(markup: I.qr, size: L.v(19, 5.4, 21), color: C.arrow)
                        .frame(width: L.v(26, 7.4, 30), height: L.v(26, 7.4, 30))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.leading, 28)
            .padding(.trailing, L.v(14, 4, 18))
            .padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            HStack(spacing: L.v(8, 2.6, 11)) {
                chip {
                    if let mood = app.me?.moodText, !mood.isEmpty {
                        Text(app.me?.moodIcon ?? "")
                        Text(mood)
                    } else {
                        Text("＋").foregroundColor(C.subLabel)
                        Text(Tr("状态"))
                    }
                } action: {
                    path.append("status")
                }
                chip {
                    Text(Tr("朋友圈"))
                    Text("\(friendCount) 个朋友")
                        .font(pf(L.v(11.5, 3.2, 12.5)))
                        .foregroundColor(C.subLabel)
                        .padding(.leading, L.v(3, 1.2, 5))
                } action: {
                    path.append("moments")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, L.v(92, 28, 113))
            .padding(.trailing, L.v(14, 4, 18))
            .padding(.bottom, 22)
        }
        .background(C.cardBg)
    }

    private func chip<Content: View>(@ViewBuilder content: () -> Content, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: L.v(2, 1, 4)) { content() }
                .font(pf(L.v(12.5, 3.4, 13.5)))
                .foregroundColor(Color.dyn(0x191919, 0xF2F2F7))
                .padding(.horizontal, L.v(10, 3.2, 13))
                .frame(height: L.v(28, 8, 32))
                .overlay(
                    Capsule().stroke(Color.dyn(0xE5E5E5, 0x333335), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 推荐位 */

    private var promoRow: some View {
        Button {
            app.show(Tr("推荐位排在下一批"))
        } label: {
            HStack(spacing: L.v(10, 3.2, 13)) {
                SVGIcon(markup: I.coke, size: L.v(38, 11, 46), color: .white)
                    .frame(width: L.v(26, 7.6, 32), height: L.v(38, 11, 46))
                VStack(alignment: .leading, spacing: L.v(3, 1.2, 5)) {
                    Text(Tr("热卖 5000+"))
                        .font(pf(L.v(10.5, 2.9, 11.5)))
                        .foregroundColor(Color.dyn(0xE0393B, 0xFF8A8D))
                        .padding(.horizontal, L.v(5, 1.6, 7))
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.dyn(0xFFECEB, 0x4A1F20)))
                    Text(Tr("添加第1个作品"))
                        .font(pf(L.v(14, 3.9, 15.5)))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
            }
            .padding(.leading, L.v(16, 5, 19))
            .padding(.trailing, L.v(14, 4, 16))
            .frame(height: L.menuH)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }
}

/* ============================================================ 设置 */

struct SettingsView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false
    @State private var busy = false
    @State private var showBg = false
    @State private var showBgPick = false
    @State private var showTheme = false
    /// 有没有设过支付密码（设置页那一行显示「已设置 / 未设置」）
    @State private var hasPay = false
    @State private var showFeedback = false
    @State private var showAbout = false
    @State private var showLang = false
    @State private var showPairApprove = false
    @State private var showMyQR = false
    @State private var showPrivacy = false
    @State private var showNotify = false
    @State private var showGeneral = false
    @State private var showProfileEdit = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("设置"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        /* 按微信「设置」的顺序排：账号与安全 → 新消息通知 → 隐私 → 通用 → 帮助与反馈 → 关于 → 退出登录 */
                        settingRow(Tr("个人信息"), app.me?.name ?? "") { showProfileEdit = true }
                        HairLine(inset: 16)
                        settingRow(Tr("账号与安全"), "") { app.show(Tr("账号与安全排在下一批")) }
                        HairLine(inset: 16)
                        /* 网页版「微信授权登录 / QQ 授权登录」出的 6 位数字在这里确认 */
                        settingRow(Tr("设备确认登录"), "") { showPairApprove = true }
                        HairLine(inset: 16)
                        /* 支付密码：点进去设置 / 修改（转账付款时要输它） */
                        settingLink(Tr("支付密码"), hasPay ? "已设置" : "未设置", key: "paypwd")
                        HairLine(inset: 16)
                        settingRow(Tr("新消息通知"), "") { showNotify = true }
                        HairLine(inset: 16)
                        settingRow(Tr("隐私"), "") { showPrivacy = true }
                        HairLine(inset: 16)
                        /* 通用：外观 / 界面语言 / 聊天背景（微信也把这几项收在「通用」里） */
                        settingRow(Tr("通用"), "") { showGeneral = true }
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        settingRow(Tr("帮助与反馈"), "") { showFeedback = true }
                        HairLine(inset: 16)
                        settingRow(Tr("关于我们 · 版本更新"), "1.0 · " + AppInfo.build) { showAbout = true }
                    }

                    Button {
                        confirmLogout = true
                    } label: {
                        Text(busy ? "退出中…" : "退出登录")
                            .font(pf(17))
                            .foregroundColor(C.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(C.cardBg)
                    }
                    .disabled(busy)
                    .padding(.top, 8)

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
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
        .confirmationDialog(Tr("外观"), isPresented: $showTheme, titleVisibility: .visible) {
            Button(Tr("跟随系统")) { app.setAppearance("auto") }
            Button(Tr("浅色")) { app.setAppearance("light") }
            Button(Tr("深色")) { app.setAppearance("dark") }
            Button(Tr("取消"), role: .cancel) { }
        }
        .sheet(isPresented: $showBgPick) {
            PhotoPicker { image in changeBg(image) }
        }
        .sheet(isPresented: $showFeedback) { FeedbackView() }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showPairApprove) { PairApproveView() }
        .sheet(isPresented: $showMyQR) { MyQRView() }
        .sheet(isPresented: $showPrivacy) { PrivacyView() }
        .sheet(isPresented: $showNotify) { NotifyView() }
        .sheet(isPresented: $showGeneral) { GeneralView() }
        .sheet(isPresented: $showProfileEdit) { ProfileEditView() }
        .confirmationDialog(Tr("界面语言"), isPresented: $showLang, titleVisibility: .visible) {
            Button(Tr("简体中文")) { setLang("zh") }
            Button("English") { setLang("en") }
            Button(Tr("取消"), role: .cancel) { }
        }
        .task { hasPay = await API.shared.hasPayPassword() }
        .confirmationDialog(Tr("确定退出登录？"), isPresented: $confirmLogout, titleVisibility: .visible) {
            Button(Tr("退出登录"), role: .destructive) {
                busy = true
                Task {
                    await app.logout()
                    busy = false
                }
            }
            Button(Tr("取消"), role: .cancel) { }
        }
    }

    /// 切换界面语言：存下来 + 让标签栏那些文案立刻重绘
    private func setLang(_ code: String) {
        Lang.code = code
        app.show(code == "en" ? "Language switched to English" : "界面语言已切成中文")
        dismiss()
        /* 同上：运行中不重绘，重开 App 生效 */
    }

    private func changeBg(_ image: UIImage) {
        busy = true
        Task {
            if let url = try? await API.shared.upload(image: image) {
                await API.shared.changeBackground(url)
                app.me = try? await API.shared.me()
                app.show(Tr("聊天背景换好了"))
            }
            busy = false
        }
    }

    private func settingRow(_ title: String, _ value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(pf(17)).foregroundColor(C.label)
                Spacer(minLength: 0)
                if !value.isEmpty {
                    Text(value).font(pf(15)).foregroundColor(C.subLabel)
                }
                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }

    /// 和 settingRow 长得一样，但点进去是下一个页面（用导航）
    private func settingLink(_ title: String, _ value: String, key: String) -> some View {
        NavigationLink(value: key) {
            HStack(spacing: 12) {
                Text(title).font(pf(17)).foregroundColor(C.label)
                Spacer(minLength: 0)
                if !value.isEmpty {
                    Text(value).font(pf(15)).foregroundColor(C.subLabel)
                }
                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }
}
