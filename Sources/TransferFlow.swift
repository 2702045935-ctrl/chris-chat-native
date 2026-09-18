import SwiftUI

/* ============================================================
   转账这一套页面 —— 照网页版 .tf-* / .pay-* / .pm-* 一条条量出来的：
   ① 转账页：转账给 XX + 微信号 + 转账金额（绿色闪烁光标）+ 说明 + 数字键盘
   ② 支付面板（半屏）：× + 使用面容 / 向 XX 转账 / ¥金额 / 付款方式 + 更改 / 6 位密码 / 数字键盘
   ③ 付款方式面板（半屏）：余额 / 建设银行储蓄卡 + 充值余额
   ④ 结果页：✓ + 待好友确认收款 + ¥金额 + 付款方式/余额/说明 + 完成
   ②③ 是两个独立面板，不是一个页面。
   尺寸都能在服务器 data/ui.json 里调（tf / pay 开头那几个键）。
   ============================================================ */

/* ============================================================ 转账页
   键盘：用 iOS 原生的（金额 decimalPad / 支付密码 numberPad），
   以前那两个自己画的数字键盘已经删掉，界面外观还是微信这一套。 */

struct TransferView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var digits = ""
    @State private var note = ""
    @State private var noteEditing = false
    @State private var method = "balance"
    @State private var showPay = false
    @State private var showMethod = false
    @State private var password = ""
    @State private var hasPwd = false
    @State private var busy = false
    @State private var step = 0                 // 0 转账页 / 1 结果页
    @State private var doneAmount: Double = 0
    @State private var payHint: String?
    @State private var badPwd = false
    @State private var caretOn = true
    /// 这台手机能不能用面容/指纹（不能用就不显示那颗按钮，直接输密码）
    @State private var faceOK = false
    /// 金额输入交给原生键盘（藏起来的输入框收字，界面还是「一位一格」）
    @FocusState private var amountFocus: Bool
    /// 支付密码也交给原生键盘
    @FocusState private var payFocus: Bool

    private var amount: Double { Double(digits) ?? 0 }
    private var peerAvatar: String { chat.avatar ?? "" }
    private var balance: Double { app.me?.balance ?? 0 }
    private var methodName: String { method == "card" ? "建设银行储蓄卡" : "余额" }
    private var methodSub: String {
        method == "card" ? "尾号 2125" : "¥" + money(balance)
    }

    var body: some View {
        ZStack {
            C.cardBg.ignoresSafeArea()

            if step == 1 {
                resultPage
            } else {
                mainPage
            }

            if busy {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView().padding(18)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.cardBg))
                }
                .zIndex(30)
            }

            if showPay {
                payLayer.zIndex(10)
            }
            if showMethod {
                methodLayer.zIndex(20)
            }
        }
        .alert("转账说明", isPresented: $noteEditing) {
            TextField("选填", text: $note)
            Button("好") { }
            Button("取消", role: .cancel) { note = "" }
        }
        .task {
            hasPwd = await API.shared.hasPayPassword()
            faceOK = Biometrics.available
            // 金额后面那根绿色光标：1.05 秒一次亮灭（和网页版一样）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 525_000_000)
                caretOn.toggle()
            }
        }
    }

    /* ---------------------------------------------------------- 转账页 */

    private var mainPage: some View {
        VStack(spacing: 0) {
            head
            bodyArea
            Spacer(minLength: 0)

            /* 藏起来的输入框：负责把原生键盘敲进来的字给到 digits */
            TextField("", text: $digits)
                .keyboardType(.decimalPad)
                .focused($amountFocus)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: digits) { v in
                    let clean = sanitizeAmount(v)
                    if clean != v { digits = clean }
                }

            sendBar
        }
        /* 一进转账页原生键盘就弹出来（和微信一样） */
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 320_000_000)
                amountFocus = true
            }
        }
    }

    /// 底部绿色「转账」按钮（原生键盘上面那颗）
    private var sendBar: some View {
        Button {
            amountFocus = false
            openPay()
        } label: {
            Text("转账")
                .font(pf(17.5, .medium))
                .foregroundColor(amount > 0 ? .white : Color.dyn(0x9A9A9A, 0x8A8A8E))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(amount > 0 ? C.green : Color.dyn(0xDCDCDC, 0x3A3A3C)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(amount <= 0)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var head: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("")
                HStack {
                    Button { dismiss() } label: {
                        SVGIcon(markup: I.backCover, size: 20, color: C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .frame(height: L.navH)

            HStack(spacing: L.v(10, 3.2, 13)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("转账给 \(chat.name)")
                        .font(pf(17.5, .semibold))
                        .foregroundColor(C.label)
                    Text("微信号：\(chat.name)")
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                Avatar(path: peerAvatar, size: L.tfAvatar, radius: 6)
            }
            .padding(.top, L.v(10, 4.8, 20))
            .padding(.horizontal, L.v(16, 5, 20))
            .padding(.bottom, L.v(12, 4.4, 18))
        }
        .background(Color.dyn(0xEDEDED, 0x1D1D1D))
    }

    private var bodyArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("转账金额")
                .font(pf(14.5))
                .foregroundColor(C.label)
                .padding(.horizontal, L.v(16, 5, 20))
                .padding(.top, L.v(10, 4, 16))
                .padding(.bottom, L.v(4, 1.4, 6))

            HStack(alignment: .center, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("¥")
                        .font(pfMoney(L.tfCnySize))
                        .foregroundColor(C.label)
                    digitCells
                }
                if caretOn {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(C.green)
                        .frame(width: L.tfCaretW, height: L.tfCaretH)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, L.v(4, 1.4, 7))
            .padding(.horizontal, L.v(16, 5, 20))
            .padding(.bottom, L.v(10, 3.4, 15))
            .overlay(alignment: .bottom) {
                Rectangle().fill(C.hairline).frame(height: 0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture { amountFocus = true }

            HStack(alignment: .top, spacing: 5) {
                Text("¥")
                    .font(pfMoney(L.tfCnySize))
                    .foregroundColor(.clear)
                unitCells
                Spacer(minLength: 0)
            }
            .padding(.top, L.v(2, 1, 4))
            .padding(.horizontal, L.v(16, 5, 20))

            Button {
                noteEditing = true
            } label: {
                Text(note.isEmpty ? "添加转账说明" : note)
                    .font(pf(16.5))
                    .foregroundColor(Color.dyn(0x1E4FA3, 0x6F9BE0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, L.v(10, 3.4, 16))
                    .padding(.horizontal, L.v(16, 5, 20))
                    .padding(.bottom, L.v(14, 4.4, 18))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 金额数字：一位一格（网页里每格 28 宽、42 号字，和下面单位行对齐）
    private var digitCells: some View {
        let chars = Array(digits)
        return HStack(spacing: 0) {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i]))
                    .font(pf(L.tfDigitSize, .semibold))
                    .foregroundColor(C.label)
                    .frame(width: L.tfCellW)
            }
            if digits.isEmpty { Color.clear.frame(width: L.tfCellW, height: 1) }
        }
    }

    /// 下划线下面那排单位（千 / 万 / 十万 / 百万），只在第一位数字下面显示
    private var unitCells: some View {
        let chars = Array(digits)
        return HStack(spacing: 0) {
            ForEach(chars.indices, id: \.self) { i in
                Text(unit(at: i, in: chars))
                    .font(pf(L.tfUnitSize))
                    .foregroundColor(Color(hex: 0xB8B8B8))
                    .lineLimit(1)
                    .frame(width: L.tfCellW)
            }
            if chars.isEmpty { Color.clear.frame(width: L.tfCellW, height: 1) }
        }
    }

    private func unit(at i: Int, in chars: [Character]) -> String {
        guard i < chars.count else { return "" }
        if chars[i] == "." { return "" }
        if chars[0..<i].contains(where: { $0 != "." }) { return "" }
        let intLen = digits.split(separator: ".").first?.count ?? 0
        switch intLen {
        case 5: return "万"
        case 6: return "十万"
        default: return intLen >= 7 ? "百万" : "千"
        }
    }

    /* ---------------------------------------------------------- 金额输入 */

    /// 原生键盘敲进来的东西过一遍：只留数字和一个小数点、最多两位小数、最多 10 位
    private func sanitizeAmount(_ raw: String) -> String {
        var out = ""
        var seenDot = false
        var decimals = 0
        for ch in raw {
            if ch >= "0" && ch <= "9" {
                if seenDot {
                    if decimals >= 2 { continue }
                    decimals += 1
                }
                out.append(ch)
            } else if ch == "." || ch == "," {
                if seenDot { continue }
                seenDot = true
                out.append(".")
            }
        }
        return out.count > 10 ? String(out.prefix(10)) : out
    }

    private func openPay() {
        guard amount > 0 else { app.show("请先输入转账金额"); return }
        password = ""
        payHint = nil
        badPwd = false
        withAnimation(.easeOut(duration: 0.26)) { showPay = true }
        Task {
            hasPwd = await API.shared.hasPayPassword()
            app.me = try? await API.shared.me()
        }
    }

    /* ---------------------------------------------------------- ② 支付面板 */

    private var payLayer: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { closePay() }

            VStack(spacing: 0) {
                // 头部：× 和「使用面容」
                HStack {
                    Button { closePay() } label: {
                        SVGIcon(markup: payClose, size: L.v(13, 3.6, 15), color: C.label)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, -6)
                    Spacer()
                    if faceOK {
                        Button {
                            facePay()
                        } label: {
                            Text(Biometrics.label)
                                .font(pf(14.3))
                                .foregroundColor(C.link)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, L.v(14, 4.3, 18))
                .frame(height: L.payHeadH)

                Text("向 \(chat.name)转账")
                    .font(pf(15.5))
                    .foregroundColor(C.label)
                    .padding(.top, L.v(9, 3.1, 13))

                Text("¥" + money(amount))
                    .font(pfMoney(38))
                    .foregroundColor(C.label)
                    .padding(.top, 2)

                // 付款方式 + 更改
                HStack {
                    Text("付款方式")
                        .font(pf(13.5))
                        .foregroundColor(Color.dyn(0x6E6E6E, 0x8F8F8F))
                    Spacer()
                    Button {
                        showMethod = true
                    } label: {
                        HStack(spacing: 2) {
                            Text("更改").font(pf(13.5))
                            SVGIcon(markup: payChev, size: 12, color: Color.dyn(0x6E6E6E, 0x8F8F8F))
                        }
                        .foregroundColor(Color.dyn(0x6E6E6E, 0x8F8F8F))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, L.v(16, 5.7, 24))
                .padding(.top, L.v(22, 7.6, 32))

                // 当前付款方式那一块
                Button {
                    showMethod = true
                } label: {
                    HStack(spacing: L.v(8, 2.6, 11)) {
                        SVGIcon(markup: method == "card" ? payCardIcon : payBalanceIcon,
                                size: L.v(21, 5.8, 25), color: method == "card" ? Color(hex: 0x1677FF) : C.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(methodName)
                                .font(pf(13.8))
                                .foregroundColor(C.label)
                            Text(methodSub)
                                .font(pf(12.8))
                                .foregroundColor(Color.dyn(0x3F3F3F, 0xB9C2CC))
                        }
                        Spacer(minLength: 0)
                        SVGIcon(markup: payTick, size: L.v(15, 4.2, 17.5), color: C.green)
                    }
                    .padding(.horizontal, L.v(12, 4, 16))
                    .frame(height: L.v(56, 16, 66))
                    .background(RoundedRectangle(cornerRadius: L.v(9, 2.9, 12))
                        .fill(Color.dyn(0xEAF3FC, 0x1B2A3D)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, L.v(16, 5.7, 24))
                .padding(.top, L.v(6, 2.6, 11))

                // 6 位支付密码
                VStack(spacing: L.v(12, 3.8, 16)) {
                    HStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { i in
                            ZStack {
                                if i > 0 {
                                    Rectangle()
                                        .fill(Color.dyn(0xECECEC, 0x3A3A3C))
                                        .frame(width: 1)
                                        .frame(maxHeight: .infinity)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if i < password.count {
                                    Circle()
                                        .fill(C.label)
                                        .frame(width: L.v(8, 2.5, 10.5), height: L.v(8, 2.5, 10.5))
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: L.payPwdW, height: L.payPwdH)
                    .background(C.cardBg)
                    .overlay(RoundedRectangle(cornerRadius: L.v(8, 2.6, 11))
                        .stroke(badPwd ? Color(hex: 0xE5484D) : Color.dyn(0xD8D8D8, 0x3A3A3C), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: L.v(8, 2.6, 11)))
                    .offset(x: badPwd ? -6 : 0)
                    .animation(.default, value: badPwd)
                    /* 点这 6 个格子也能把原生键盘唤出来 */
                    .contentShape(Rectangle())
                    .onTapGesture { payFocus = true }

                    if let hint = payHint {
                        Text(hint)
                            .font(pf(13.5))
                            .foregroundColor(Color(hex: 0xE5484D))
                    } else if !hasPwd {
                        Button {
                            submit(face: false)
                        } label: {
                            Text("还没设置支付密码，点这里直接支付")
                                .font(pf(13.5))
                                .foregroundColor(C.link)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(amount > balance ? "余额只剩 ¥\(money(balance))，点这里去充值" : "请输入 6 位支付密码")
                            .font(pfMoney(13.5))
                            .foregroundColor(amount > balance ? C.link : C.subLabel)
                    }
                }
                .padding(.top, L.v(24, 8.4, 35))

                /* 支付密码也用原生键盘：藏起来的输入框收字 */
                TextField("", text: $password)
                    .keyboardType(.numberPad)
                    .focused($payFocus)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .onChange(of: password) { v in
                        let clean = String(v.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        if clean != v { password = clean; return }
                        payHint = nil
                        if clean.count == 6 && !busy { payFocus = false; submit(face: false) }
                    }
                    .onAppear { focusPaySoon() }
                    .padding(.top, L.v(12, 5.5, 23))

                Rectangle()
                    .fill(Color.dyn(0xEDEDED, 0x232325))
                    .frame(height: max(34, L.safeBottom))
            }
            .background(C.cardBg)
            .clipShape(TopRounded(radius: L.paySheetRadius))
        }
    }

    /// 支付面板一出来就弹原生键盘。
    /// 以前这里是「设过支付密码才弹」——结果没设密码的号（比如 friend001）进来一个键盘都没有，
    /// 看着就像面板坏了。现在不管有没有密码都弹，跟网页版一致。
    /// 半屏面板有进场动画，刚出现时抢焦点偶尔会被系统吞掉，所以隔几拍补两次。
    private func focusPaySoon() {
        Task {
            payFocus = true
            for delay in [280_000_000, 480_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(delay))
                if Task.isCancelled { return }
                if !payFocus && password.isEmpty { payFocus = true }
            }
        }
    }

    private func closePay() {
        payFocus = false
        withAnimation(.easeOut(duration: 0.22)) {
            showPay = false
            showMethod = false
        }
        password = ""
        payHint = nil
        badPwd = false
    }

    /* ---------------------------------------------------------- ③ 付款方式面板 */

    private var methodLayer: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.22)) { showMethod = false }
                }

            VStack(spacing: 0) {
                ZStack {
                    Text("选择付款方式")
                        .font(pf(16.5, .semibold))
                        .foregroundColor(C.label)
                    HStack {
                        Button {
                            withAnimation(.easeOut(duration: 0.22)) { showMethod = false }
                        } label: {
                            SVGIcon(markup: payClose, size: L.v(13, 3.6, 15), color: C.label)
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    .padding(.leading, L.v(10, 3.4, 14))
                }
                .frame(height: L.payHeadH)

                VStack(spacing: 10) {
                    methodRow("balance", "余额", "¥" + money(balance))
                    methodRow("card", "建设银行储蓄卡", "尾号 2125")
                }
                .padding(.horizontal, L.v(12, 3.8, 16))
                .padding(.bottom, L.v(10, 3, 14))

                Button {
                    recharge()
                } label: {
                    Text("充值余额")
                        .font(pf(14.5))
                        .foregroundColor(C.link)
                        .frame(maxWidth: .infinity)
                        .frame(height: L.v(44, 12.4, 50))
                        .background(RoundedRectangle(cornerRadius: L.v(9, 2.9, 12))
                            .fill(Color.dyn(0xEDEDED, 0x111111)))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, L.v(12, 3.8, 16))

                Rectangle()
                    .fill(Color.dyn(0xEDEDED, 0x232325))
                    .frame(height: max(34, L.safeBottom))
            }
            .background(C.cardBg)
            .clipShape(TopRounded(radius: L.paySheetRadius))
        }
    }

    private func methodRow(_ key: String, _ name: String, _ sub: String) -> some View {
        Button {
            method = key
            withAnimation(.easeOut(duration: 0.22)) { showMethod = false }
            app.show("付款方式：" + (key == "card" ? "建设银行储蓄卡" : "余额 ¥" + money(balance)))
        } label: {
            HStack(spacing: L.v(8, 2.6, 11)) {
                SVGIcon(markup: key == "card" ? payCardIcon : payBalanceIcon,
                        size: L.v(21, 5.8, 25),
                        color: key == "card" ? Color(hex: 0x1677FF) : C.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(pf(14)).foregroundColor(C.label)
                    Text(sub).font(pf(12.8)).foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                SVGIcon(markup: payTick, size: L.v(15, 4.2, 17.5), color: C.green)
                    .opacity(method == key ? 1 : 0)
            }
            .padding(.horizontal, L.v(12, 3.8, 15))
            .frame(height: L.v(56, 16, 64))
            .background(RoundedRectangle(cornerRadius: L.v(9, 2.9, 12))
                .fill(method == key ? Color.dyn(0xEAF3FC, 0x1B2A3D) : Color.dyn(0xEDEDED, 0x111111)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recharge() {
        Task {
            if let b = try? await API.shared.recharge(500) {
                app.me = try? await API.shared.me()
                app.show("充值成功，余额 ¥\(money(b))")
            }
        }
    }

    /* ---------------------------------------------------------- ④ 结果页 */

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
            Text("¥" + money(doneAmount))
                .font(pfMoney(34))
                .foregroundColor(C.label)
                .padding(.top, 10)

            VStack(spacing: 0) {
                resultRow("付款方式", methodName)
                HairLine(inset: 16)
                resultRow("余额", "¥" + money(balance))
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

    /// 「使用面容」：先让系统真的验一次脸/指纹，过了才把 face=true 发给服务器
    private func facePay() {
        guard amount > 0 else { app.show("请先输入转账金额"); return }
        Task {
            let r = await Biometrics.authenticate(
                reason: "验证身份，向 \(chat.name) 转账 ¥\(money(amount))")
            if r.ok {
                payHint = nil
                submit(face: true)
            } else if !r.message.isEmpty {
                payHint = r.message                      // 失败就提示，让他直接输密码
                payFocus = true
            }
        }
    }

    private func submit(face: Bool) {
        guard amount > 0 else { return }
        if !face && hasPwd && password.count < 6 {
            payHint = "请输入 6 位支付密码"
            return
        }
        busy = true
        payHint = nil
        Task {
            do {
                try await API.shared.transfer(chatId: chat.id, amount: amount, note: note,
                                              method: method, password: password, face: face)
                doneAmount = amount
                app.me = try? await API.shared.me()
                password = ""
                withAnimation(.easeOut(duration: 0.2)) { showPay = false }
                step = 1
                await app.loadChats()
            } catch {
                password = ""
                badPwd = true
                payHint = (error as? APIError)?.errorDescription ?? "转账失败"
                if hasPwd { payFocus = true }          // 密码错了：键盘留着，直接重输
                try? await Task.sleep(nanoseconds: 420_000_000)
                badPwd = false
            }
            busy = false
        }
    }
}

/* ============================================================ 小零件 */

/// 只把上面两个角切圆（半屏面板用）
struct TopRounded: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 面板右上角那个「×」
let payClose = """
<svg data-key="pay.close" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.3" stroke-linecap="round"><path d="M5.8 5.8l12.4 12.4M18.2 5.8L5.8 18.2"/></svg>
"""

/// 付款方式右边的「›」
let payChev = """
<svg data-key="pay.chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.8 5.6l6.4 6.4-6.4 6.4"/></svg>
"""

/// 付款方式选中的那个绿勾
let payTick = """
<svg data-key="pay.tick" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.9 12.7l4.7 4.7 9.5-10.4"/></svg>
"""

/// 余额（零钱）图标
let payBalanceIcon = """
<svg data-key="pay.balance" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.6"/><path d="M12 6.6v10.8M9.4 9.2h4.2a2.1 2.1 0 0 1 0 4.2H9.4h4.6a2.1 2.1 0 0 1 0 4.2H9.4"/></svg>
"""

/// 银行卡图标
let payCardIcon = """
<svg data-key="pay.card" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.2" y="5.6" width="17.6" height="12.8" rx="2.6"/><path d="M3.2 10.2h17.6"/><path d="M6.6 14.6h3.4"/></svg>
"""

/// ¥0.00 这种金额写法
func money(_ v: Double) -> String {
    String(format: "%.2f", v)
}
