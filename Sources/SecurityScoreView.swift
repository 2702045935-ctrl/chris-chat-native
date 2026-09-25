import SwiftUI

/* ============================================================
   安全分（照微信那套机制）
   550~850 分 · 三个维度：身份特质 / 支付行为 / 守约历史
   分档：较差 / 中等 / 良好 / 优秀 / 极好
   分数是服务端按真实记录算的（资料、登录设备、转账、记账、安全事件、违规）。
   ============================================================ */
struct SecurityScoreView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var data: CreditScore?
    @State private var failed = false
    @State private var openDim: String?

    private var sheetBg: Color { scheme == .dark ? Color(hex: 0x1C1C1E) : .white }
    private var pageBg: Color { scheme == .dark ? Color(hex: 0x111111) : Color(hex: 0xEDEDED) }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }
    private var gray: Color { scheme == .dark ? Color(hex: 0x8E8E93) : Color(hex: 0x737373) }
    private var line: Color { scheme == .dark ? Color(white: 1, opacity: 0.09) : Color(hex: 0xE6E6E6) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("安全分"), back: { dismiss() }) {
                Button { Task { await load() } } label: {
                    Text(Tr("刷新")).font(pf(16)).foregroundColor(C.label)
                        .frame(height: L.navH).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    hero
                    if let d = data {
                        Color.clear.frame(height: 10)
                        dimsCard(d)
                        Color.clear.frame(height: 10)
                        tipsCard(d)
                        Color.clear.frame(height: 10)
                        howCard
                    } else if failed {
                        Text(Tr("分数拿不到，检查下网络再刷新")).font(pf(14)).foregroundColor(gray)
                            .padding(.top, 40)
                    } else {
                        ProgressView().padding(.top, 40)
                    }
                    Color.clear.frame(height: 26)
                }
            }
            .background(pageBg)
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
    }

    /* ---------------------------------------------------- 上面那个大分数 */
    private var hero: some View {
        VStack(spacing: 6) {
            Text(Tr("安全分"))
                .font(pf(14))
                .foregroundColor(gray)

            ZStack {
                Circle()
                    .stroke(Color.dyn(0xE9E9E9, 0x2C2C2E), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, Double(data?.percent ?? 0) / 100)))
                    .stroke(LinearGradient(colors: [Color(hexString: "#19A47A"), Color(hexString: "#3FD07F")],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(data.map { String($0.score) } ?? "—")
                        .font(pf(44, .semibold))
                        .foregroundColor(ink)
                    Text(Tr(data?.level ?? "算分中"))
                        .font(pf(13, .medium))
                        .foregroundColor(Color(hexString: "#19A47A"))
                }
            }
            .frame(width: 150, height: 150)
            .padding(.top, 6)

            Text("分数范围 \(data?.min ?? 550) - \(data?.max ?? 850)")
                .font(pf(12))
                .foregroundColor(gray)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .background(sheetBg)
    }

    /* ---------------------------------------------------- 三个维度 */
    private func dimsCard(_ d: CreditScore) -> some View {
        VStack(spacing: 0) {
            ForEach(d.dims) { dim in
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            openDim = (openDim == dim.key) ? nil : dim.key
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(Tr(dim.label))
                                .font(pf(16))
                                .foregroundColor(ink)
                            Spacer(minLength: 0)
                            Text("\(dim.score)")
                                .font(pf(16, .medium))
                                .foregroundColor(Color(hexString: "#19A47A"))
                            Text("/ \(dim.max)")
                                .font(pf(12))
                                .foregroundColor(gray)
                            Image(systemName: openDim == dim.key ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(gray)
                                .padding(.leading, 2)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    /* 进度条 */
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.dyn(0xEFEFEF, 0x2C2C2E))
                            Capsule()
                                .fill(Color(hexString: "#19A47A"))
                                .frame(width: max(4, geo.size.width * CGFloat(dim.score) / CGFloat(max(1, dim.max))))
                        }
                    }
                    .frame(height: 6)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                    if openDim == dim.key {
                        VStack(spacing: 0) {
                            ForEach(Array((dim.items ?? []).enumerated()), id: \.offset) { _, it in
                                HStack(spacing: 8) {
                                    Image(systemName: it.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                                        .font(.system(size: 14))
                                        .foregroundColor(it.ok ? Color(hexString: "#19A47A") : Color(hexString: "#FA9D3C"))
                                    Text(Tr(it.label))
                                        .font(pf(14))
                                        .foregroundColor(ink)
                                    Spacer(minLength: 6)
                                    Text(Tr(it.tip ?? ""))
                                        .font(pf(12.5))
                                        .foregroundColor(gray)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.trailing)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    if dim.key != d.dims.last?.key {
                        Rectangle().fill(line).frame(height: 0.5).padding(.leading, 16)
                    }
                }
            }
        }
        .background(sheetBg)
    }

    /* ---------------------------------------------------- 怎么提分 */
    private func tipsCard(_ d: CreditScore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Tr("怎么提分"))
                .font(pf(15, .medium))
                .foregroundColor(ink)
            ForEach(Array(d.tips.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Color(hexString: "#19A47A")).frame(width: 5, height: 5).padding(.top, 6)
                    Text(Tr(t))
                        .font(pf(13.5))
                        .foregroundColor(gray)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(sheetBg)
    }

    private var howCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Tr("这是怎么算的") + "（" + Tr("体验分") + "）")
                .font(pf(15, .medium))
                .foregroundColor(ink)
            Text(Tr("三个维度各 100 分：身份特质（资料全不全）、支付行为（转账、收款、记账）、守约历史（按时收款、没有超时退回、没有违规）。加起来 300 分，落在 550~850 上就是你的体验分。"))
                .font(pf(13))
                .foregroundColor(gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(sheetBg)
    }

    private func load() async {
        do {
            data = try await API.shared.securityScore()
            failed = false
        } catch {
            failed = true
        }
    }
}
