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
    @State private var showFaq = false
    @State private var faqAnswer: String?

    private var st: BalanceStyle { cfg?.style ?? BalanceStyle() }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航：左边返回箭头 + 中间「零钱明细」（和参考代码一致）
            NavBar(title: cfg?.navTitle ?? "零钱明细", back: { dismiss() })

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
            Button(Tr("充值")) { doRecharge() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(Tr("常见问题"), isPresented: $showFaq, titleVisibility: .visible) {
            ForEach((cfg?.faq ?? []).indices, id: \.self) { i in
                Button(cfg!.faq![i].q) { faqAnswer = cfg!.faq![i].a }
            }
            Button(Tr("关闭"), role: .cancel) { }
        }
        .alert("常见问题", isPresented: Binding(get: { faqAnswer != nil }, set: { if !$0 { faqAnswer = nil } })) {
            Button(Tr("知道了"), role: .cancel) { faqAnswer = nil }
        } message: {
            Text(faqAnswer ?? "")
        }
        .task { await load() }
        .onChange(of: realtime.event) { ev in
            if ev.type == "balance" || ev.type == "transfer" || ev.type == "ui" { Task { await load() } }
        }
    }

    /* ---------------------------------------------------------- 上面：金币 + 我的零钱 + 余额 */

    private var top: some View {
        VStack(spacing: 0) {
            // 黄色圆形 ¥ 图标
            ZStack {
                Circle().fill(st.circleColorV)
                Text("¥")
                    .font(pfMoney(st.yenFont))
                    .foregroundColor(st.yenColorV)
            }
            .frame(width: st.circle, height: st.circle)
            .padding(.top, st.topPad)

            Text(cfg?.title ?? "我的零钱")
                .font(pf(st.titleFont))
                .foregroundColor(Color.dyn(0x000000, 0xEDEDED))
                .padding(.top, st.gapTitleV)

            MoneyLabel(text: money(cfg?.balance ?? app.me?.balance ?? 0),
                       size: st.amountFont, curSize: st.curFont, topAlign: true,
                       color: Color.dyn(0x000000, 0xEDEDED))
                .padding(.top, st.gapAmountV)

            if let note = cfg?.note, !note.isEmpty {
                HStack(spacing: 4) {
                    Text(note).font(pf(st.noteFont)).foregroundColor(st.noteColorV)
                    Chevron(size: 6, line: 1.4, color: st.noteColorV)
                }
                .padding(.top, st.gapNoteV)
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
            Text(Tr(l.label)).font(pf(st.linkFont)).foregroundColor(st.linkColorV)
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
        case "withdraw": app.show(Tr("提现：还没接后端，先把页面做出来"))
        case "faq": showFaq = true
        default: app.show("「\(label)」还没接后端，先把页面做出来")
        }
    }

    private func doRecharge() {
        guard let amount = Double(rechargeAmount), amount > 0 else {
            app.show(Tr("金额不对"))
            return
        }
        Task {
            if let balance = try? await API.shared.recharge(amount) {
                app.me = try? await API.shared.me()
                app.show("充值成功，余额 ¥\(String(format: "%.2f", balance))")
                await load()
            } else {
                app.show(Tr("充值失败"))
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
