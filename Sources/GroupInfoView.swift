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
    /* 补齐的那几项：群公告、群名称（群主可改）、群屏蔽、清空记录、退群/解散 */
    @State private var muted = false
    @State private var announce = ""
    @State private var showAnnounce = false
    @State private var announceDraft = ""
    @State private var showRename = false
    @State private var nameDraft = ""
    @State private var showSearch = false
    @State private var confirmClear = false
    @State private var confirmQuit = false
    @State private var kickTarget: User?
    @State private var showQR = false
    @State private var muteAll = false
    @State private var kickMode = "kick"          // kick = 移出群聊，mute = 禁言

    private var isOwner: Bool { !ownerId.isEmpty && ownerId == app.me?.id }

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
            NavBar(title: L("聊天信息"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    headCard
                    memberCard
                    infoCard
                    switchCard
                    recordCard
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
            muted = chat.muted == true
            muteAll = chat.muteAll == true
            if let r = try? await API.shared.chatMembers(chatId: chat.id) {
                members = r.members
                ownerId = r.ownerId
                createdAt = r.createdAt
            }
            announce = chatAnnounceFromList()
            loading = false
        }
        .sheet(isPresented: $showAnnounce) { announceEditor }
        .sheet(isPresented: $showRename) { renameEditor }
        .sheet(isPresented: $showSearch) { ChatSearchView(chat: chat) }
        .sheet(isPresented: $showQR) { GroupQRView(chat: chat) }
        .confirmationDialog(L("清空聊天记录？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L("清空"), role: .destructive) { clearHistory() }
            Button(L("取消"), role: .cancel) { }
        }
        .confirmationDialog(isOwner ? "解散并退出群聊？" : "退出群聊？",
                            isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(isOwner ? "解散并退出" : "退出", role: .destructive) { quitGroup() }
            Button(L("取消"), role: .cancel) { }
        }
        .confirmationDialog(kickMode == "kick" ? "把 TA 移出群聊？" : "禁言 TA？",
                            isPresented: Binding(get: { kickTarget != nil }, set: { if !$0 { kickTarget = nil } }),
                            titleVisibility: .visible) {
            if kickMode == "kick" {
                Button(L("移出群聊"), role: .destructive) { kick() }
            } else {
                Button(L("禁言"), role: .destructive) { muteMember() }
            }
            Button(L("取消"), role: .cancel) { kickTarget = nil }
        }
    }

    private func muteMember() {
        guard let target = kickTarget else { return }
        Task {
            if let err = await API.shared.setMemberMuted(chatId: chat.id, userId: target.id, muted: true) {
                app.show(err)
            } else {
                app.show("已禁言 \(target.name)")
            }
            kickTarget = nil
        }
    }

    /// 群公告从会话列表数据里取（chat.announce），不用再发一次请求
    private func chatAnnounceFromList() -> String { chat.announce ?? "" }

    private var announceEditor: some View {
        editorSheet(title: isOwner ? "编辑群公告" : "群公告",
                    placeholder: "群公告内容（最多 500 字）",
                    text: $announceDraft, editable: isOwner) {
            saveAnnounce()
        }
    }

    private var renameEditor: some View {
        editorSheet(title: "修改群名称", placeholder: "群名称（最多 30 字）",
                    text: $nameDraft, editable: true) {
            saveName()
        }
    }

    private func editorSheet(title: String, placeholder: String,
                             text: Binding<String>, editable: Bool,
                             onSave: @escaping () -> Void) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(pf(15))
                            .foregroundColor(C.subLabel)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                    }
                    TextEditor(text: text)
                        .font(pf(15))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 11)
                        .padding(.top, 6)
                        .disabled(!editable)
                }
                .frame(height: 170)
                .background(C.cardBg)
                Spacer()
            }
            .background(C.pageBg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L("取消")) { showAnnounce = false; showRename = false }
                }
                if editable {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L("保存")) { onSave() }.font(pf(16, .medium))
                    }
                }
            }
        }
    }

    private func saveAnnounce() {
        Task {
            if let err = await API.shared.updateChatInfo(chatId: chat.id, name: chat.name, announce: announceDraft) {
                app.show(err)
            } else {
                announce = announceDraft
                showAnnounce = false
                app.show(L("群公告已更新"))
            }
        }
    }

    private func saveName() {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { app.show(L("群名称不能为空")); return }
        Task {
            if let err = await API.shared.updateChatInfo(chatId: chat.id, name: n, announce: announce) {
                app.show(err)
            } else {
                showRename = false
                await app.loadChats()
                app.show(L("群名称已修改"))
            }
        }
    }

    private func clearHistory() {
        Task {
            if let err = await API.shared.clearChat(chatId: chat.id) {
                app.show(err)
            } else {
                app.show(L("聊天记录已清空"))
            }
        }
    }

    private func quitGroup() {
        Task {
            let err = isOwner ? await API.shared.dismissGroup(chatId: chat.id)
                              : await API.shared.leaveGroup(chatId: chat.id)
            if let err = err {
                app.show(err)
            } else {
                await app.loadChats()
                dismiss()
                app.show(isOwner ? "群已解散" : "已退出群聊")
            }
        }
    }

    private func kick() {
        guard let target = kickTarget else { return }
        Task {
            if let err = await API.shared.kickMember(chatId: chat.id, userId: target.id) {
                app.show(err)
            } else {
                app.show("已把 \(target.name) 移出群聊")
                kickTarget = nil
                if let r = try? await API.shared.chatMembers(chatId: chat.id) { members = r.members }
                await app.loadChats()
            }
        }
    }

    /* ---------------------------------------------------------- 顶部：群头像 + 群名 */

    private var headCard: some View {
        HStack(spacing: 14) {
            Avatar(path: chat.avatar ?? "", size: 62, radius: 8)
            VStack(alignment: .leading, spacing: 5) {
                Text(chat.name)
                    .font(pf(17, .semibold))
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
                        /* 群主长按成员 → 移出群聊（对应清单里的「群踢人」） */
                        .contentShape(Rectangle())
                        .contextMenu {
                            if isOwner && u.id != app.me?.id {
                                Button {
                                    kickMode = "kick"
                                    kickTarget = u
                                } label: { Label(L("移出群聊"), systemImage: "person.badge.minus") }
                                Button {
                                    kickMode = "mute"
                                    kickTarget = u
                                } label: { Label(L("禁言"), systemImage: "speaker.slash") }
                                Button {
                                    Task { _ = await API.shared.setMemberMuted(chatId: chat.id, userId: u.id, muted: false) }
                                } label: { Label(L("取消禁言"), systemImage: "speaker.wave.2") }
                            } else {
                                Button { } label: { Label(L("只有群主能管理成员"), systemImage: "info.circle") }
                            }
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
            Button {
                nameDraft = chat.name
                if isOwner { showRename = true }
                else { app.show(L("只有群主能改群名称")) }
            } label: {
                infoRow("群聊名称", chat.name, chevron: true)
            }
            .buttonStyle(.plain)
            divider
            Button {
                announceDraft = announce
                showAnnounce = true
            } label: {
                infoRow("群公告", announce.isEmpty ? "未设置" : announce, chevron: true)
            }
            .buttonStyle(.plain)
            divider
            infoRow("群主", ownerName)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    private func infoRow(_ title: String, _ value: String, chevron: Bool = false) -> some View {
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
            if chevron { Chevron(size: 9, line: 1.6) }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .contentShape(Rectangle())
    }

    /* ---------------------------------------------------------- 置顶聊天 */

    private var switchCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("置顶聊天"))
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
            divider
            if isOwner {
                /* 群禁言：开了以后只有群主能说话（对应清单里的「群禁言」） */
                HStack(spacing: 10) {
                    Text(L("全员禁言"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { muteAll },
                        set: { v in
                            muteAll = v
                            Task {
                                if let err = await API.shared.setMuteAll(chatId: chat.id, on: v) {
                                    app.show(err)
                                    muteAll = !v
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(C.green)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                divider
            }
            /* 群屏蔽：消息免打扰（每个人自己设） */
            HStack(spacing: 10) {
                Text(L("消息免打扰"))
                    .font(pf(16))
                    .foregroundColor(C.label)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { muted },
                    set: { v in
                        muted = v
                        Task {
                            let now = await API.shared.setMuted(chatId: chat.id, muted: v)
                            muted = now
                            await app.loadChats()
                        }
                    }
                ))
                .labelsHidden()
                .tint(C.green)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    /* ---------------------------------------------------------- 记录 / 退群 */

    private var recordCard: some View {
        VStack(spacing: 0) {
            Button { showSearch = true } label: {
                HStack(spacing: 10) {
                    Text(L("查找聊天记录")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    Chevron(size: 9, line: 1.6)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            divider
            Button { showQR = true } label: {
                HStack(spacing: 10) {
                    Text(L("群二维码")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    Chevron(size: 9, line: 1.6)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            divider
            Button { confirmClear = true } label: {
                HStack(spacing: 10) {
                    Text(L("清空聊天记录")).font(pf(16)).foregroundColor(C.label)
                    Spacer(minLength: 8)
                    Chevron(size: 9, line: 1.6)
                }
                .padding(.horizontal, 14)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    /* ---------------------------------------------------------- 删除该聊天 */

    private var dangerCard: some View {
        VStack(spacing: 0) {
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
                    app.show(L("已删除该聊天"))
                }
            } label: {
                Text(L("删除该聊天"))
                    .font(pf(16))
                    .foregroundColor(C.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            divider
            /* 群主 = 解散并退出；普通成员 = 退出群聊 */
            Button { confirmQuit = true } label: {
                Text(isOwner ? "解散并退出群聊" : "退出群聊")
                    .font(pf(16))
                    .foregroundColor(C.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    private var divider: some View {
        Rectangle()
            .fill(C.hairline)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }
}
