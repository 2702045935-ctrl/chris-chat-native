import SwiftUI

/* ============================================================
   转账这一套页面（照网页版）：
   ① 转账页：对方头像 + 转账给 XXX + 金额 + 说明 + 数字键盘 + 转账
   ② 付款方式面板：零钱 / 建设银行储蓄卡 + 充值余额
   ③ 支付密码面板：向 XX 转账 + ¥金额 + 6 位密码 + 数字键盘 + 使用面容
   ④ 结果页：✓ + 待好友确认收款 + ¥金额 + 付款方式/余额/说明 + 完成
   ============================================================ */

/// 数字键盘（转账页和支付密码面板共用）
struct NumberPad: View {
    var showDot: Bool = true
    var onKey: (String) -> Void

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 0.5) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0.5) {
                    ForEach(rows[r], id: \.self) { k in
                        key(k)
                    }
                }
            }
            HStack(spacing: 0.5) {
                if showDot {
                    key(".")
                } else {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 52)
                }
                key("0")
                Button {
                    onKey("del")
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 22))
                        .foregroundColor(C.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.dyn(0xF2F2F2, 0x2C2C2E))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func key(_ k: String) -> some View {
        Button {
            onKey(k)
        } label: {
            Text(k)
                .font(pf(26))
                .foregroundColor(C.label)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.dyn(0xF2F2F2, 0x2C2C2E))
        }
        .buttonStyle(.plain)
    }
}

/* ============================================================ 转账页 */

struct TransferView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var digits = ""
    @State private var note = ""
    @State private var noteEditing = false
    @State private var method = "balance"
    @State private var step = 0            // 0 输入金额 / 1 支付密码 / 2 结果
    @State private var password = ""
    @State private var hasPwd = false
    @State private var showMethod = false
    @State private var busy = false
    @State private var doneAmount: Double = 0

    private var amount: Double { Double(digits) ?? 0 }
    private var peerAvatar: String { chat.avatar ?? "" }
    private var selfAvatar: String { app.me?.avatarPath ?? "" }

    var body: some View {
        ZStack {
            C.cardBg.ignoresSafeArea()
            if step == 2 {
                resultPage
            } else {
                VStack(spacing: 0) {
                    header
                    amountArea
                    Spacer(minLength: 0)
                    if step == 1 { passwordArea }
                    pad
                }
            }
            if busy {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView().padding(18)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.cardBg))
                }
            }
        }
        .sheet(isPresented: $showMethod) {
            PayMethodSheet(balance: app.me?.balance ?? 0, method: $method)
        }
        .alert("转账说明", isPresented: $noteEditing) {
            TextField("选填", text: $note)
            Button("好") { }
            Button("取消", role: .cancel) { note = "" }
        }
        .task { hasPwd = await API.shared.hasPayPassword() }
    }

    /* ---------------------------------------------------------- 头部 */

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("转账给 \(chat.name)")
                    .font(pf(17, .semibold))
                    .foregroundColor(C.label)
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(pf(20, .medium))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .frame(height: L.navH)
            .padding(.top, L.safeTop)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("转账给 \(chat.name)")
                        .font(pf(17.5, .semibold))
                        .foregroundColor(C.label)
                    Text("微信号：\(chat.name)")
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                Avatar(path: peerAvatar, size: 34, radius: 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .background(Color.dyn(0xEDEDED, 0x1D1D1D))
    }

    /* ---------------------------------------------------------- 金额 */

    private var amountArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("转账金额")
                .font(pf(14))
                .foregroundColor(C.label)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 6)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("¥")
                    .font(pf(30, .medium))
                    .foregroundColor(C.label)
                Text(digits.isEmpty ? "0.00" : digits)
                    .font(pf(38, .semibold))
                    .foregroundColor(digits.isEmpty ? C.subLabel : C.label)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)

            Rectangle().fill(C.hairline).frame(height: 0.5)

            Button {
                noteEditing = true
            } label: {
                HStack {
                    Text(note.isEmpty ? "添加转账说明" : note)
                        .font(pf(15))
                        .foregroundColor(note.isEmpty ? Color.dyn(0x1E4FA3, 0x6F9BE0) : C.label)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /* ---------------------------------------------------------- 支付密码 */

    private var passwordArea: some View {
        VStack(spacing: 0) {
            Button {
                showMethod = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: method == "balance" ? "yensign.circle.fill" : "creditcard.fill")
                        .font(.system(size: 20))
                        .foregroundColor(method == "balance" ? C.green : Color(hex: 0x1677FF))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(method == "balance" ? "零钱" : "建设银行储蓄卡")
                            .font(pf(15))
                            .foregroundColor(C.label)
                        Text(method == "balance"
                             ? "¥\(String(format: "%.2f", app.me?.balance ?? 0))"
                             : "尾号 2125")
                            .font(pf(12))
                            .foregroundColor(C.subLabel)
                    }
                    Spacer(minLength: 0)
                    Text("更改").font(pf(14)).foregroundColor(C.subLabel)
                    Chevron(size: 8, line: 1.6)
                }
                .padding(.horizontal, 20)
                .frame(height: 58)
                .background(C.cardBg)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(hasPwd ? "请输入 6 位支付密码" : "没设置过支付密码，直接确认即可")
                .font(pf(13))
                .foregroundColor(C.subLabel)
                .padding(.top, 14)

            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { i in
                    ZStack {
                        Rectangle().stroke(Color.dyn(0xD9D9D9, 0x3A3A3C), lineWidth: 0.5)
                        if i < password.count {
                            Circle().fill(C.label).frame(width: 9, height: 9)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .padding(.top, 12)
            .background(C.cardBg)
        }
        .background(Color.dyn(0xEDEDED, 0x1D1D1D))
        .padding(.bottom, 8)
    }

    /* ---------------------------------------------------------- 底部键盘 */

    private var pad: some View {
        VStack(spacing: 0) {
            if step == 1 {
                HStack {
                    Button {
                        step = 0
                        password = ""
                    } label: {
                        Text("取消").font(pf(16)).foregroundColor(C.label)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        withAnimation { method = "balance" }
                        submit()
                    } label: {
                        Text("确认支付").font(pf(16)).foregroundColor(C.green)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .frame(height: 46)
                .background(C.cardBg)
            }

            if step == 0 {
                Button {
                    if hasPwd { step = 1 } else { submit() }
                } label: {
                    Text("转账  ¥\(String(format: "%.2f", amount))")
                        .font(pf(17, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(amount > 0 ? C.green : C.green.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .disabled(!(amount > 0))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            NumberPad(showDot: true) { key in
                handle(key)
            }
        }
        .background(C.cardBg)
        .ignoresSafeArea(edges: .bottom)
    }

    private func handle(_ key: String) {
        if step == 0 {
            if key == "del" {
                if !digits.isEmpty { digits.removeLast() }
            } else if key == "." {
                if !digits.contains(".") { digits = digits.isEmpty ? "0." : digits + "." }
            } else {
                if let dot = digits.firstIndex(of: ".") {
                    if digits.distance(from: dot, to: digits.endIndex) > 2 { return }
                } else if digits.count >= 7 {
                    return
                }
                digits += key
            }
        } else if step == 1 {
            if key == "del" {
                if !password.isEmpty { password.removeLast() }
            } else if key != "." {
                if password.count < 6 { password += key }
                if password.count == 6 { submit() }
            }
        }
    }

    /* ---------------------------------------------------------- 结果页 */

    private var resultPage: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 90)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(C.green)
            Text("待好友确认收款")
                .font(pf(17))
                .foregroundColor(C.label)
                .padding(.top, 14)
            Text("¥\(String(format: "%.2f", doneAmount))")
                .font(pf(34, .medium))
                .foregroundColor(C.label)
                .padding(.top, 10)

            VStack(spacing: 0) {
                resultRow("付款方式", method == "balance" ? "零钱" : "建设银行储蓄卡")
                HairLine(inset: 16)
                resultRow("余额", "¥\(String(format: "%.2f", app.me?.balance ?? 0))")
                if !note.isEmpty {
                    HairLine(inset: 16)
                    resultRow("转账说明", note)
                }
            }
            .background(C.cardBg)
            .padding(.top, 26)

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("完成")
                    .font(pf(17))
                    .foregroundColor(C.green)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(C.cardBg)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .background(C.pageBg.ignoresSafeArea())
    }

    private func resultRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(pf(15)).foregroundColor(C.subLabel)
            Spacer()
            Text(v).font(pf(15)).foregroundColor(C.label)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    /* ---------------------------------------------------------- 提交 */

    private func submit() {
        guard amount > 0 else { return }
        busy = true
        Task {
            do {
                try await API.shared.transfer(chatId: chat.id, amount: amount, note: note,
                                              method: method, password: password)
                doneAmount = amount
                app.me = try? await API.shared.me()
                step = 2
                await app.loadChats()
            } catch {
                password = ""
                app.show((error as? APIError)?.errorDescription ?? "转账失败")
            }
            busy = false
        }
    }
}

/* ============================================================ 付款方式 */

struct PayMethodSheet: View {
    let balance: Double
    @Binding var method: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState
    @State private var recharge = ""
    @State private var showRecharge = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("付款方式")) {
                    row("零钱", "¥\(String(format: "%.2f", balance))", "balance")
                    row("建设银行储蓄卡", "尾号 2125", "card")
                }
                Section {
                    Button("充值余额") { showRecharge = true }
                }
            }
            .navigationTitle("选择付款方式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
        .alert("充值余额", isPresented: $showRecharge) {
            TextField("金额", text: $recharge).keyboardType(.decimalPad)
            Button("充值") { doRecharge() }
            Button("取消", role: .cancel) { }
        }
    }

    private func row(_ name: String, _ sub: String, _ value: String) -> some View {
        Button {
            method = value
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).foregroundColor(.primary)
                    Text(sub).font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
                if method == value {
                    Image(systemName: "checkmark").foregroundColor(C.green)
                }
            }
        }
    }

    private func doRecharge() {
        guard let amount = Double(recharge), amount > 0 else { return }
        Task {
            if let b = try? await API.shared.recharge(amount) {
                app.me = try? await API.shared.me()
                app.show("充值成功，余额 ¥\(String(format: "%.2f", b))")
            }
        }
    }
}
