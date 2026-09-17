import SwiftUI

struct MeView: View {
    @EnvironmentObject var app: AppState
    @State private var path = NavigationPath()

    private var friendCount: Int { app.contacts.count }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    profileTop
                    GroupGap()

                    GroupCard {
                        MenuRow(icon: I.wallet, iconColor: Color(hex: 0x59C47E),
                                title: "服务", onTap: { path.append("service") })
                    }

                    GroupGap()

                    GroupCard {
                        MenuRow(icon: I.star, iconColor: Color(hex: 0x4489EA),
                                title: "收藏", onTap: { path.append("favorites") })
                        rowLine
                        MenuRow(icon: I.album, iconColor: Color(hex: 0x7275E9),
                                title: "朋友圈", onTap: { path.append("moments") })
                        rowLine
                        MenuRow(icon: I.works, iconColor: Color(hex: 0x3D83E7),
                                title: "作品", onTap: { path.append("works") })
                        if UIConfig.num("showPromo", 0) > 0 {
                            rowLine
                            promoRow
                        }
                    }

                    GroupGap()

                    // 参考图里「表情」是单独一组
                    GroupCard {
                        MenuRow(icon: I.sticker, iconColor: Color(hex: 0xF5C144),
                                title: "表情", onTap: { path.append("stickers") })
                    }

                    GroupGap()

                    GroupCard {
                        MenuRow(icon: I.gear, iconColor: Color(hex: 0x3D83E7),
                                title: "设置", onTap: { path.append("settings") })
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
                } else {
                    ComingSoonView(title: String(key.dropFirst(5)))
                }
            }
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
                    app.show("我的二维码排在下一批")
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
                    Text("＋").foregroundColor(C.subLabel)
                    Text("状态")
                } action: {
                    app.show("状态排在下一批")
                }
                chip {
                    Text("朋友圈")
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
            app.show("推荐位排在下一批")
        } label: {
            HStack(spacing: L.v(10, 3.2, 13)) {
                SVGIcon(markup: I.coke, size: L.v(38, 11, 46), color: .white)
                    .frame(width: L.v(26, 7.6, 32), height: L.v(38, 11, 46))
                VStack(alignment: .leading, spacing: L.v(3, 1.2, 5)) {
                    Text("热卖 5000+")
                        .font(pf(L.v(10.5, 2.9, 11.5)))
                        .foregroundColor(Color.dyn(0xE0393B, 0xFF8A8D))
                        .padding(.horizontal, L.v(5, 1.6, 7))
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.dyn(0xFFECEB, 0x4A1F20)))
                    Text("添加第1个作品")
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
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false
    @State private var busy = false
    @State private var showBg = false
    @State private var showBgPick = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "设置", back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        settingRow("个人信息", app.me?.name ?? "") { app.show("个人信息排在下一批") }
                        HairLine(inset: 16)
                        settingRow("聊天背景", (app.me?.chatBackground ?? "auto") == "auto" ? "默认" : "自定义") { showBg = true }
                        HairLine(inset: 16)
                        settingRow("账号与安全", "") { app.show("账号与安全排在下一批") }
                        HairLine(inset: 16)
                        settingRow("新消息通知", "") { app.show("通知设置排在下一批") }
                        HairLine(inset: 16)
                        settingRow("隐私", "") { app.show("隐私设置排在下一批") }
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        settingRow("关于 CHRIS聊天", "原生版 1.0") { }
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
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .confirmationDialog("聊天背景", isPresented: $showBg, titleVisibility: .visible) {
            Button("从相册选一张") { showBgPick = true }
            Button("恢复默认") {
                Task {
                    await API.shared.changeBackground("auto")
                    app.me = try? await API.shared.me()
                    app.show("已恢复默认背景")
                }
            }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showBgPick) {
            PhotoPicker { image in changeBg(image) }
        }
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                busy = true
                Task {
                    await app.logout()
                    busy = false
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private func changeBg(_ image: UIImage) {
        busy = true
        Task {
            if let url = try? await API.shared.upload(image: image) {
                await API.shared.changeBackground(url)
                app.me = try? await API.shared.me()
                app.show("聊天背景换好了")
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
}
