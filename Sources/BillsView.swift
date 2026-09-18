import SwiftUI

/* ============================================================
   账单（钱包页右上角「账单」进来）
   数据来自 GET /api/bills：这个人所有的转账，带对方是谁、进出方向、状态、时间。
   上面一张汇总卡（总支出 / 总收入 / 待收款 / 共多少笔），下面按月分组列出来，
   点一条进原来的账单详情页（BillDetailView）。
   ============================================================ */

struct BillsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var bills: [BillRecord] = []
    @State private var months: [String] = []
    @State private var summary: BillSummary?
    @State private var month = ""            // 空 = 全部
    @State private var loading = true
    @State private var showMonths = false
    @State private var openBill: BillRecord?
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "账单", back: { dismiss() }) {
                Button { showMonths = true } label: {
                    Text(monthTitle)
                        .font(pf(15))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    summaryCard
                    if loading {
                        ProgressView().padding(.vertical, 40)
                    } else if bills.isEmpty {
                        Text("还没有账单")
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .padding(.vertical, 60)
                    } else {
                        ForEach(groups, id: \.month) { g in
                            Text(monthLabel(g.month))
                                .font(pf(13))
                                .foregroundColor(C.subLabel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 18)
                                .padding(.top, 14)
                                .padding(.bottom, 8)
                            VStack(spacing: 0) {
                                ForEach(Array(g.rows.enumerated()), id: \.element.id) { idx, b in
                                    row(b)
                                    if idx < g.rows.count - 1 { HairLine(inset: 66) }
                                }
                            }
                            .background(C.cardBg)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .confirmationDialog("按月份看", isPresented: $showMonths, titleVisibility: .hidden) {
            Button("全部账单") { Task { await load("") } }
            ForEach(months, id: \.self) { m in
                Button(monthLabel(m)) { Task { await load(m) } }
            }
            Button("取消", role: .cancel) { }
        }
        .navigationDestination(isPresented: $showDetail) {
            if let b = openBill { billDetail(b) }
        }
        .task { await load("") }
        .onChange(of: app.me?.balance) { _ in Task { await load(month) } }
    }

    /* ---------------------------------------------------------- 汇总卡 */

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(money(summary?.out ?? 0))
                    .font(pf(26, .semibold))
                    .foregroundColor(C.label)
                Text(month.isEmpty ? "总支出" : "这个月支出")
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
            }
            Text((month.isEmpty ? "总收入 " : "收入 ") + money(summary?.inSum ?? 0)
                 + " · 待收款 \(summary?.pendingIn ?? 0) 笔 · 待对方收款 \(summary?.pendingOut ?? 0) 笔 · 共 \(summary?.count ?? 0) 笔")
                .font(pf(12.5))
                .foregroundColor(C.subLabel)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .background(C.cardBg)
    }

    /* ---------------------------------------------------------- 一条账单 */

    private func row(_ b: BillRecord) -> some View {
        Button {
            openBill = b
            showDetail = true
        } label: {
            HStack(spacing: 12) {
                Avatar(path: b.peerAvatar ?? "", size: 36, radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.mine ? "转账-转给\(b.peer)" : "转账-来自\(b.peer)")
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    Text(TimeFmt.bill(b.createdAt))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text((b.mine ? "-" : "+") + money(b.amount))
                        .font(pf(16))
                        .foregroundColor(C.label)
                    Text(b.stateText)
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 点一条 → 原来的账单详情页（用这条账单的数据拼一个 TransferInfo）
    @ViewBuilder
    private func billDetail(_ b: BillRecord) -> some View {
        let meId = app.me?.id ?? ""
        let chat = Chat(id: (b.chatId?.isEmpty == false ? b.chatId! : b.peerId ?? b.id),
                        type: "direct",
                        title: b.peer,
                        avatar: b.peerAvatar)
        let json: [String: Any] = [
            "id": b.id,
            "amount": b.amount,
            "note": b.note ?? "",
            "status": b.status ?? "pending",
            "method": b.method ?? "balance",
            "fromId": b.mine ? meId : (b.peerId ?? ""),
            "toId": b.mine ? (b.peerId ?? "") : meId,
            "createdAt": b.createdAt ?? "",
            "expiresAt": b.expiresAt ?? 0,
            "receivedAt": b.receivedAt ?? "",
            "refundedAt": b.refundedAt ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let s = String(data: data, encoding: .utf8),
           let info = TransferInfo(json: s) {
            BillDetailView(chat: chat, info: info)
        } else {
            Text("这条账单读不出来").font(pf(14)).foregroundColor(C.subLabel)
        }
    }

    /* ---------------------------------------------------------- 分组 / 文案 / 数据 */

    private struct MonthGroup { var month: String; var rows: [BillRecord] }

    private var groups: [MonthGroup] {
        var out: [MonthGroup] = []
        for b in bills {
            let m = String((b.createdAt ?? "").prefix(7))
            if out.last?.month == m {
                out[out.count - 1].rows.append(b)
            } else {
                out.append(MonthGroup(month: m, rows: [b]))
            }
        }
        return out
    }

    private var monthTitle: String {
        month.isEmpty ? "全部" : monthLabel(month)
    }

    private func monthLabel(_ m: String) -> String {
        let parts = m.split(separator: "-")
        guard parts.count == 2, let mm = Int(parts[1]) else { return m }
        return "\(parts[0])年\(mm)月"
    }

    private func money(_ v: Double) -> String { "¥" + String(format: "%.2f", v) }

    private func load(_ m: String) async {
        loading = true
        if let d = try? await API.shared.bills(month: m.isEmpty ? nil : m) {
            bills = d.bills
            months = d.months ?? []
            summary = d.summary
            month = m
        }
        loading = false
    }
}
