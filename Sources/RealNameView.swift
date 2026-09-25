import SwiftUI

/* ============================================================
   实名认证（我 → 设置 → 实名认证）
   填姓名 + 身份证号，服务端校验：18 位（最后一位可能是 X）、
   生日合法、校验位对、一人一证（和「自助解封」用同一张证）。
   认证过就不能自己改，要改找管理员。实名 +30 分安全分。
   ============================================================ */
struct RealNameView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var info: API.RealNameInfo?
    @State private var name = ""
    @State private var idCard = ""
    @State private var busy = false
    @State private var error = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable { case name, id }

    private var sheetBg: Color { scheme == .dark ? Color(hex: 0x1C1C1E) : .white }
    private var pageBg: Color { scheme == .dark ? Color(hex: 0x111111) : Color(hex: 0xEDEDED) }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }
    private var gray: Color { scheme == .dark ? Color(hex: 0x8E8E93) : Color(hex: 0x737373) }
    private var line: Color { scheme == .dark ? Color(white: 1, opacity: 0.09) : Color(hex: 0xE6E6E6) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("实名认证"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 10)

                    if let i = info, i.verified {
                        verifiedCard(i)
                    } else {
                        formCard
                    }

                    Color.clear.frame(height: 10)
                    noteCard
                    Color.clear.frame(height: 26)
                }
            }
            .background(pageBg)
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            info = await API.shared.realNameStatus()
            if let i = info, !i.verified { name = app.me?.name ?? "" }
        }
    }

    /* ---------------------------------------------------- 已经实名了 */
    private func verifiedCard(_ i: API.RealNameInfo) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Color(hexString: "#19A47A"))
                Text(Tr("已实名认证"))
                    .font(pf(17, .medium))
                    .foregroundColor(ink)
            }
            .padding(.vertical, 22)

            HairLine(inset: 16)
            row(Tr("姓名"), i.realName)
            HairLine(inset: 16)
            row(Tr("身份证号"), i.idMask)
            if !i.at.isEmpty {
                HairLine(inset: 16)
                row(Tr("认证时间"), i.at.prefix(10).description)
            }
        }
        .background(sheetBg)
    }

    /* ---------------------------------------------------- 还没实名：填表 */
    private var formCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(Tr("姓名"))
                    .font(pf(16))
                    .foregroundColor(ink)
                    .frame(width: 72, alignment: .leading)
                TextField(Tr("请填写真实姓名"), text: $name)
                    .font(pf(16))
                    .foregroundColor(ink)
                    .focused($focus, equals: .name)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(sheetBg)

            HairLine(inset: 16)

            HStack(spacing: 10) {
                Text(Tr("身份证号"))
                    .font(pf(16))
                    .foregroundColor(ink)
                    .frame(width: 72, alignment: .leading)
                TextField(Tr("18 位身份证号"), text: $idCard)
                    .font(pf(16))
                    .foregroundColor(ink)
                    .focused($focus, equals: .id)
                    .keyboardType(.asciiCapable)
                    .autocorrectionDisabled()
                    .autocapitalization(.allCharacters)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(sheetBg)

            if !error.isEmpty {
                Text(error)
                    .font(pf(13))
                    .foregroundColor(Color(hexString: "#FA5151"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(sheetBg)
            }

            Button {
                submit()
            } label: {
                Text(busy ? Tr("提交中…") : Tr("提交认证"))
                    .font(pf(17, .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canSubmit ? C.green : Color.dyn(0xC8C8C8, 0x4A4A4A)))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || busy)
            .padding(16)
            .background(sheetBg)
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && idCard.count >= 15
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Tr("为什么要实名"))
                .font(pf(15, .medium))
                .foregroundColor(ink)
            bullet(Tr("实名后安全分的「身份特质」加 30 分"))
            bullet(Tr("转账、收付款更可信；被封号也能用这张身份证自助解封"))
            bullet(Tr("身份证号只在本机服务器上存密文，界面只显示前 6 位和后 4 位"))
            bullet(Tr("一张身份证只能绑一个账号，认证后不能自己改"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(sheetBg)
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(C.green).frame(width: 5, height: 5).padding(.top, 6)
            Text(t).font(pf(13.5)).foregroundColor(gray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(pf(16)).foregroundColor(ink)
            Spacer(minLength: 0)
            Text(v).font(pf(16)).foregroundColor(gray)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func submit() {
        error = ""
        focus = nil
        busy = true
        Task {
            do {
                let r = try await API.shared.submitRealName(name: name.trimmingCharacters(in: .whitespaces),
                                                            idCard: idCard.trimmingCharacters(in: .whitespaces))
                info = r
                app.me = try? await API.shared.me()
                app.show(Tr("实名认证通过 ✅"))
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "认证失败，检查一下再试"
            }
            busy = false
        }
    }
}
