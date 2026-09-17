import SwiftUI

struct MeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    profileCard
                        .padding(.top, 4)

                    GroupCard {
                        NavigationLink(value: "service") {
                            MenuRow(icon: "creditcard.fill", color: Color(hex: 0x07C160), title: "服务")
                        }
                        .buttonStyle(.plain)
                    }

                    GroupCard {
                        NavigationLink(value: "favorites") {
                            MenuRow(icon: "star.fill", color: Color(hex: 0xFFB300), title: "收藏")
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 54)
                        NavigationLink(value: "album") {
                            MenuRow(icon: "photo.fill", color: Color(hex: 0x3C9CFF), title: "朋友圈")
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 54)
                        NavigationLink(value: "cards") {
                            MenuRow(icon: "rectangle.stack.fill", color: Color(hex: 0x5856D6), title: "卡包")
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 54)
                        NavigationLink(value: "stickers") {
                            MenuRow(icon: "face.smiling.fill", color: Color(hex: 0xFF9500), title: "表情")
                        }
                        .buttonStyle(.plain)
                    }

                    GroupCard {
                        NavigationLink(value: "settings") {
                            MenuRow(icon: "gearshape.fill", color: Color(hex: 0x8E8E93), title: "设置")
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer().frame(height: 24)
                }
            }
            .background(Brand.pageBg)
            .navigationTitle("我")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { key in
                switch key {
                case "settings":
                    SettingsView()
                case "album":
                    MomentsView()
                default:
                    ComingSoonView(title: titleFor(key))
                }
            }
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            Avatar(path: app.me?.avatarPath ?? "", size: 64, radius: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.me?.name ?? "")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Brand.label)
                Text("微信号：\((app.me?.username ?? "-"))")
                    .font(.system(size: 14))
                    .foregroundColor(Brand.subLabel)
                if let bio = app.me?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.system(size: 13))
                        .foregroundColor(Brand.subLabel)
                }
            }
            Spacer()
            Image(systemName: "qrcode")
                .font(.system(size: 16))
                .foregroundColor(Color.dyn(0xC7C7CC, 0x8E8E93))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .background(Brand.cellBg)
    }

    private func titleFor(_ key: String) -> String {
        switch key {
        case "service": return "服务"
        case "favorites": return "收藏"
        case "cards": return "卡包"
        case "stickers": return "表情"
        default: return "敬请期待"
        }
    }
}

/* ============================================================ 设置 */

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var confirmLogout = false
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                GroupCard {
                    MenuRow(icon: "person.crop.circle.fill", color: Color(hex: 0x3C9CFF),
                            title: "个人信息", detail: app.me?.name ?? "")
                    HairLine(inset: 54)
                    MenuRow(icon: "lock.fill", color: Color(hex: 0x8E8E93),
                            title: "账号与安全")
                    HairLine(inset: 54)
                    MenuRow(icon: "bell.fill", color: Color(hex: 0xFF9500),
                            title: "新消息通知")
                    HairLine(inset: 54)
                    MenuRow(icon: "hand.raised.fill", color: Color(hex: 0x07C160),
                            title: "隐私")
                }
                .padding(.top, 8)

                GroupCard {
                    MenuRow(icon: "info.circle.fill", color: Color(hex: 0x8E8E93),
                            title: "关于 CHRIS聊天", detail: "原生版 1.0")
                }

                Button {
                    confirmLogout = true
                } label: {
                    Text(busy ? "退出中…" : "退出登录")
                        .font(.system(size: 17))
                        .foregroundColor(Brand.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.cellBg))
                }
                .disabled(busy)
                .padding(.horizontal, 16)
                .padding(.top, 6)

                Spacer().frame(height: 30)
            }
        }
        .background(Brand.pageBg)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确定退出登录？", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                busy = true
                Task {
                    await app.logout()
                    busy = false
                }
            }
            Button("取消", role: .cancel) { }
        }
    }
}

