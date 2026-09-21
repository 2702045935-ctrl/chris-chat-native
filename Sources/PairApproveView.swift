import SwiftUI

/* 设备确认登录（确认方）：
   网页版点「微信授权登录 / QQ 授权登录」会出一个 6 位数字，
   在这台已经登录的手机上：我 → 设置 → 设备确认登录，输入那个数字，网页就登上了。 */
struct PairApproveView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("设备确认登录"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    Text(Tr("在另一台设备（网页版 / 新手机）上点「微信授权登录」，会显示一个 6 位数字，输在下面，那台设备就能进这台账号。"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)

                    HStack(spacing: 10) {
                        TextField("6 位数字", text: $code)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .keyboardType(.numberPad)
                            .tracking(6)
                            .focused($focused)
                            .onChange(of: code) { v in
                                code = String(v.filter { $0.isNumber }.prefix(6))
                            }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 64)
                    .background(C.cardBg)
                    .padding(.top, 18)

                    if let e = error {
                        Text(e).font(pf(13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                    }

                    Button {
                        approve()
                    } label: {
                        Text(busy ? "确认中…" : "确认登录")
                            .font(pf(16, .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(C.green)
                            .cornerRadius(12)
                    }
                    .disabled(busy || code.count != 6)
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear { focused = true }
    }

    private func approve() {
        busy = true
        error = nil
        Task {
            if let err = await API.shared.pairApprove(code: code) {
                error = err
            } else {
                app.show(Tr("已确认，那台设备登录成功"))
                dismiss()
            }
            busy = false
        }
    }
}
