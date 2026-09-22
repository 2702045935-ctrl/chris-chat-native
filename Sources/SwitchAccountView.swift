import SwiftUI

/* ============================================================
   切换账号（我 → 设置 → 切换账号）—— 逻辑照微信：
   · 这台设备登录过的账号列在这儿，点一下直接切，不用重新输密码
   · 右上「管理」→ 可以移除没在用的账号（当前账号不能删）
   · 最下面「+ 添加账号」→ 直接弹登录页再登一个
   · 最多记 3 个；令牌分开存在钥匙串里，切回去也是秒进
   ============================================================ */
struct SwitchAccountView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var managing = false
    @State private var adding = false
    @State private var busy = ""
    @State private var note = ""

    private var me: String { app.me?.username ?? "" }
    private var sheetBg: Color { scheme == .dark ? Color(hex: 0x1C1C1E) : .white }
    private var pageBg: Color { scheme == .dark ? Color(hex: 0x111111) : Color(hex: 0xEDEDED) }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }
    private var gray: Color { scheme == .dark ? Color(hex: 0x8E8E93) : Color(hex: 0x737373) }
    private var line: Color { scheme == .dark ? Color(white: 1, opacity: 0.09) : Color(hex: 0xE6E6E6) }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("切换账号"), back: { dismiss() }) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { managing.toggle() }
                } label: {
                    Text(Tr(managing ? "完成" : "管理"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 8)

                    VStack(spacing: 0) {
                        ForEach(app.accounts) { acct in
                            row(acct)
                            HairLine(inset: 68)
                        }
                        addRow
                    }
                    .background(sheetBg)

                    if !note.isEmpty {
                        Text(note)
                            .font(pf(13))
                            .foregroundColor(Color(hexString: "#FA5151"))
                            .padding(.top, 12)
                            .padding(.horizontal, 16)
                    }

                    Text(Tr("一个设备最多记 3 个账号。切过去不用重新输密码，令牌分开存在本机钥匙串里。"))
                        .font(pf(12.5))
                        .foregroundColor(gray)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    Color.clear.frame(height: 24)
                }
            }
            .background(pageBg)
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $adding) {
            /* 跟登录页一样的那套（微信号/手机号 + 密码/验证码），登完就多一个账号 */
            AccountLoginSheet(mode: .account)
                .environmentObject(app)
        }
    }

    /* ---------------------------------------------------------- 一个账号 */

    private func row(_ a: SavedAccount) -> some View {
        let current = (a.username == me)
        return Button {
            if managing {
                if !current { remove(a) }      // 管理模式下点一下 = 移除（当前账号不给删）
            } else if !current {
                switchTo(a)
            }
        } label: {
            HStack(spacing: 12) {
                Avatar(path: a.avatar, size: 44, radius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(a.nickname.isEmpty ? a.username : a.nickname)
                        .font(pf(16.5))
                        .foregroundColor(ink)
                        .lineLimit(1)
                    Text(Tr("微信号") + "：" + a.username)
                        .font(pf(13))
                        .foregroundColor(gray)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if busy == a.username {
                    ProgressView()
                } else if managing, !current {
                    Text(Tr("移除"))
                        .font(pf(15))
                        .foregroundColor(Color(hexString: "#FA5151"))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().stroke(Color(hexString: "#FA5151").opacity(0.5), lineWidth: 0.8))
                } else if current {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(C.green)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addRow: some View {
        Button {
            adding = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.dyn(0xD5D5D5, 0x4A4A4A), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: 44, height: 44)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(gray)
                }
                Text(Tr("添加账号"))
                    .font(pf(16.5))
                    .foregroundColor(ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 干活 */

    private func switchTo(_ a: SavedAccount) {
        note = ""
        busy = a.username
        Task {
            let saved = AccountStore.token(for: a.username)
            let ok = await app.quickLogin(token: saved.isEmpty ? nil : saved)
            busy = ""
            if ok {
                dismiss()
            } else {
                note = Tr("这个账号的登录状态过期了，重新输一次密码就行")
                adding = true
            }
        }
    }

    private func remove(_ a: SavedAccount) {
        AccountStore.remove(username: a.username)
        app.accounts = AccountStore.load()
        app.show(Tr("已移除") + "「" + a.nickname + "」")
        if app.accounts.isEmpty { managing = false }
    }
}
