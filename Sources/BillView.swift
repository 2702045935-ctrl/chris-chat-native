import SwiftUI

/// 转账单（从聊天里那条转账消息的 JSON 解析出来）
struct TransferInfo {
    var id = ""
    var amount: Double = 0
    var note = ""
    var status = "pending"
    var method = "balance"
    var fromId = ""
    var toId = ""
    var createdAt = ""
    var expiresAt: Double = 0
    var receivedAt = ""
    var refundedAt = ""

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        id = (o["id"] as? String) ?? ""
        amount = (o["amount"] as? Double) ?? 0
        note = (o["note"] as? String) ?? ""
        status = (o["status"] as? String) ?? "pending"
        method = (o["method"] as? String) ?? "balance"
        fromId = (o["fromId"] as? String) ?? ""
        toId = (o["toId"] as? String) ?? ""
        createdAt = (o["createdAt"] as? String) ?? ""
        if let e = o["expiresAt"] as? Double { expiresAt = e }
        else if let e = o["expiresAt"] as? Int { expiresAt = Double(e) }
        receivedAt = (o["receivedAt"] as? String) ?? ""
        refundedAt = (o["refundedAt"] as? String) ?? ""
    }

    var methodName: String { method == "card" ? "建设银行储蓄卡(2125)" : "零钱" }

    func statusText(mine: Bool) -> String {
        if status == "pending" { return mine ? "等待对方确认收钱" : "等待你确认收钱" }
        if status == "received" { return "已收款" }
        return "已退回"
    }

    /// 还剩多久自动退回（网页版 leftText）
    var leftText: String {
        let ms = expiresAt - Date().timeIntervalSince1970 * 1000
        if !(ms > 0) { return "已到期" }
        let h = Int(ms / 3_600_000)
        let m = Int((ms.truncatingRemainder(dividingBy: 3_600_000)) / 60_000)
        if h >= 24 { return "1天内" }
        if h >= 1 { return "\(h)小时" + (m > 0 ? "\(m)分" : "") }
        return "\(m)分钟"
    }

    /// 参考图的单号格式：1000050001 + 年月日时分秒 + 单号
    var billNo: String {
        let d = TimeFmt.date(createdAt)
        var stamp = "00000000000000"
        if let d = d {
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            func p(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
            stamp = "\(c.year ?? 0)" + p(c.month) + p(c.day) + p(c.hour) + p(c.minute) + p(c.second)
        }
        return "1000050001" + stamp + id.replacingOccurrences(of: "tr_", with: "").uppercased()
    }
}

/* ============================================================
   账单详情（照网页版 bl-screen）：
   头像 + 转账-转给XX + -¥金额 + 当前状态/说明/时间/方式/单号 + 账单服务
   ============================================================ */

struct BillDetailView: View {
    let chat: Chat
    let info: TransferInfo

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var live: TransferInfo?
    @State private var showMore = false

    private var mine: Bool { info.fromId == (app.me?.id ?? "") }
    private var who: String { mine ? chat.name : (chat.lastMessage?.senderName ?? chat.name) }
    private var t: TransferInfo { live ?? info }

    /* 参考图（微信转账详情）量出来的文字：标题 17 / 金额数字 50、¥ 35 / 提示·明细 15 */
    private var faint: Color { Color.dyn(0x737373, 0x9A9A9A) }

    private var titleText: String {
        if t.status == "pending" { return mine ? "待\(who)收款" : "\(who)向你转账" }
        if t.status == "received" { return mine ? "对方已收款" : "已收款" }
        return mine ? "已退回你的余额" : "已退回对方"
    }

    private var hintText: String {
        if t.status == "pending" {
            /* leftText 在满 24 小时时返回的是「1天内」，已经带「内」了，别再加一个 */
            let left = t.leftText.hasSuffix("内") ? String(t.leftText.dropLast()) : t.leftText
            return mine ? "\(left)内对方未收款，将退还给你。" : "\(left)内未收款，将退还对方。"
        }
        if t.status == "received" { return "钱已存入" + (mine ? "对方" : "你的") + "零钱余额。" }
        return "超过 24 小时未收款，钱已原路退回。"
    }

    var body: some View {
        VStack(spacing: 0) {
            /* 顶栏：和参考图一样，右边是「···」（菜单里放账单服务） */
            NavBar(title: "", back: { dismiss() }) {
                Button {
                    showMore = true
                } label: {
                    Text("···")
                        .font(pf(19))
                        .foregroundColor(C.label)
                        .frame(width: 60, height: L.navH)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    /* 大图标：参考图是 50pt 的蓝色圆 */
                    TransferDetailIcon()
                        .padding(.top, 52)

                    /* 标题：参考图墨迹 14.3pt 高 → 16.5pt */
                    Text(titleText)
                        .font(pfExact(16.5))
                        .foregroundColor(C.label)
                        .padding(.top, 36)

                    /* 金额：参考图数字墨迹 35.7pt 高 → 50pt；¥ 墨迹 24.3 → 34pt；方点。
                       这一页不吃全站缩放（不然 50 会算成 47，跟参考图对不上）。 */
                    MoneyLabel(text: "¥" + money(t.amount), size: 50, curSize: 34,
                               topAlign: true, color: C.label, exact: true)
                        .padding(.top, 16)

                    /* 提示 + 操作链接：参考图 15pt，灰字 + 链接蓝 */
                    HStack(spacing: 2) {
                        Text(hintText)
                            .font(pfExact(14.5))
                            .foregroundColor(faint)
                        if t.status == "pending" {
                            Button {
                                billAction()
                            } label: {
                                Text(mine ? "提醒对方收款" : "立即收款")
                                    .font(pfExact(14.5))
                                    .foregroundColor(C.link)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 21)

                    /* 明细：参考图是先一条细线，再一行行 15pt 的「左灰右黑」 */
                    Rectangle()
                        .fill(C.hairline)
                        .frame(height: 0.5)
                        .padding(.horizontal, 32)
                        .padding(.top, 31)

                    detailRow("转账时间", TimeFmt.bill(t.createdAt))
                    if !t.note.isEmpty { detailRow("转账说明", t.note) }
                    detailRow("支付方式", t.methodName)
                    detailRow("转账单号", t.billNo)
                    if t.status == "received" { detailRow("收款时间", TimeFmt.bill(t.receivedAt)) }
                    if t.status == "refunded" { detailRow("退回时间", TimeFmt.bill(t.refundedAt)) }

                    Spacer(minLength: 40)
                }
            }
            .background(C.cardBg)

            /* 最下面那颗「账单详情」（参考图在最底下、链接色） */
            Button {
                showMore = true
            } label: {
                Text("账单详情")
                    .font(pfExact(14.5))
                    .foregroundColor(C.link)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 18)
            .background(C.cardBg)
        }
        .background(C.cardBg.ignoresSafeArea(edges: .bottom))
        .background(C.cardBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .confirmationDialog("账单详情", isPresented: $showMore, titleVisibility: .visible) {
            Button("刷新状态") {
                Task {
                    if let list = try? await API.shared.messages(chatId: chat.id, limit: 30),
                       let msg = list.messages.last(where: { $0.kindName == "transfer" }),
                       let updated = TransferInfo(json: msg.body) {
                        live = updated
                    }
                    app.show("已经是最新状态")
                }
            }
            Button("对订单有疑惑") {
                app.show("有疑问可以先联系对方，或让管理员在后台查这笔单号")
            }
            Button("定位到聊天位置") { dismiss() }
            Button("取消", role: .cancel) { }
        }
    }

    /// 明细行：左灰右黑，参考图里一行 49 高、左右各留 32
    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            Text(k)
                .font(pfExact(14.5))
                .foregroundColor(faint)
            Spacer(minLength: 0)
            Text(v)
                .font(pfExact(14.5))
                .foregroundColor(C.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 32)
        .frame(height: 49)
    }

    private func billAction() {
        if mine {
            app.show("已提醒对方收款")
            return
        }
        Task {
            await API.shared.claimTransfer(t.id)
            if let list = try? await API.shared.messages(chatId: chat.id, limit: 30),
               let msg = list.messages.last(where: { $0.kindName == "transfer" }),
               let updated = TransferInfo(json: msg.body) {
                live = updated
            }
            app.me = try? await API.shared.me()
            app.show("已收款")
        }
    }
}

extension Message {
    var transferInfo: TransferInfo? {
        kindName == "transfer" ? TransferInfo(json: body) : nil
    }
}

/* ============================================================
   转账详情页顶上那个大图标。
   参考图里是：50pt 的蓝色实心圆（#10AEFF）+ 一笔白色的折线。
   白色那笔是照着参考图逐像素量出来的（不是字体渲染的）：
   竖笔在圆心偏左 0.35pt，从圆顶往下 10pt 处起笔，到 23.6pt 处折向右下 33°，
   笔宽 5.4pt、两头圆头。
   ============================================================ */
struct TransferDetailIcon: View {
    var size: CGFloat = 50

    var body: some View {
        let s = size / 50
        ZStack {
            Circle().fill(Color(hex: 0x10AEFF))
            Path { p in
                p.move(to: CGPoint(x: 25.35 * s, y: 12.7 * s))
                p.addLine(to: CGPoint(x: 25.35 * s, y: 23.6 * s))
                p.addLine(to: CGPoint(x: 31.7 * s, y: 33.4 * s))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 5.4 * s,
                                                    lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}
