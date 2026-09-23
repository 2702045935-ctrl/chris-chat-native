import SwiftUI

/* ============================================================
   搜索（微信点会话页那个搜索框进的就是这一页）
   · 顶部：搜索框（自动聚焦）+「取消」
   · 没输内容时：「搜索指定内容」一排（聊天记录 / 联系人 / 群聊 / 朋友圈 / 视频号）+「最近搜索」
   · 输了内容：分「聊天记录 / 联系人 / 群聊」三组出结果，点一条直接进聊天/名片
   ============================================================ */
struct SearchPage: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var onOpenChat: ((Chat) -> Void)? = nil
    var onOpenUser: ((User) -> Void)? = nil

    @State private var q = ""
    @State private var scope = "all"
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "chris.searchHistory") ?? []
    @FocusState private var focused: Bool

    private let scopes: [(String, String, String)] = [
        ("all", "全部", "magnifyingglass"),
        ("chat", "聊天记录", "bubble.left.and.bubble.right"),
        ("user", "联系人", "person.crop.circle"),
        ("group", "群聊", "person.2"),
        ("moments", "朋友圈", "photo.on.rectangle.angled"),
        ("feed", "视频号", "play.rectangle")
    ]

    private var key: String { q.trimmingCharacters(in: .whitespaces) }

    private var chats: [Chat] {
        let base = app.chats.filter { $0.botRank != 0 }
        if key.isEmpty { return [] }
        return base.filter { c in
            chatTitle(c).localizedCaseInsensitiveContains(key)
        }
    }

    /// 会话标题：群聊用群名，单聊用对方的昵称（本地算，不依赖别的辅助函数）
    private func chatTitle(_ c: Chat) -> String {
        if let t = c.title, !t.isEmpty { return t }
        if let peerId = (c.memberIds ?? []).first(where: { $0 != (app.me?.id ?? "") }),
           let u = app.contact(for: peerId) {
            return u.name
        }
        return Tr("聊天")
    }

    /// 会话头像：群聊用群头像，单聊用对方头像
    private func chatAvatar(_ c: Chat) -> String {
        if let a = c.avatar, !a.isEmpty { return a }
        if let peerId = (c.memberIds ?? []).first(where: { $0 != (app.me?.id ?? "") }),
           let u = app.contact(for: peerId) {
            return u.avatarPath
        }
        return ""
    }
    private var groups: [Chat] { scope == "all" || scope == "group" ? chats.filter { $0.type == "group" } : [] }
    private var directChats: [Chat] { scope == "group" ? [] : chats.filter { $0.type != "group" } }
    private var contacts: [User] {
        if key.isEmpty || scope == "chat" || scope == "group" { return [] }
        return app.contacts.filter { ($0.nickname ?? "").localizedCaseInsensitiveContains(key)
            || ($0.username ?? "").localizedCaseInsensitiveContains(key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(C.searchIcon)
                    TextField(Tr("搜索"), text: $q)
                        .font(pf(14.5))
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { remember(key) }
                    if !key.isEmpty {
                        Button { q = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15)).foregroundColor(C.searchIcon)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.searchBg))

                Button { dismiss() } label: {
                    Text(Tr("取消")).font(pf(16)).foregroundColor(C.label)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if key.isEmpty {
                        scopeRow
                        if !recent.isEmpty { recentBlock }
                        Text(Tr("输入关键词就能搜会话、联系人和群聊"))
                            .font(pf(12.5)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        scopeRow
                        if !directChats.isEmpty { sectionBlock(Tr("聊天记录"), directChats, isGroup: false) }
                        if !groups.isEmpty { sectionBlock(Tr("群聊"), groups, isGroup: true) }
                        if !contacts.isEmpty { contactBlock }
                        if directChats.isEmpty && groups.isEmpty && contacts.isEmpty {
                            Text(Tr("没有找到 ") + "「\(key)」")
                                .font(pf(14)).foregroundColor(C.subLabel)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focused = true }
        .onChange(of: key) { v in if v.count > 1 { remember(v) } }
    }

    private var scopeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(scopes, id: \.0) { s in
                    let on = (scope == s.0)
                    Button { scope = s.0 } label: {
                        HStack(spacing: 5) {
                            Image(systemName: s.2).font(.system(size: 12, weight: .medium))
                            Text(Tr(s.1)).font(pf(13))
                        }
                        .foregroundColor(on ? .white : C.subLabel)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(on ? C.green : C.cardBg))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private var recentBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Tr("最近搜索")).font(pf(13)).foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Button { recent = []; UserDefaults.standard.set(recent, forKey: "chris.searchHistory") } label: {
                    Text(Tr("清空")).font(pf(13)).foregroundColor(C.green)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            ForEach(recent, id: \.self) { r in
                Button { q = r } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 14)).foregroundColor(C.subLabel)
                        Text(r).font(pf(15)).foregroundColor(C.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairLine(inset: 40)
            }
        }
        .background(C.cardBg)
    }

    private func sectionBlock(_ title: String, _ list: [Chat], isGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(pf(13)).foregroundColor(C.subLabel)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            ForEach(list) { c in
                Button {
                    onOpenChat?(c)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Avatar(path: chatAvatar(c), size: 40, radius: isGroup ? 6 : 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chatTitle(c)).font(pf(16)).foregroundColor(C.label)
                            if let p = c.lastMessage?.preview, !p.isEmpty {
                                Text(p).font(pf(12.5)).foregroundColor(C.subLabel).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairLine(inset: 66)
            }
        }
        .background(C.cardBg)
        .padding(.top, 10)
    }

    private var contactBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Tr("联系人")).font(pf(13)).foregroundColor(C.subLabel)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
            ForEach(contacts) { u in
                Button {
                    onOpenUser?(u)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Avatar(path: u.avatarPath, size: 40, radius: 4)
                        Text(u.name).font(pf(16)).foregroundColor(C.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HairLine(inset: 66)
            }
        }
        .background(C.cardBg)
        .padding(.top, 10)
    }

    private func remember(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var list = recent.filter { $0 != t }
        list.insert(t, at: 0)
        recent = Array(list.prefix(10))
        UserDefaults.standard.set(recent, forKey: "chris.searchHistory")
    }
}
