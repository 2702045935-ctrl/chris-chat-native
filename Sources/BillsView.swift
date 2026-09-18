import SwiftUI

/* ============================================================
   账单（钱包页右上角「账单」进来）
   尺寸照参考图量的（iPhone @3x，420×912pt）：
     · 顶栏高 52.4：「全部账单 ▾」药丸 90×36 在 x=16.7、
       「查找交易」搜索框 101.7×36 在 x=124.3、「收支统计 ›」贴右 18，
       顶栏下面一条 0.5pt 分隔线
     · 月份行 56.3：左边「2026年9月 ▾」（15pt），右边「支出 ¥x 收入 ¥y」（13pt 灰）
     · 白卡里每行 80：图标 48 圆角 12 在 x=16、标题 x=81（17pt）、
       时间 x=81（13pt #B2B2B2）、金额贴右 18（16pt，收入 #FFC406，支出深色）
   数据来自 GET /api/bills（真实转账记录）。
   ============================================================ */

struct BillsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var bills: [BillRecord] = []
    @State private var months: [String] = []
    @State private var summary: BillSummary?
    @State private var month = ""                 // 空 = 全部
    @State private var loading = true
    @State private var showMonths = false
    @State private var showFilter = false
    @State private var showStats = false
    @State private var showMore = false
    @State private var filter = "all"             // all / out / in
    @State private var query = ""
    @State private var openBill: BillRecord?
    @State private var showDetail = false
    @State private var style = BillsPageStyle()

    private let fieldBg = Color.dyn(0xE3E3E3, 0x2C2C2E)
    private let fieldInk = Color.dyn(0x3A3A3A, 0xEDEDED)
    private let timeGray = Color.dyn(0xB2B2B2, 0x8A8A8E)
    private let sumGray = Color.dyn(0x7B7B7B, 0x8A8A8E)
    private let incomeGold = Color(hex: 0xFFC406)

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "账单", back: { dismiss() }) {
                Button { showMore = true } label: {
                    Text("⋯")
                        .font(pf(22))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
            }

            topBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if loading {
                        ProgressView().padding(.vertical, 40)
                    } else if filtered.isEmpty {
                        Text("还没有账单")
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                            .padding(.vertical, 60)
                    } else {
                        ForEach(groups, id: \.month) { g in
                            monthHeader(g)
                            VStack(spacing: 0) {
                                ForEach(Array(g.rows.enumerated()), id: \.element.id) { idx, b in
                                    row(b)
                                    if idx < g.rows.count - 1 { HairLine(inset: 64) }
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
        .confirmationDialog("账单", isPresented: $showFilter, titleVisibility: .hidden) {
            Button("全部账单") { filter = "all" }
            Button("只看支出") { filter = "out" }
            Button("只看收入") { filter = "in" }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("按月份看", isPresented: $showMonths, titleVisibility: .hidden) {
            Button("全部账单") { Task { await load("") } }
            ForEach(months, id: \.self) { m in
                Button(monthLabel(m)) { Task { await load(m) } }
            }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog("收支统计", isPresented: $showStats, titleVisibility: .visible) {
            Button("支出 \(money(summary?.out ?? 0))") { }
            Button("收入 \(money(summary?.inSum ?? 0))（只算已收款的）") { }
            Button("待你收款 \(summary?.pendingIn ?? 0) 笔 · 待对方收款 \(summary?.pendingOut ?? 0) 笔") { }
            Button("一共 \(summary?.count ?? 0) 笔") { }
            Button("关闭", role: .cancel) { }
        }
        .confirmationDialog("账单", isPresented: $showMore, titleVisibility: .hidden) {
            Button("账单常见问题") { app.show("账单常见问题：还没做，排在下一批") }
            Button("导出账单（CSV）") { exportCsv() }
            Button("取消", role: .cancel) { }
        }
        .navigationDestination(isPresented: $showDetail) {
            if let b = openBill { billDetail(b) }
        }
        .task { await load("") }
    }

    /* ---------------------------------------------------------- 顶栏 */

    private var topBar: some View {
        HStack(spacing: 0) {
            Button { showFilter = true } label: {
                HStack(spacing: 3) {
                    Text(filterName).font(pf(13)).foregroundColor(fieldInk)
                    DownChevron(size: 9, color: fieldInk)
                }
                .frame(width: 90, height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fieldBg))
            }
            .buttonStyle(.plain)

            HStack(spacing: 4.4) {
                SVGIcon(markup: I.searchSmall, size: 13, color: fieldInk)
                    .frame(width: 13, height: 13)
                    .padding(.leading, 4.3)
                TextField("查找交易", text: $query)
                    .font(pf(13))
                    .foregroundColor(fieldInk)
                    .textFieldStyle(.plain)
            }
            .frame(width: 101.7, height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fieldBg))
            .padding(.leading, 17.6)

            Spacer(minLength: 0)

            Button { showStats = true } label: {
                HStack(spacing: 5) {
                    Text("收支统计").font(pf(13)).foregroundColor(sumGray)
                    Chevron(size: 6, line: 1.4, color: sumGray)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16.7)
        .frame(height: 52.4)
        .overlay(alignment: .bottom) { HairLine() }
    }

    private var filterName: String {
        filter == "out" ? "只看支出" : (filter == "in" ? "只看收入" : "全部账单")
    }

    /* ---------------------------------------------------------- 月份行 */

    private func monthHeader(_ g: MonthGroup) -> some View {
        let s = monthSum(g.month)
        return HStack(spacing: 0) {
            Button { showMonths = true } label: {
                HStack(spacing: 4) {
                    Text(monthLabel(g.month)).font(pf(style.monthFont)).foregroundColor(C.label)
                    DownChevron(size: 9, color: C.label)
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Text("支出 \(money(s.out)) 收入 \(money(s.income))")
                .font(pfMoney(style.sumFont))
                .foregroundColor(sumGray)
        }
        .padding(.leading, 17)
        .padding(.trailing, 18)
        .frame(height: 56.3)
    }

    /* ---------------------------------------------------------- 一行账单 */

    private func row(_ b: BillRecord) -> some View {
        Button {
            openBill = b
            showDetail = true
        } label: {
            HStack(spacing: 0) {
                Avatar(path: b.peerAvatar ?? "", size: style.icon, radius: style.icon * 0.25)
                    .padding(.leading, 16)
                VStack(alignment: .leading, spacing: 11) {
                    Text(b.peer)
                        .font(pf(style.titleFont))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    Text(TimeFmt.bill(b.createdAt))
                        .font(pf(style.timeFont))
                        .foregroundColor(timeGray)
                }
                .padding(.leading, 17)
                Spacer(minLength: 8)
                MoneyLabel(text: (b.mine ? "-" : "+") + money(b.amount),
                           size: style.amountFont, curSize: style.curFontSize,
                           color: b.mine ? C.label : incomeGold)
                    .padding(.trailing, 18)
            }
            .frame(height: style.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 点一条 → 账单详情 */

    @ViewBuilder
    private func billDetail(_ b: BillRecord) -> some View {
        let meId = app.me?.id ?? ""
        let chat = Chat(id: (b.chatId?.isEmpty == false ? b.chatId! : (b.peerId ?? b.id)),
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

    /* ---------------------------------------------------------- 分组 / 汇总 / 数据 */

    private struct MonthGroup { var month: String; var rows: [BillRecord] }

    private var filtered: [BillRecord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return bills.filter { b in
            if filter == "out" && !b.mine { return false }
            if filter == "in" && b.mine { return false }
            if !q.isEmpty {
                let hay = (b.peer + " " + (b.note ?? "")).lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    private var groups: [MonthGroup] {
        var out: [MonthGroup] = []
        for b in filtered {
            let m = String((b.createdAt ?? "").prefix(7))
            if out.last?.month == m { out[out.count - 1].rows.append(b) }
            else { out.append(MonthGroup(month: m, rows: [b])) }
        }
        return out
    }

    private func monthSum(_ m: String) -> (out: Double, income: Double) {
        var o = 0.0
        var i = 0.0
        for b in bills where String((b.createdAt ?? "").prefix(7)) == m {
            if b.mine { o += b.amount }
            else if (b.status ?? "") == "received" { i += b.amount }
        }
        return (o, i)
    }

    private func monthLabel(_ m: String) -> String {
        let parts = m.split(separator: "-")
        guard parts.count == 2, let mm = Int(parts[1]) else { return m }
        return "\(parts[0])年\(mm)月"
    }

    private func money(_ v: Double) -> String { "¥" + String(format: "%.2f", v) }

    /// 导出账单：拼一份 CSV 复制到剪贴板（手机上先这样，之后可以接分享）
    private func exportCsv() {
        guard !bills.isEmpty else { app.show("还没有账单可以导出"); return }
        var lines = ["时间,对方,方向,金额,状态,说明,支付方式,单号"]
        for b in bills {
            let fields = [
                TimeFmt.bill(b.createdAt),
                b.peer,
                b.mine ? "支出" : "收入",
                (b.mine ? "-" : "+") + String(format: "%.2f", b.amount),
                b.stateText,
                b.note ?? "",
                (b.method ?? "balance") == "card" ? "银行卡" : "零钱",
                b.id
            ]
            lines.append(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        app.show("已复制 \(bills.count) 笔账单到剪贴板（CSV）")
    }

    private func load(_ m: String) async {
        loading = true
        if let d = try? await API.shared.bills(month: m.isEmpty ? nil : m) {
            bills = d.bills
            months = d.months ?? []
            summary = d.summary
            month = m
            if let s = d.style { style = s }
        }
        loading = false
    }
}

/// 小的下箭头（月份、筛选那种 ▾）
struct DownChevron: View {
    var size: CGFloat = 9
    var line: CGFloat = 1.6
    var color: Color = .gray
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: size / 2, y: size / 2))
            p.addLine(to: CGPoint(x: size, y: 0))
        }
        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size / 2)
    }
}
