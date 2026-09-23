import SwiftUI

/* ============================================================
   好友名片 · 新版（畅聊 / HarmonyOS 设计语言）
   令牌：品牌蓝 #007DFF、文字 #181818/#666/#999、底 #FFFFFF/#F5F6F7、
        分隔 #E8EAED、圆角 8/12/16/胶囊、阴影 #20000000、间距 4 的倍数
   开关：后台 ui.json 里 cardStyle = "new" 才用这一版；默认 "old" 就是原来那版
   ============================================================ */

private let hBlue   = Color(hex: 0x007DFF)
private let hBlueBg = Color(hex: 0xE8F3FF)
private let hInk    = Color(hex: 0x181818)
private let hInk2   = Color(hex: 0x666666)
private let hInk3   = Color(hex: 0x999999)
private let hBg     = Color(hex: 0xF5F6F7)
private let hLine   = Color(hex: 0xE8EAED)
private let hGreen  = Color(hex: 0x2E7D32)

struct ContactCardNew: View {
    let name: String
    let idLine: String
    let initial: String
    let remark: String
    let phone: String
    let momentCount: Int
    let onClose: () -> Void
    let onMessage: () -> Void
    let onMoments: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            hBg.ignoresSafeArea()
            VStack(spacing: 0) {
                nav
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        if !detailRows.isEmpty {
                            sectionTitle("资料")
                            card {
                                ForEach(Array(detailRows.enumerated()), id: \.offset) { idx, row in
                                    if idx > 0 { line }
                                    hRow(row.0, row.1)
                                }
                            }
                        }
                        if momentCount > 0 {
                            sectionTitle("朋友圈", trailing: "\(momentCount) 条")
                            card {
                                Button {
                                    onMoments?()
                                } label: {
                                    HStack(spacing: 12) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(hBlueBg)
                                            .frame(width: 44, height: 44)
                                            .overlay(Image(systemName: "photo.on.rectangle.angled")
                                                .font(.system(size: 18)).foregroundColor(hBlue))
                                        Text("看 TA 的朋友圈").font(pf(16)).foregroundColor(hInk)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold)).foregroundColor(hInk3)
                                    }
                                    .padding(.horizontal, 16).frame(height: 60)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Spacer(minLength: 24)
                    }
                }
            }
        }
    }

    private var detailRows: [(String, String)] {
        var list: [(String, String)] = []
        if !remark.isEmpty { list.append(("备注", remark)) }
        if !phone.isEmpty { list.append(("手机号", phone)) }
        return list
    }

    private var nav: some View {
        HStack {
            Button { onClose() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(hInk)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(name).font(pf(17, .semibold)).foregroundColor(hInk)
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 17)).foregroundColor(hInk)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.white)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(Color(hex: 0xE4E6EB)).frame(width: 88, height: 88)
                    .overlay(Text(initial).font(pf(34, .medium)).foregroundColor(hInk))
                Circle().fill(hGreen).frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2.5))
            }
            .padding(.top, 24)
            Text(name).font(pf(22, .medium)).foregroundColor(hInk).padding(.top, 16)
            Text(idLine).font(pf(14)).foregroundColor(hInk3).padding(.top, 6)
            HStack(spacing: 12) {
                Button { onMessage() } label: {
                    Text("发消息").font(pf(17, .medium)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(Capsule().fill(hBlue))
                }
                .buttonStyle(.plain)
                if let m = onMoments, momentCount > 0 {
                    Button { m() } label: {
                        Text("朋友圈").font(pf(17, .medium)).foregroundColor(hBlue)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(Capsule().stroke(hBlue, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color(hex: 0x20000000), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func sectionTitle(_ t: String, trailing: String? = nil) -> some View {
        HStack {
            Text(t).font(pf(18, .medium)).foregroundColor(hInk)
            Spacer()
            if let tr = trailing { Text(tr).font(pf(14)).foregroundColor(hInk3) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color(hex: 0x20000000), radius: 8, x: 0, y: 2)
            .padding(.horizontal, 16)
    }

    private func hRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(pf(16)).foregroundColor(hInk)
            Spacer()
            Text(v).font(pf(14)).foregroundColor(hInk3)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var line: some View {
        Rectangle().fill(hLine).frame(height: 1).padding(.leading, 16)
    }
}
