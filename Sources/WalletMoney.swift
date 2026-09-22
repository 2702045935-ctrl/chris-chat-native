import SwiftUI

/* ============================================================
   零钱：充值 / 提现（照微信那一套）
   · 充值：银行卡 → 零钱。大号金额 + 快捷金额 + 到账银行卡 + 绿色「充值」
   · 提现：零钱 → 银行卡。可提现余额 + 全部提现 + 手续费（0.1%，最低 0.1）+ 支付密码
   · 银行卡只存「银行名 + 末四位」
   ============================================================ */

struct RechargeView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var banks: [API.BankCard] = []
    @State private var bankId = ""
    @State private var busy = false
    @State private var showAddBank = false
    @State private var showPay = false
    @State private var done = false

    private var amount: Double { Double(amountText) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("充值"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    Text(Tr("充值金额"))
                        .font(pf(13)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 18)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("¥").font(pfMoney(28))
                        TextField("0.00", text: $amountText)
                            .font(pfMoney(44))
                            .keyboardType(.decimalPad)
                            .foregroundColor(C.label)
                    }
                    .padding(.horizontal, 20)
                    .frame(height: 66)

                    /* 快捷金额（微信也有这几个档） */
                    HStack(spacing: 10) {
                        ForEach([50, 100, 200, 500], id: \.self) { v in
                            Button {
                                amountText = "\(v)"
                            } label: {
                                Text("¥\(v)")
                                    .font(pf(15, .medium))
                                    .foregroundColor(amount == Double(v) ? .white : C.label)
                                    .frame(maxWidth: .infinity).frame(height: 40)
                                    .background(RoundedRectangle(cornerRadius: 7)
                                        .fill(amount == Double(v) ? C.green : C.cardBg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer().frame(height: 18)

                    GroupCard {
                        Button {
                            if banks.isEmpty { showAddBank = true }
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("到账银行卡")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                Text(bankLabel).font(pf(15)).foregroundColor(C.subLabel).lineLimit(1)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16).frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(Tr("充值是从银行卡转入零钱（本 App 内记账），到账立刻可用。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)

                    Spacer().frame(height: 26)

                    Button { showPay = true } label: {
                        Text(busy ? Tr("处理中…") : Tr("充值"))
                            .font(pf(17, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8).fill(amount > 0 ? C.green : C.subLabel))
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || amount <= 0)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await loadBanks() }
        .sheet(isPresented: $showAddBank) {
            BankAddSheet { list in banks = list; bankId = list.first(where: { $0.isDefault == true })?.id ?? list.first?.id ?? "" }
                .environmentObject(app)
        }
        .sheet(isPresented: $showPay) {
            PayConfirmSheet(title: Tr("充值") + " ¥" + money(amount)) { pwd, face in
                doRecharge(password: pwd, face: face)
            }
            .environmentObject(app)
        }
    }

    private var bankLabel: String {
        if let b = banks.first(where: { $0.id == bankId }) { return b.label }
        if let b = banks.first { return b.label }
        return Tr("添加银行卡")
    }

    private func loadBanks() async {
        banks = (try? await API.shared.walletBanks()) ?? []
        if bankId.isEmpty { bankId = banks.first(where: { $0.isDefault == true })?.id ?? banks.first?.id ?? "" }
    }

    private func doRecharge(password: String, face: Bool) {
        busy = true
        Task {
            do {
                let r = try await API.shared.walletRecharge(amount: amount, bankId: bankId)
                await app.refreshAll()
                busy = false
                dismiss()
                app.show(Tr("充值成功") + " ¥" + money(amount) + "，" + Tr("零钱") + " ¥" + money(r.balance ?? 0))
            } catch {
                busy = false
                app.show((error as? APIError)?.errorDescription ?? Tr("充值失败"))
            }
        }
    }
}

struct WithdrawView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var banks: [API.BankCard] = []
    @State private var bankId = ""
    @State private var busy = false
    @State private var showAddBank = false
    @State private var showPay = false
    @State private var ops: [API.WalletOp] = []

    private var amount: Double { Double(amountText) ?? 0 }
    private var balance: Double { app.me?.balance ?? 0 }
    /* 微信：每笔 0.1%，最低 0.1 元 */
    private var fee: Double { amount <= 0 ? 0 : max(0.1, (amount * 0.001 * 100).rounded() / 100) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("提现"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        Button {
                            if banks.count > 1 { switchBank() } else if banks.isEmpty { showAddBank = true }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(Tr("到账银行卡")).font(pf(16)).foregroundColor(C.label)
                                    Text(bankLabel).font(pf(12.5)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 8)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16).frame(height: 62)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)

                    Spacer().frame(height: 8)

                    GroupCard {
                        HStack(spacing: 12) {
                            Text(Tr("提现金额")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            TextField("0.00", text: $amountText)
                                .font(pfMoney(20))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .foregroundColor(C.label)
                                .frame(maxWidth: 160)
                            Button {
                                amountText = String(format: "%.2f", max(0, balance))
                            } label: {
                                Text(Tr("全部提现")).font(pf(14)).foregroundColor(C.link)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16).frame(height: 56)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(Tr("可提现余额")).font(pf(13)).foregroundColor(C.subLabel)
                            Spacer()
                            Text("¥" + money(balance)).font(pf(13)).foregroundColor(C.subLabel)
                        }
                        if amount > 0 {
                            HStack {
                                Text(Tr("服务费（0.1%，最低 ¥0.1）")).font(pf(13)).foregroundColor(C.subLabel)
                                Spacer()
                                Text("¥" + money(fee)).font(pf(13)).foregroundColor(C.subLabel)
                            }
                            HStack {
                                Text(Tr("实际到账")).font(pf(13)).foregroundColor(C.subLabel)
                                Spacer()
                                Text("¥" + money(max(0, amount))).font(pf(13)).foregroundColor(C.subLabel)
                            }
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 10)

                    Text(Tr("提现到银行卡一般是 2 小时内到账，具体以银行处理时间为准。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22).padding(.top, 10)

                    Spacer().frame(height: 22)

                    Button { showPay = true } label: {
                        Text(busy ? Tr("处理中…") : Tr("提现"))
                            .font(pf(17, .medium)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8).fill(canWithdraw ? C.green : C.subLabel))
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || !canWithdraw)

                    /* 提现记录（微信在这一页下面就有） */
                    if !ops.isEmpty {
                        HStack {
                            Text(Tr("提现记录")).font(pf(13)).foregroundColor(C.subLabel)
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 6)
                        GroupCard {
                            ForEach(ops.indices, id: \.self) { i in
                                let o = ops[i]
                                if i > 0 { HairLine(inset: 16) }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("¥" + money(o.amount ?? 0)).font(pf(16)).foregroundColor(C.label)
                                        Text((o.bankText ?? "") + " · " + (o.createdAt ?? "").prefix(16))
                                            .font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(statusText(o.status))
                                        .font(pf(13))
                                        .foregroundColor(o.status == "pending" ? C.orange : C.green)
                                }
                                .padding(.horizontal, 16).frame(height: 60)
                            }
                        }
                    }
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
        .task {
            banks = (try? await API.shared.walletBanks()) ?? []
            bankId = banks.first(where: { $0.isDefault == true })?.id ?? banks.first?.id ?? ""
            ops = (try? await API.shared.walletOps()) ?? []
        }
        .sheet(isPresented: $showAddBank) {
            BankAddSheet { list in banks = list; bankId = list.first?.id ?? "" }
                .environmentObject(app)
        }
        .sheet(isPresented: $showPay) {
            PayConfirmSheet(title: Tr("提现") + " ¥" + money(amount)) { pwd, face in
                doWithdraw(password: pwd, face: face)
            }
            .environmentObject(app)
        }
    }

    private var canWithdraw: Bool { amount >= 1 && amount + fee <= balance && !bankId.isEmpty }
    private var bankLabel: String {
        if let b = banks.first(where: { $0.id == bankId }) { return b.label }
        return banks.isEmpty ? Tr("添加银行卡") : (banks.first?.label ?? "")
    }

    private func statusText(_ s: String?) -> String {
        switch s {
        case "done": return Tr("已到账")
        case "failed": return Tr("提现失败")
        default: return Tr("处理中")
        }
    }

    private func switchBank() {
        guard let i = banks.firstIndex(where: { $0.id == bankId }) else { return }
        bankId = banks[(i + 1) % banks.count].id
    }

    private func doWithdraw(password: String, face: Bool) {
        busy = true
        Task {
            do {
                let r = try await API.shared.walletWithdraw(amount: amount, bankId: bankId,
                                                            password: password, face: face)
                await app.refreshAll()
                ops = (try? await API.shared.walletOps()) ?? ops
                amountText = ""
                busy = false
                app.show(Tr("提现申请已提交") + "：" + (r.expect ?? "") + "（" + Tr("服务费") + " ¥" + money(r.fee ?? 0) + "）")
            } catch {
                busy = false
                app.show((error as? APIError)?.errorDescription ?? Tr("提现失败"))
            }
        }
    }
}

/* 添加银行卡：只存银行名 + 末四位 */
struct BankAddSheet: View {
    var onAdded: ([API.BankCard]) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var bank = ""
    @State private var cardNo = ""
    @State private var holder = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("添加银行卡"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(busy ? Tr("保存中…") : Tr("完成"))
                        .font(pf(17)).foregroundColor(cardNo.count >= 12 ? C.green : C.subLabel)
                        .frame(height: L.navH).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(busy || cardNo.count < 12)
            }
            GroupCard {
                field(Tr("开户银行"), $bank, "招商银行")
                HairLine(inset: 16)
                field(Tr("卡号"), $cardNo, "6225 8801 2345 6789")
                HairLine(inset: 16)
                field(Tr("姓名"), $holder, "")
            }
            .padding(.top, 12)
            Text(Tr("出于安全考虑，服务器只保存银行名和卡号后四位，完整卡号不落盘。"))
                .font(pf(12.5)).foregroundColor(C.subLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 10)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }

    private func field(_ title: String, _ text: Binding<String>, _ ph: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(16)).foregroundColor(C.label).frame(width: 84, alignment: .leading)
            TextField(ph, text: text)
                .font(pf(16)).foregroundColor(C.label)
                .keyboardType(title == Tr("卡号") ? .numberPad : .default)
        }
        .padding(.horizontal, 16).frame(height: 54)
    }

    private func save() {
        busy = true
        Task {
            do {
                let list = try await API.shared.addBank(bank: bank, cardNo: cardNo, holder: holder)
                onAdded(list)
                busy = false
                dismiss()
                app.show(Tr("银行卡已添加"))
            } catch {
                busy = false
                app.show((error as? APIError)?.errorDescription ?? Tr("添加失败"))
            }
        }
    }
}

/* 支付确认：6 位支付密码（有面容的话可以点「使用面容」） */
struct PayConfirmSheet: View {
    var title: String
    var onConfirm: (String, Bool) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pwd = ""
    @State private var hasPay = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .foregroundColor(C.label).frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(title).font(pf(16, .medium)).foregroundColor(C.label)
                Spacer()
                Spacer().frame(width: 44)
            }
            .frame(height: L.navH)

            Text(Tr("请输入支付密码"))
                .font(pf(15)).foregroundColor(C.subLabel)
                .padding(.top, 18)

            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    Text(i < pwd.count ? "●" : "")
                        .font(pf(20))
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(C.cardBg)
                        .overlay(Rectangle().frame(width: 0.5).foregroundColor(C.hairline), alignment: .leading)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16)

            TextField("", text: $pwd)
                .keyboardType(.numberPad)
                .frame(height: 1).opacity(0.01)

            if Biometrics.available {
                Button {
                    dismiss()
                    onConfirm("", true)      // 面容已通过
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "faceid")
                        Text(Tr("使用面容"))
                    }
                    .font(pf(15)).foregroundColor(C.link)
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }

            Button {
                dismiss()
                onConfirm(pwd, false)
            } label: {
                Text(Tr("确认支付"))
                    .font(pf(16, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(pwd.count >= 6 ? C.green : C.subLabel))
                    .padding(.horizontal, 20)
            }
            .buttonStyle(.plain)
            .disabled(pwd.count < 6)
            .padding(.top, 20)
            Spacer()
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }
}
