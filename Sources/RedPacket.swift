import SwiftUI

/* ============================================================
   红包（微信那一套）
   · 聊天里那张卡片：橙色的可以点开，领过/领完/过期都变淡
   · 发红包：金额 + 个数（群聊）+ 祝福语 + 拼手气/普通 → 支付密码
   · 拆红包：点「开」才进零钱，显示抢到多少
   · 详情：谁抢了多少、手气最佳
   ============================================================ */

struct RedPacketInfo: Identifiable {
    var id = ""
    var total: Double = 0
    var count = 1
    var claimedCount = 0
    var claimedIds: [String] = []
    var type = "normal"
    var note = ""
    var status = "pending"
    var expired = false
    var fromId = ""
    var fromName = ""
    var expiresAt: Double = 0
    var refundAmount: Double = 0

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        total = num(o["total"])
        count = max(1, Int(num(o["count"], 1)))
        claimedCount = Int(num(o["claimedCount"], 0))
        claimedIds = (o["claimedIds"] as? [String]) ?? []
        type = (o["type"] as? String) ?? "normal"
        note = (o["note"] as? String) ?? "恭喜发财，大吉大利"
        status = (o["status"] as? String) ?? "pending"
        /* 老版本那条「一对一红包」的消息（服务器上已经删掉那套逻辑）：
           status 是 received，这里当成已结束画，不要当成还能抢 */
        if status == "received" { status = "done"; expired = true }
        expired = (o["expired"] as? Bool) ?? (status == "refunded")
        fromId = (o["fromId"] as? String) ?? ""
        fromName = (o["fromName"] as? String) ?? ""
        expiresAt = num(o["expiresAt"])
        refundAmount = num(o["refundAmount"])
    }

    init(raw: API.RedPacketRaw) {
        id = raw.id
        total = raw.total ?? 0
        count = max(1, raw.count ?? 1)
        claimedCount = raw.claimedCount ?? 0
        claimedIds = raw.claimedIds ?? []
        type = raw.type ?? "normal"
        note = raw.note ?? "恭喜发财，大吉大利"
        status = raw.status ?? "pending"
        expired = raw.expired ?? (status == "refunded")
        fromId = raw.fromId ?? ""
        fromName = raw.fromName ?? ""
        expiresAt = raw.expiresAt ?? 0
        refundAmount = raw.refundAmount ?? 0
    }

    private func num(_ v: Any?, _ fallback: Double = 0) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        return fallback
    }

    var isLucky: Bool { type == "lucky" }
    func claimed(by uid: String) -> Bool { claimedIds.contains(uid) }
    /// 还有没有得抢（群里别人还能抢）
    var stillOpen: Bool { !expired && status == "pending" && claimedCount < count }
    /// 抢完了 / 过期了
    var isOver: Bool { !stillOpen }
    /// 剩下多久过期（小时）
    var hoursLeft: Int {
        guard expiresAt > 0 else { return 0 }
        return max(0, Int((expiresAt / 1000 - Date().timeIntervalSince1970) / 3600))
    }
}

/* ============================================================ 聊天里的红包卡片 */
struct RedPacketCard: View {
    let info: RedPacketInfo
    let mine: Bool
    let myId: String

    private var claimedByMe: Bool { info.claimed(by: myId) }
    /// 领过 / 领完 / 过期 → 淡色（微信就是这样变淡的）
    private var pale: Bool { claimedByMe || info.isOver }

    private var stateText: String {
        if claimedByMe { return "已领取" }
        if info.expired { return "已过期" }
        if info.isOver { return "红包已被领完" }
        return "领取红包"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RedPacketGlyph(pale: pale)
                    .frame(width: 30, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.note.isEmpty ? "恭喜发财，大吉大利" : info.note)
                        .font(pf(15.5, .medium))
                        .foregroundColor(pale ? Color.white.opacity(0.92) : .white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if info.count > 1 {
                        Text("共 \(info.count) 个")
                            .font(pf(11.5))
                            .foregroundColor(Color.white.opacity(0.75))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(height: 0.5)

            HStack(spacing: 6) {
                Text(info.isLucky ? "拼手气红包" : "普通红包")
                    .font(pf(11.5))
                    .foregroundColor(Color.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(stateText)
                    .font(pf(12.5))
                    .foregroundColor(pale ? Color.white.opacity(0.9) : .white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .frame(width: 236, alignment: .leading)
        .background(
            LinearGradient(colors: pale
                           ? [Color(hex: 0xF7BE8F), Color(hex: 0xF0AE79)]
                           : [Color(hex: 0xFA9D3C), Color(hex: 0xF2882A)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 红包图标：红封套 + 中间一个金色小圆（微信卡片左边那个）
struct RedPacketGlyph: View {
    var pale = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .fill(Color(hex: 0xE95A45))
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    )
                    .opacity(pale ? 0.85 : 1)
                /* 封套那一撇 */
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.34))
                    p.addQuadCurve(to: CGPoint(x: w, y: h * 0.34),
                                   control: CGPoint(x: w / 2, y: h * 0.62))
                }
                .stroke(Color.white.opacity(0.9), lineWidth: 1.4)
                Circle()
                    .fill(Color(hex: 0xF7C948))
                    .frame(width: w * 0.34, height: w * 0.34)
                    .offset(y: h * 0.42)
            }
        }
    }
}

/* ============================================================ 发红包 */
struct RedPacketSendView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let chat: Chat
    var onSent: ((RedPacketInfo) -> Void)? = nil

    @State private var amountText = ""
    @State private var countText = "1"
    @State private var note = "恭喜发财，大吉大利"
    @State private var lucky = true
    @State private var busy = false
    @State private var showPay = false
    @State private var errorText = ""
    @State private var myBalance: Double = 0
    /// 余额有没有从服务器拿到（没拿到就别用 0 去拦人，交给服务器判断）
    @State private var balanceLoaded = false

    private var isGroup: Bool { chat.type == "group" }
    private var amount: Double { Double(amountText) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: isGroup ? "发红包" : "发红包", back: { dismiss() }) {
                Text(LuckLabel.text(isLucky: lucky))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .frame(height: L.navH)
                    .padding(.trailing, 16)
            }

            ScrollView {
                VStack(spacing: 0) {
                    /* 顶部：红包那种红黄渐变条（微信发红包页顶部是红的） */
                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("¥").font(pf(22, .medium)).foregroundColor(.white)
                            Text(amountText.isEmpty ? "0.00" : amountText)
                                .font(pfMoney(38, .medium))
                                .foregroundColor(.white)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                        }
                        Text("零钱余额 ¥\(String(format: "%.2f", myBalance))")
                            .font(pf(12.5))
                            .foregroundColor(Color.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(LinearGradient(colors: [Color(hex: 0xF0563C), Color(hex: 0xE23B2E)],
                                               startPoint: .top, endPoint: .bottom))

                    GroupCard {
                        HStack(spacing: 12) {
                            Text("金额").font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            TextField("0.00", text: $amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(pfMoney(17))
                                .frame(maxWidth: 160)
                            Text("元").font(pf(15)).foregroundColor(C.label)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 54)

                        if isGroup {
                            HairLine(inset: 16)
                            HStack(spacing: 12) {
                                Text("个数").font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                TextField("1", text: $countText)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(pfMoney(17))
                                    .frame(maxWidth: 160)
                                Text("个").font(pf(15)).foregroundColor(C.label)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 54)
                        }

                        HairLine(inset: 16)
                        HStack(spacing: 12) {
                            Text("祝福语").font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            TextField("恭喜发财，大吉大利", text: $note)
                                .multilineTextAlignment(.trailing)
                                .font(pf(15))
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 54)
                    }
                    .padding(.top, 10)

                    if isGroup {
                        GroupCard {
                            Picker("", selection: $lucky) {
                                Text("拼手气红包").tag(true)
                                Text("普通红包").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .padding(.top, 10)
                    }

                    Text(helpText)
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)

                    Button {
                        self.submit()
                    } label: {
                        Text(busy ? "正在发…" : "塞钱进红包")
                            .font(pf(17, .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.red))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 22)
                    .disabled(busy)

                    Color.clear.frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if let me = app.me, let b = me.balance { myBalance = b; balanceLoaded = true }
            if let m = try? await API.shared.me() {
                app.me = m
                myBalance = m.balance ?? 0
                balanceLoaded = true
            }
        }
        .sheet(isPresented: $showPay) {
            PayPasswordSheet(amount: amount, purpose: "发红包") { pwd, face in
                try await send(password: pwd, face: face)
            } onDone: { info in
                showPay = false
                onSent?(info)
                dismiss()
            }
            .environmentObject(app)
        }
    }

    private var helpText: String {
        if !isGroup { return "单聊红包只能发 1 个；对方点开就进他的零钱。" }
        return lucky
            ? "拼手气红包：总金额随机分给每个人，谁抢多少看运气。24 小时没抢完，剩下的自动退回。"
            : "普通红包：每个人抢到的金额一样。24 小时没抢完，剩下的自动退回。"
    }

    private func submit() {
        errorText = ""
        guard amount > 0 else { app.show("先填金额"); return }
        if isGroup {
            let n = Int(countText) ?? 0
            guard n >= 1 && n <= 100 else { app.show("个数填 1~100"); return }
            if amount < Double(n) * 0.01 { app.show("每个红包最少 0.01 元"); return }
            if !lucky {
                let each = (amount / Double(n) * 100).rounded() / 100
                if abs(each * Double(n) - amount) > 0.005 {
                    app.show("普通红包要能平分：\(n) 个 × \(String(format: "%.2f", each)) 元")
                    return
                }
            }
        }
        if balanceLoaded && amount > myBalance {
            app.show("零钱不够：这个红包要 ¥\(String(format: "%.2f", amount))，你只有 ¥\(String(format: "%.2f", myBalance))。去「我 → 服务 → 钱包 → 零钱 → 充值」")
            return
        }
        showPay = true
    }

    private func send(password: String, face: Bool) async throws -> RedPacketInfo {
        busy = true
        defer { busy = false }
        let n = isGroup ? max(1, min(100, Int(countText) ?? 1)) : 1
        let r = try await API.shared.sendRedPacket(
            chatId: chat.id, amount: amount, count: n,
            type: (isGroup && lucky) ? "lucky" : "normal",
            note: note.isEmpty ? "恭喜发财，大吉大利" : note,
            password: password, face: face)
        myBalance = r.balance
        if var me = app.me { me.balance = r.balance; app.me = me }
        return RedPacketInfo(raw: r.redpacket)
    }
}

enum LuckLabel {
    static func text(isLucky: Bool) -> String { isLucky ? "拼手气红包" : "普通红包" }
}

/* ============================================================ 支付密码（发红包前确认） */
struct PayPasswordSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let amount: Double
    var purpose: String = "支付"
    /// 真正付钱的动作（抛错就是失败）
    let pay: (String, Bool) async throws -> RedPacketInfo
    let onDone: (RedPacketInfo) -> Void

    @State private var password = ""
    @State private var hasPwd = true
    @State private var faceOK = false
    @State private var busy = false
    @State private var tip = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }

            Text(purpose)
                .font(pf(15))
                .foregroundColor(C.subLabel)
            Text("¥\(String(format: "%.2f", amount))")
                .font(pfMoney(32, .medium))
                .foregroundColor(C.label)
                .padding(.top, 6)

            if hasPwd {
                /* 6 个格子 + 自带数字键盘：
                   以前用「藏起来的输入框 + 系统键盘」，在真机上经常不弹键盘，
                   表现就是「塞钱进红包」按了没反应 —— 现在不依赖系统键盘。 */
                HStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { i in
                        ZStack {
                            Rectangle().fill(C.cardBg)
                            if password.count > i {
                                Circle().fill(C.label).frame(width: 8, height: 8)
                            }
                        }
                        .frame(height: 46)
                        .overlay(Rectangle().stroke(C.hairline, lineWidth: 0.5))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 24)
                .padding(.top, 16)

                keypad
                    .padding(.top, 10)
            } else {
                /* 没设过支付密码：直接确认就行（服务器也是这个规则） */
                Text("你还没设支付密码，点下面就能直接付（想设密码：我 → 设置 → 账号与安全 → 支付密码）")
                    .font(pf(13.5))
                    .foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 26)
                    .padding(.top, 16)
                Button { run(face: false) } label: {
                    Text(busy ? "正在付…" : "确认支付 ¥\(String(format: "%.2f", amount))")
                        .font(pf(17, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .disabled(busy)
            }

            if !tip.isEmpty {
                Text(tip).font(pf(13)).foregroundColor(C.red).padding(.top, 10)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            if faceOK {
                Button { run(face: true) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "faceid").font(.system(size: 15, weight: .semibold))
                        Text("使用面容")
                    }
                    .font(pf(15, .medium))
                    .foregroundColor(C.green)
                    .frame(height: 40)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        .background(C.pageBg.ignoresSafeArea())
        .presentationDetents([.height(hasPwd ? 452 : 300)])
        .task {
            hasPwd = await API.shared.hasPayPassword()
            faceOK = Biometrics.available
        }
    }

    /// 自带数字键盘（1~9 / 0 / 删除），输满 6 位自动付
    private var keypad: some View {
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
        return VStack(spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { c in
                        let key = rows[r][c]
                        Button {
                            tap(key)
                        } label: {
                            Text(key)
                                .font(pf(24, .medium))
                                .foregroundColor(C.label)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(C.cardBg)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(key.isEmpty)
                    }
                }
                .overlay(Rectangle().stroke(C.hairline, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 12)
    }

    private func tap(_ key: String) {
        if busy { return }
        if key == "⌫" {
            if !password.isEmpty { password.removeLast() }
            tip = ""
            return
        }
        guard !key.isEmpty, password.count < 6 else { return }
        password.append(key)
        tip = ""
        if password.count == 6 { run(face: false) }
    }

    private func run(face: Bool) {
        if !face && hasPwd && password.count < 6 { return }
        busy = true
        tip = ""
        Task {
            do {
                let info = try await pay(password, face)
                busy = false
                onDone(info)
            } catch {
                busy = false
                password = ""
                tip = (error as? LocalizedError)?.errorDescription ?? "支付失败，再试一次"
            }
        }
    }
}

/* ============================================================ 拆红包 */
struct RedPacketOpenView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let info: RedPacketInfo
    let myId: String
    var onSeeDetail: ((String) -> Void)? = nil

    @State private var opened = false
    @State private var amount: Double = 0
    @State private var busy = false
    @State private var tip = ""
    @State private var spin = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xE4553C), Color(hex: 0xB8381F)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Text(info.fromName.isEmpty ? "好友" : info.fromName)
                        .font(pf(17, .medium))
                        .foregroundColor(Color(hex: 0xF7DFA0))
                    Text("给你发了一个\(info.isLucky ? "拼手气" : "")红包")
                        .font(pf(14))
                        .foregroundColor(Color(hex: 0xF7DFA0).opacity(0.85))
                }

                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(hex: 0xFFE9B0), Color(hex: 0xE9B84C)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 116, height: 116)
                    Circle()
                        .stroke(Color(hex: 0xFFF3CF).opacity(0.7), lineWidth: 2)
                        .frame(width: 132, height: 132)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                    if opened {
                        Text("¥\(String(format: "%.2f", amount))")
                            .font(pfMoney(30, .medium))
                            .foregroundColor(Color(hex: 0x8A3A12))
                    } else {
                        Button { open() } label: {
                            Text(busy ? "…" : "开")
                                .font(pf(30, .semibold))
                                .foregroundColor(Color(hex: 0x8A3A12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 34)
                .onAppear {
                    withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true }
                }

                if opened {
                    VStack(spacing: 6) {
                        Text("已存入零钱")
                            .font(pf(13))
                            .foregroundColor(Color(hex: 0xF7DFA0).opacity(0.9))
                        Button {
                            dismiss()
                            onSeeDetail?(info.id)
                        } label: {
                            Text("看看大家的手气")
                                .font(pf(15, .medium))
                                .foregroundColor(Color(hex: 0x8A3A12))
                                .padding(.horizontal, 22)
                                .frame(height: 40)
                                .background(Capsule().fill(Color(hex: 0xF7DFA0)))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                    }
                    .padding(.top, 24)
                } else if !tip.isEmpty {
                    Text(tip).font(pf(13.5)).foregroundColor(Color(hex: 0xF7DFA0)).padding(.top, 20)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func open() {
        if busy { return }
        busy = true
        tip = ""
        Task {
            do {
                let r = try await API.shared.claimRedPacket(id: info.id)
                amount = r.amount
                if var me = app.me { me.balance = r.balance; app.me = me }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { opened = true }
            } catch {
                tip = (error as? LocalizedError)?.errorDescription ?? "没抢到，看看详情"
            }
            busy = false
        }
    }
}

/* ============================================================ 红包详情 */
struct RedPacketDetailView: View {
    @ObservedObject private var lang = LangStore.shared
    @Environment(\.dismiss) private var dismiss

    let id: String
    let myId: String

    @State private var raw: API.RedPacketRaw?
    @State private var loading = true

    private var info: RedPacketInfo? { raw.map { RedPacketInfo(raw: $0) } }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "红包详情", back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    if let info = info {
                        VStack(spacing: 8) {
                            RPAvatar(path: raw?.fromAvatar ?? "", size: 44)
                            Text(info.fromName.isEmpty ? "好友" : info.fromName)
                                .font(pf(15, .medium))
                                .foregroundColor(C.label)
                            Text(info.note.isEmpty ? "恭喜发财，大吉大利" : info.note)
                                .font(pf(14))
                                .foregroundColor(C.subLabel)
                            Text(summaryLine(info))
                                .font(pf(13))
                                .foregroundColor(C.subLabel)
                                .padding(.top, 2)
                            if let mine = raw?.claims?.first(where: { $0.userId == myId }) {
                                Text("我抢到 ¥\(String(format: "%.2f", mine.amount))")
                                    .font(pf(15, .medium))
                                    .foregroundColor(C.red)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(LinearGradient(colors: [Color(hex: 0xFBEFD8), Color(hex: 0xF7E2C0)],
                                                   startPoint: .top, endPoint: .bottom))

                        GroupCard {
                            let list = raw?.claims ?? []
                            if list.isEmpty {
                                Text("还没有人抢到这个红包")
                                    .font(pf(14))
                                    .foregroundColor(C.subLabel)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 26)
                            } else {
                                ForEach(Array(list.enumerated()), id: \.offset) { idx, c in
                                    if idx > 0 { HairLine(inset: 62) }
                                    HStack(spacing: 12) {
                                        RPAvatar(path: c.avatar ?? "", size: 34)
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(c.name ?? "好友")
                                                    .font(pf(15))
                                                    .foregroundColor(C.label)
                                                if let best = raw?.bestUserId, best == c.userId, list.count > 1 {
                                                    Text("手气最佳")
                                                        .font(pf(10.5))
                                                        .foregroundColor(.white)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1.5)
                                                        .background(Capsule().fill(Color(hex: 0xE2A03C)))
                                                }
                                            }
                                            Text(rpTime(c.at ?? ""))
                                                .font(pf(12))
                                                .foregroundColor(C.subLabel)
                                        }
                                        Spacer(minLength: 8)
                                        Text("¥\(String(format: "%.2f", c.amount))")
                                            .font(pfMoney(15))
                                            .foregroundColor(C.label)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 56)
                                }
                            }
                        }
                        .padding(.top, 10)

                        Text(footHint(info))
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 16)
                    } else if loading {
                        ProgressView().padding(.top, 60)
                    } else {
                        Text("红包不存在或者已经删了")
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .padding(.top, 60)
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            raw = try? await API.shared.redPacketDetail(id: id)
            loading = false
        }
    }

    private func summaryLine(_ info: RedPacketInfo) -> String {
        let claimed = raw?.claimedCount ?? info.claimedCount
        if info.expired {
            return "共 \(info.count) 个，已领 \(claimed) 个 · 红包已过期"
        }
        if info.isOver {
            return "共 \(info.count) 个，\(info.count) 个已被领完"
        }
        return "共 \(info.count) 个，已领 \(claimed) 个"
    }

    private func footHint(_ info: RedPacketInfo) -> String {
        if info.expired && info.refundAmount > 0 {
            return "24 小时到了，没被抢走的 ¥\(String(format: "%.2f", info.refundAmount)) 已经退回给发红包的人"
        }
        if info.stillOpen {
            return "还有 \(raw?.leftCount ?? 0) 个没被领 · 未领完的钱 24 小时后自动退回"
        }
        return "红包里的钱已经全部领走了"
    }
}

/* ============================================================ 通用：小头像（不要叫 AsyncImage，会盖住系统那个） */
struct RPAvatar: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Group {
            if !path.isEmpty, let url = API.shared.assetURL(path) {
                AsyncImageLoad(url: url)
            } else {
                Circle().fill(Color(hex: 0xE2A03C)).overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundColor(.white)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct AsyncImageLoad: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(C.hairline)
            }
        }
        .task {
            if let data = try? await API.shared.assetData(url) { image = UIImage(data: data) }
        }
    }
}

/* 时间：2026-09-23T06:12:33.123Z → 09-23 06:12 */
func rpTime(_ raw: String) -> String {
    let s = raw.replacingOccurrences(of: "T", with: " ")
    guard s.count >= 16 else { return s }
    let a = s.index(s.startIndex, offsetBy: 5)
    let b = s.index(s.startIndex, offsetBy: 16)
    return String(s[a..<b])
}
