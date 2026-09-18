import SwiftUI

/* ============================================================
   钱包（我 → 服务 → 钱包）
   尺寸照参考图量的（iPhone @3x，420×912pt）：
     · 页顶留 6pt，然后一张全宽白卡（卡上沿一条 0.5pt 分隔线）
     · 每行 56.4pt：图标 20pt 在 x=18，文字 x=56.7（17pt），右边数值 16pt，
       箭头右边距 18pt；行与行之间 0.5pt 分隔线，左边缩进 56pt 画到右边
     · 两张卡之间空 12pt；底部两个蓝色链接（#576B95 / 13pt）居中，距安全区 26pt
   内容全部来自后台「钱包页」模块（GET /api/wallet），零钱那一行显示真实余额。
   ============================================================ */

struct WalletView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var cfg: WalletConfig?
    /// 点开看过的金额（每次进页面都清空 → 默认都是星号）
    @State private var revealed: Set<String> = []

    private var st: WalletStyle { cfg?.style ?? WalletStyle() }

    /// 卡片：第一张 5 行、第二张 2 行，都是后台配的
    private var groups: [WalletGroup] {
        let list = cfg?.groups ?? []
        return list.filter { ($0.enabled != false) && !(($0.items ?? []).filter { $0.enabled != false }.isEmpty) }
    }

    private var footLinks: [WalletFoot] {
        (cfg?.footer ?? []).filter { $0.enabled != false }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: cfg?.title ?? "钱包", back: { dismiss() }) {
                Button {
                    run((cfg?.right?.action ?? "bills"), (cfg?.right?.label ?? "账单"))
                } label: {
                    Text(cfg?.right?.label ?? "账单")
                        .font(pf(17))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.trailing, 18)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 6)
                    ForEach(groups) { g in
                        card(g).padding(.top, g.id == groups.first?.id ? 0 : st.gap)
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)

            footer
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .onChange(of: realtime.event) { ev in
            if ev.type == "transfer" || ev.type == "balance" || ev.type == "ui" { Task { await load() } }
        }
    }

    /* ---------------------------------------------------------- 一张白卡 */

    private func card(_ g: WalletGroup) -> some View {
        let rows = (g.items ?? []).filter { $0.enabled != false }
        let s = st
        return VStack(spacing: 0) {
            Rectangle().fill(C.hairline).frame(height: 0.5)
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, it in
                row(it)
                if idx < rows.count - 1 {
                    HairLine(inset: s.divider)
                }
            }
        }
        .background(C.cardBg)
    }

    /* ---------------------------------------------------------- 一行 */

    private func row(_ it: WalletItem) -> some View {
        let s = st
        let rawValue = it.value ?? ""
        let masked = !rawValue.isEmpty && s.mask && (it.mask ?? true)
        let value = (masked && !revealed.contains(it.id)) ? WalletView.maskMoney(rawValue) : rawValue
        let note = it.note ?? ""
        return Button {
            run(it.action ?? "soon", it.label)
        } label: {
            HStack(spacing: 0) {
                SVGIcon(markup: WalletIcon.markup(it.icon, it.svg), size: s.icon,
                        color: Color(hexString: it.color ?? "#1180E0", fallback: 0x1180E0))
                    .frame(width: s.icon, height: s.icon)
                    .padding(.leading, s.iconX)

                Text(it.label)
                    .font(pf(s.labelFont))
                    .foregroundColor(s.labelColorV)
                    .padding(.leading, max(0, s.textX - s.iconX - s.icon))

                if !note.isEmpty {
                    Text(note)
                        .font(pf(s.noteFont))
                        .foregroundColor(s.noteColorV)
                        .padding(.leading, 11.7)
                }

                Spacer(minLength: 0)

                if !value.isEmpty {
                    Text(value)
                        .font(pf(s.valueFont))
                        .foregroundColor(s.valueColorV)
                        .padding(.trailing, 11)
                        .onTapGesture {
                            guard masked, s.canReveal else { return }
                            if revealed.contains(it.id) { revealed.remove(it.id) } else { revealed.insert(it.id) }
                        }
                }

                Chevron(size: 9, line: 1.6)
                    .padding(.trailing, s.rightPad)
            }
            .frame(height: s.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 底部两个链接 */

    private var footer: some View {
        HStack(spacing: 19) {
            ForEach(footLinks) { f in
                Button {
                    run(f.action ?? "soon", f.label)
                } label: {
                    Text(f.label)
                        .font(pf(st.footFont))
                        .foregroundColor(st.footerColorV)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .background(C.pageBg)
    }

    /* ---------------------------------------------------------- 动作 */

    private func run(_ action: String, _ label: String) {
        switch action {
        case "balance":
            app.show("零钱 ¥\(String(format: "%.2f", app.me?.balance ?? 0))")
        case "bills":
            app.show("账单：进任意聊天看「转账」记录")
        case "settings":
            app.show("支付设置：还没接后端，先把页面做出来")
        case "service":
            app.show("客服中心：暂时没有在线客服")
        default:
            app.show("「\(label)」还没接后端，先把页面做出来")
        }
    }

    private func load() async {
        revealed = []          // 进来先全部打星号
        if let got = try? await API.shared.walletConfig() {
            cfg = got
        } else if cfg == nil {
            // 服务器连不上 / 还没升级：用内置那份兜底，别开天窗
            cfg = WalletFallback.config(balance: app.me?.balance ?? 0)
        }
    }

    /// ¥122.00 → ¥****
    static func maskMoney(_ text: String) -> String {
        if text.contains("¥") { return "¥****" }
        return String(text.map { $0.isNumber ? "*" : $0 })
    }
}
