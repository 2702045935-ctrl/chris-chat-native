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

    private var mine: Bool { info.fromId == (app.me?.id ?? "") }
    private var who: String { mine ? chat.name : (chat.lastMessage?.senderName ?? chat.name) }
    private var t: TransferInfo { live ?? info }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "账单", back: { dismiss() }) {
                Button {
                    app.show("这就是全部账单")
                } label: {
                    Text("全部账单")
                        .font(pf(15))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Avatar(path: chat.avatar ?? "", size: 56, radius: 8)
                        Text(mine ? "转账-转给\(who)" : "转账-来自\(who)")
                            .font(pf(15.3))
                            .foregroundColor(C.label)
                            .padding(.top, 14)
                        MoneyLabel(text: (mine ? "-" : "+") + "¥" + String(format: "%.2f", t.amount),
                                   size: 30, curSize: 0, color: C.label)
                            .padding(.top, 16)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 36)
                    .padding(.bottom, 66)

                    GroupCard {
                        infoRow("当前状态", t.statusText(mine: mine)
                                + (t.status == "pending" ? "（\(t.leftText)后自动退回）" : ""))
                        if t.status == "pending" {
                            HairLine(inset: 16)
                            Button {
                                billAction()
                            } label: {
                                HStack {
                                    Text(mine ? "提醒对方收款" : "立即收款")
                                        .font(pf(15))
                                        .foregroundColor(C.link)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 46)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        HairLine(inset: 16)
                        infoRow("转账说明", t.note.isEmpty ? "微信转账" : t.note)
                        HairLine(inset: 16)
                        infoRow("转账时间", TimeFmt.bill(t.createdAt))
                        HairLine(inset: 16)
                        infoRow("支付方式", t.methodName)
                        HairLine(inset: 16)
                        infoRow("转账单号", t.billNo, small: true)
                        if t.status == "received" {
                            HairLine(inset: 16)
                            infoRow("收款时间", TimeFmt.bill(t.receivedAt))
                        }
                        if t.status == "refunded" {
                            HairLine(inset: 16)
                            infoRow("退回时间", TimeFmt.bill(t.refundedAt))
                        }
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        HStack {
                            Text("账单服务")
                                .font(pf(14, .semibold))
                                .foregroundColor(C.label)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 10)

                        serviceRow("？", "对订单有疑惑") {
                            app.show("有疑问可以先联系对方，或让管理员在后台查这笔单号")
                        }
                        HairLine(inset: 16)
                        serviceRow("💬", "定位到聊天位置") {
                            dismiss()
                        }
                        HairLine(inset: 16)
                        serviceRow("📄", "查看往来转账") {
                            app.show("这就是全部账单")
                        }
                    }

                    Text("本服务由财付通提供")
                        .font(pf(12.5))
                        .foregroundColor(Color.dyn(0xA7A7A7, 0x7A7A7A))
                        .padding(.top, 90)
                        .padding(.bottom, 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private func infoRow(_ k: String, _ v: String, small: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k)
                .font(pf(15))
                .foregroundColor(C.subLabel)
                .frame(width: 68, alignment: .leading)
            Text(v)
                .font(pf(small ? 13 : 15))
                .foregroundColor(C.label)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func serviceRow(_ icon: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(icon).font(pf(16)).frame(width: 20)
                Text(name).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
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
