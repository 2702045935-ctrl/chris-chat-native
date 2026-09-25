import SwiftUI

/* ============================================================
   青少年模式 / 关怀模式（微信「设置」里那两项）
   · 青少年模式：先设 4 位密码 → 开关（要密码）→ 勾选限制哪些功能
     （视频号 / 直播 / 游戏 / 附近的人 / 摇一摇 / 搜一搜 / 支付）
     服务端会真的把这些接口挡住；家长手机号只存脱敏
   · 关怀模式：本机开关，开了全站字号放大（照顾长辈）
   ============================================================ */
struct TeenModeView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: API.TeenStatus?
    @State private var loading = true
    @State private var pin = ""
    @State private var askPin = false
    @State private var pendingEnable: Bool? = nil
    @State private var guardian = ""
    @State private var busy = false

    private let items: [(String, String)] = [
        ("feed", "视频号"), ("live", "直播"), ("games", "游戏"),
        ("nearby", "附近的人"), ("shake", "摇一摇"), ("search", "搜一搜"), ("pay", "支付")
    ]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("青少年模式"), back: { dismiss() })
            if loading {
                ProgressView().padding(.top, 60)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        GroupCard {
                            HStack {
                                Text(Tr("开启青少年模式")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Toggle("", isOn: Binding(
                                    get: { cfg?.enabled ?? false },
                                    set: { v in requestToggle(v) }
                                )).labelsHidden().tint(C.green)
                            }
                            .padding(.horizontal, 16).frame(height: 54)
                            HairLine(inset: 16)
                            HStack {
                                Text(Tr("家长手机号")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 6)
                                TextField(Tr("选填"), text: $guardian)
                                    .font(pf(15)).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                            }
                            .padding(.horizontal, 16).frame(height: 52)
                            if let g = cfg?.guardianPhone, !g.isEmpty {
                                HairLine(inset: 16)
                                HStack {
                                    Text(Tr("已绑定的监护人")).font(pf(16)).foregroundColor(C.label)
                                    Spacer(minLength: 6)
                                    Text(g).font(pf(15)).foregroundColor(C.subLabel)
                                }
                                .padding(.horizontal, 16).frame(height: 52)
                            }
                        }
                        .padding(.top, 10)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(Tr("受限功能（关掉的不能进）")).font(pf(13)).foregroundColor(C.subLabel)
                                .padding(.horizontal, 8).padding(.bottom, 6)
                            GroupCard {
                                ForEach(Array(items.enumerated()), id: \.offset) { idx, it in
                                    if idx > 0 { HairLine(inset: 16) }
                                    HStack {
                                        Text(Tr(it.1)).font(pf(16)).foregroundColor(C.label)
                                        Spacer(minLength: 8)
                                        Text(on(it.0) ? Tr("已限制") : Tr("可用"))
                                            .font(pf(14)).foregroundColor(on(it.0) ? C.red : C.green)
                                        Toggle("", isOn: Binding(
                                            get: { on(it.0) },
                                            set: { v in setScope(it.0, restricted: v) }
                                        )).labelsHidden().tint(C.red).frame(width: 50)
                                    }
                                    .padding(.horizontal, 16).frame(height: 52)
                                }
                            }
                        }
                        .padding(.horizontal, 8).padding(.top, 14)

                        Text(cfg?.hasPin == true
                             ? Tr("开关和设置都要输 4 位密码；忘了密码只能让管理员在后台重置。")
                             : Tr("第一次打开会让你设一个 4 位密码，之后每次开关都要输它。"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24).padding(.top, 14)
                        Color.clear.frame(height: 26)
                    }
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .alert(Tr("输入青少年模式密码"), isPresented: $askPin) {
            TextField(Tr("4 位数字"), text: $pin).keyboardType(.numberPad)
            Button(Tr("取消"), role: .cancel) { pin = ""; pendingEnable = nil }
            Button(Tr("确定")) { confirmPin() }
        } message: {
            Text(Tr("开关青少年模式需要这个密码"))
        }
    }

    private func on(_ key: String) -> Bool { ((cfg?.scopes ?? [:])[key] ?? 0) == 0 }

    private func load() async {
        cfg = try? await API.shared.teen()
        loading = false
    }

    /// 点开关：已设过密码就要输密码，没设过先设一个（顺手就开启）
    private func requestToggle(_ v: Bool) {
        if cfg?.hasPin != true {
            pin = ""
            pendingEnable = v
            askPin = true
            return
        }
        pendingEnable = v
        pin = ""
        askPin = true
    }

    private func confirmPin() {
        let p = pin.trimmingCharacters(in: .whitespaces)
        guard p.count == 4 else {
            app.show(Tr("密码要 4 位数字")); pendingEnable = nil; pendingScope = nil; return
        }
        busy = true
        Task {
            do {
                if (cfg?.hasPin ?? false) == false {
                    cfg = try await API.shared.teenSetup(pin: p)
                }
                if let sc = pendingScope {
                    /* 勾上 = 限制（服务端 0 表示不可用） */
                    var s = cfg?.scopes ?? [:]
                    s[sc.0] = sc.1 ? 0 : 1
                    cfg = try await API.shared.teenSet(pin: p, enabled: nil, scopes: s,
                                                        guardianPhone: guardian.isEmpty ? nil : guardian)
                } else {
                    cfg = try await API.shared.teenSet(pin: p, enabled: pendingEnable, scopes: nil,
                                                        guardianPhone: guardian.isEmpty ? nil : guardian)
                }
                app.show(Tr("已保存"))
            } catch {
                app.show((error as? LocalizedError)?.errorDescription ?? Tr("操作失败"))
            }
            pin = ""
            pendingEnable = nil
            pendingScope = nil
            busy = false
        }
    }

    private func setScope(_ key: String, restricted: Bool) {
        guard let hasPin = cfg?.hasPin, hasPin else { app.show(Tr("先设一个密码")); return }
        pin = ""
        askPin = true
        pendingScope = (key, restricted)
    }
    @State private var pendingScope: (String, Bool)? = nil
}

/* ---------------------------------------------------------- 关怀模式 */
struct CareModeView: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var on = CareMode.on

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("关怀模式"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    GroupCard {
                        HStack {
                            Text(Tr("开启关怀模式")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            Toggle("", isOn: $on).labelsHidden().tint(C.green)
                        }
                        .padding(.horizontal, 16).frame(height: 54)
                    }
                    .padding(.top, 10)

                    VStack(spacing: 8) {
                        Text(Tr("效果预览")).font(pf(13)).foregroundColor(C.subLabel)
                        Text(Tr("聊天")) .font(on ? .system(size: 19) : .system(size: 16)).foregroundColor(C.label)
                        Text(Tr("开启后字更大、更好看清（说明里也会跟着变大）"))
                            .font(on ? .system(size: 15) : .system(size: 13)).foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(C.cardBg)
                    .padding(.top, 10)

                    Text(Tr("只改这台手机上的显示，不影响别人；关掉就恢复原来的字号。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 14)
                    Color.clear.frame(height: 26)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onChange(of: on) { v in
            CareMode.set(v)
            app.show(v ? Tr("关怀模式已开启") : Tr("关怀模式已关闭"))
        }
    }
}
