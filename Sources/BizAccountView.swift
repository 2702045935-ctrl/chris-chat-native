import SwiftUI

/* 钱包 → 经营账户（点进去要先过手势密码，和微信一样）
   这一页是收款用的「经营账户」：余额、收款记录、经营设置。 */
struct BizAccountView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    private var money: String {
        "¥" + String(format: "%.2f", app.me?.balance ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("经营账户"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Text(Tr("账户余额"))
                            .font(pf(14))
                            .foregroundColor(C.subLabel)
                        Text(money)
                            .font(pf(34, .medium))
                            .foregroundColor(C.label)
                        Text(Tr("收款直接进零钱，经营账户用于开票和对账"))
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .background(C.cardBg)

                    Color.clear.frame(height: 12)

                    VStack(spacing: 0) {
                        row(Tr("收款记录"), "去「钱包 → 账单」看每一笔进出")
                        row(Tr("经营设置"), "经营账户设置还没接后端，先把页面做出来")
                        row(Tr("提现到零钱"), "余额随时可以提到零钱")
                        row(Tr("开票信息"), "开发票要先填抬头和税号，下一步再接")
                    }
                    .background(C.cardBg)

                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private func row(_ title: String, _ tip: String) -> some View {
        Button {
            app.show(tip)
        } label: {
            HStack {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { HairLine(inset: 16) }
    }
}
