import SwiftUI

/* ============================================================
   零钱（钱包页点「零钱」进来）
   尺寸照参考图量的（iPhone @3x，420×912pt）：整页白底；
   金币 48 居中（导航栏下 59）；「我的零钱」17pt（金币下 ~36）；
   余额 44pt 半粗（标题下 12）；冻结提示 13pt 橙（余额下 24）；
   底下贴着屏幕底部：充值 183.7×47.7 圆角 8（绿），空 16，
   提现同尺寸（#F2F2F2），空 71 是「常见问题 / 账户升级服务」13pt（#576B95），
   空 10 是说明 12pt（#B3B3B3），最后留 25pt。
   文案/按钮/链接/样式都来自后台「零钱页」模块（GET /api/balance-page），余额是真的。
   ============================================================ */

struct BalancePageView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var cfg: BalancePageConfig?
    @State private var showBills = false
    @State private var showRecharge = false
    @State private var rechargeAmount = ""

    private var st: BalanceStyle { cfg?.style ?? BalanceStyle() }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "") {
                Button {
                    run("bills", "零钱明细")
                } label: {
                    Text(cfg?.detailLabel ?? "零钱明细")
                        .font(pf(15))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    top
                    Spacer(minLength: 40)
                    bottom
                }
                .frame(minHeight: 912 - L.safeTop - L.navH - L.safeBottom - 20, alignment: .top)
            }
            .background(st.pageBg)
        }
        .background(st.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationDestination(isPresented: $showBills) { BillsView() }
        .alert("充值", isPresented: $showRecharge) {
            TextField("金额", text: $rechargeAmount).keyboardType(.decimalPad)
            Button("充值") { doRecharge() }
            Button("取消", role: .cancel) { }
        }
        .task { await load() }
        .onChange(of: realtime.event) { ev in
            if ev.type == "balance" || ev.type == "transfer" || ev.type == "ui" { Task { await load() } }
        }
    }

    /* ---------------------------------------------------------- 上面：金币 + 我的零钱 + 余额 */

    private var top: some View {
        VStack(spacing: 0) {
            ZStack {
                SVGIcon(markup: cfg?.svg ?? "", size: st.icon, color: Color(hex: 0xFFC300))
                    .frame(width: st.icon, height: st.icon)
                /* 默认那枚金币是「实心金圆 + 白 ¥」，原生这层解析器给不出双色，这里补一个白 ¥ */
                if (cfg?.icon ?? "svc.coin") == "svc.coin" {
                    Text("¥")
                        .font(pf(st.icon * 0.46, .semibold))
                        .foregroundColor(.white)
                }
            }
            .padding(.top, 59)

            Text(cfg?.title ?? "我的零钱")
                .font(pf(st.titleFont))
                .foregroundColor(Color.dyn(0x363636, 0xEDEDED))
                .padding(.top, 36)

            Text(money(cfg?.balance ?? app.me?.balance ?? 0))
                .font(pf(st.amountFont, .semibold))
                .monospacedDigit()          // 钱用等宽数字
                .kerning(-0.8)
                .foregroundColor(Color.dyn(0x272727, 0xEDEDED))
                .padding(.top, 12)

            if let note = cfg?.note, !note.isEmpty {
                HStack(spacing: 4) {
                    Text(note).font(pf(st.noteFont)).foregroundColor(st.noteColorV)
                    Chevron(size: 6, line: 1.4, color: st.noteColorV)
                }
                .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /* ---------------------------------------------------------- 底部：充值 / 提现 / 链接 / 说明 */

    private var bottom: some View {
        VStack(spacing: 0) {
            Button {
                run(cfg?.recharge?.action ?? "recharge", cfg?.recharge?.label ?? "充值")
            } label: {
                Text(cfg?.recharge?.label ?? "充值")
                    .font(pf(17))
                    .foregroundColor(st.rechargeInkV)
                    .frame(width: st.btnW, height: st.btnH)
                    .background(RoundedRectangle(cornerRadius: st.btnR, style: .continuous).fill(st.rechargeBgV))
            }
            .buttonStyle(.plain)

            Button {
                run(cfg?.withdraw?.action ?? "withdraw", cfg?.withdraw?.label ?? "提现")
            } label: {
                Text(cfg?.withdraw?.label ?? "提现")
                    .font(pf(17))
                    .foregroundColor(st.withdrawInkV)
                    .frame(width: st.btnW, height: st.btnH)
                    .background(RoundedRectangle(cornerRadius: st.btnR, style: .continuous).fill(st.withdrawBgV))
            }
            .buttonStyle(.plain)
            .padding(.top, 16)

            HStack(spacing: 15) {
                ForEach((cfg?.links ?? []).filter { $0.enabled != false }) { l in
                    Button {
                        run(l.action ?? "soon", l.label)
                    } label: {
                        Text(l.label).font(pf(st.linkFont)).foregroundColor(st.linkColorV)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 71)

            if let f = cfg?.footer, !f.isEmpty {
                Text(f)
                    .font(pf(st.footFont))
                    .foregroundColor(st.footerColorV)
                    .padding(.top, 10)
            }
            Color.clear.frame(height: 25)
        }
    }

    /* ---------------------------------------------------------- 动作 */

    private func run(_ action: String, _ label: String) {
        switch action {
        case "recharge": rechargeAmount = ""; showRecharge = true
        case "bills": showBills = true
        case "withdraw": app.show("提现：还没接后端，先把页面做出来")
        default: app.show("「\(label)」还没接后端，先把页面做出来")
        }
    }

    private func doRecharge() {
        guard let amount = Double(rechargeAmount), amount > 0 else {
            app.show("金额不对")
            return
        }
        Task {
            if let balance = try? await API.shared.recharge(amount) {
                app.me = try? await API.shared.me()
                app.show("充值成功，余额 ¥\(String(format: "%.2f", balance))")
                await load()
            } else {
                app.show("充值失败")
            }
        }
    }

    private func money(_ v: Double) -> String { "¥" + String(format: "%.2f", v) }

    private func load() async {
        if let got = try? await API.shared.balancePage() {
            cfg = got
        }
    }
}
