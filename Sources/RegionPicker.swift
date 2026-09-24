import SwiftUI

/* ============================================================
   地区选择（和微信一样）：省 / 市两个滚轮，上下滑着选
   省市表在服务端（/api/regions），一次拉回来；点「完成」把「省 市」写回个人资料。
   ============================================================ */

struct RegionPickerSheet: View {
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [API.RegionRow] = []
    @State private var pi = 0
    @State private var ci = 0

    private var cities: [String] { pi < rows.count ? rows[pi].c : [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if rows.isEmpty {
                    ProgressView().padding(.top, 50)
                } else {
                    HStack(spacing: 0) {
                        Picker("", selection: $pi) {
                            ForEach(0..<rows.count, id: \.self) { i in
                                Text(rows[i].p).tag(i)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .onChange(of: pi) { _ in ci = 0 }

                        Picker("", selection: $ci) {
                            ForEach(0..<max(cities.count, 1), id: \.self) { i in
                                Text(i < cities.count ? cities[i] : "").tag(i)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        .clipped()
                    }
                    .frame(height: 220)
                }
                Spacer(minLength: 0)
            }
            .task { if rows.isEmpty { rows = await API.shared.regions() } }
            .navigationTitle(Tr("选择地区"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Tr("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Tr("完成")) {
                        guard pi < rows.count else { dismiss(); return }
                        let p = rows[pi].p
                        let c = ci < cities.count ? cities[ci] : ""
                        onPick((c.isEmpty || c == p) ? p : (p + " " + c))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(320)])
    }
}
