import SwiftUI

/// 转账面板：金额 + 备注 + 付款方式 + 支付密码
struct TransferSheet: View {
    let chat: Chat
    var onConfirm: (Double, String, String, String) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var amount = ""
    @State private var note = ""
    @State private var method = "balance"
    @State private var password = ""

    private var value: Double { Double(amount) ?? 0 }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("转账给 \(chat.name)")) {
                    HStack {
                        Text("¥")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(C.label)
                        TextField("0.00", text: $amount)
                            .font(.system(size: 26, weight: .medium))
                            .keyboardType(.decimalPad)
                    }
                    TextField("添加转账说明（选填）", text: $note)
                }

                Section(header: Text("付款方式")) {
                    Button {
                        method = "balance"
                    } label: {
                        HStack {
                            Text("零钱").foregroundColor(C.label)
                            Spacer()
                            Text("¥\(String(format: "%.2f", app.me?.balance ?? 0))")
                                .font(.system(size: 14))
                                .foregroundColor(C.subLabel)
                            if method == "balance" {
                                Image(systemName: "checkmark").foregroundColor(C.green)
                            }
                        }
                    }
                    Button {
                        method = "card"
                    } label: {
                        HStack {
                            Text("建设银行储蓄卡（2125）").foregroundColor(C.label)
                            Spacer()
                            if method == "card" {
                                Image(systemName: "checkmark").foregroundColor(C.green)
                            }
                        }
                    }
                }

                Section(footer: Text("没设过支付密码就不用填。钱先从零钱里扣，对方点「收钱」才进他余额，24 小时没人收自动退回。")) {
                    SecureField("支付密码（没设过可留空）", text: $password)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("转账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("转账") {
                        onConfirm(value, note, method, password)
                        dismiss()
                    }
                    .disabled(!(value > 0))
                }
            }
        }
    }
}
