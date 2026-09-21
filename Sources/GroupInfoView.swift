import SwiftUI

/* ============================================================
   群聊信息页（微信「聊天信息」那一页）
   · 顶部是群头像（就是服务器用成员头像拼的九宫格）+ 群名 + 人数
   · 群聊成员：5 个一行铺开，顺序和九宫格头像一致
   · 群聊名称 / 群公告 / 群主
   · 置顶聊天开关、删除该聊天
   ============================================================ */
struct GroupInfoView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var members: [User] = []
    @State private var ownerId = ""
    @State private var createdAt = ""
    @State private var loading = true
    @State private var pinned = false
    @State private var saving = false

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    private var ownerName: String {
        if let u = members.first(where: { $0.id == ownerId }) { return u.name }
        return "群主"
    }

    /// 建群时间：2026-09-21 → 2026年9月21日
    private var createdText: String {
        guard createdAt.count >= 10 else { return "" }
        let y = createdAt.prefix(4)
        let m = createdAt.dropFirst(5).prefix(2)
        let d = createdAt.dropFirst(8).prefix(2)
        return "\(Int(y) ?? 0)年\(Int(m) ?? 0)月\(Int(d) ?? 0)日"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "聊天信息", back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    headCard
                    memberCard
                    infoCard
                    switchCard
                    dangerCard
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            pinned = chat.pinned == true
            if let r = try? await API.shared.chatMembers(chatId: chat.id) {
                members = r.members
                ownerId = r.ownerId
                createdAt = r.createdAt
            }
            loading = false
        }
    }

    /* ---------------------------------------------------------- 顶部：群头像 + 群名 */

    private var headCard: some View {
        HStack(spacing: 14) {
            Avatar(path: chat.avatar ?? "", size: 62, radius: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(chat.name)
                    .font(pf(17, weight: .semibold))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                Text(members.isEmpty ? "群聊" : "\(members.count) 位成员" + (createdText.isEmpty ? "" : " · " + createdText + "创建"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    /* ---------------------------------------------------------- 群聊成员 */

    private var memberCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("群聊成员（\(members.count)）")
                .font(pf(13))
                .foregroundColor(C.subLabel)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if loading && members.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.bottom, 18)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(members) { u in
                        VStack(spacing: 5) {
                            Avatar(path: u.avatarPath, size: 50, radius: 6)
                            Text(u.name)
                                .font(pf(10.5))
                                .foregroundColor(C.subLabel)
                                .lineLimit(1)
                                .frame(width: 54)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    /* ---------------------------------------------------------- 群名 / 公告 / 群主 */

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("群聊名称", chat.name)
            divider
            infoRow("群公告", "未设置")
            divider
            infoRow("群主", ownerName)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(pf(16))
                .foregroundColor(C.label)
            Spacer(minLength: 8)
            Text(value)
                .font(pf(15))
                .foregroundColor(C.subLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    /* ---------------------------------------------------------- 置顶聊天 */

    private var switchCard: some View {
        HStack(spacing: 10) {
            Text("置顶聊天")
                .font(pf(16))
                .foregroundColor(C.label)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { pinned },
                set: { v in
                    pinned = v
                    Task {
                        let now = await API.shared.setPinned(chatId: chat.id, pinned: v)
                        pinned = now
                        await app.loadChats()
                    }
                }
            ))
            .labelsHidden()
            .tint(C.green)
            .disabled(saving)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    /* ---------------------------------------------------------- 删除该聊天 */

    private var dangerCard: some View {
        Button {
            Task {
                saving = true
                if let err = await API.shared.hideChat(chatId: chat.id) {
                    app.show(err)
                    saving = false
                    return
                }
                await app.loadChats()
                saving = false
                dismiss()
                app.show("已删除该聊天")
            }
        } label: {
            Text("删除该聊天")
                .font(pf(16))
                .foregroundColor(C.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(C.hairline)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}
