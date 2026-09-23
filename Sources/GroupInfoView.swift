import SwiftUI

/* ============================================================
   群聊信息页（微信「聊天信息」那一页）
   · 顶部是群头像（就是服务器用成员头像拼的九宫格）+ 群名 + 人数
   · 群聊成员：5 个一行铺开，顺序和九宫格头像一致
   · 群聊名称 / 群公告 / 群主
   · 置顶聊天开关、删除该聊天
   ============================================================ */
struct GroupInfoView: View {
    @ObservedObject private var lang = LangStore.shared
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
    /// 加人：选人面板 + 删除成员模式（微信群管理那个「＋ / －」）
    @State private var showAdd = false
    @State private var removing = false

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
            NavBar(title: Tr("聊天信息"), back: { dismiss() })

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
        .sheet(isPresented: $showAdd) {
            GroupAddMembersView(chat: chat, existing: members.map { $0.id }) { names in
                app.show(names.isEmpty ? Tr("没有新增成员") : (Tr("已邀请 ") + names.joined(separator: "、") + Tr(" 进群")))
                Task {
                    if let r = try? await API.shared.chatMembers(chatId: chat.id) { members = r.members }
                    await app.loadChats()
                }
            }
        }
        .confirmationDialog(Tr("清空聊天记录？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(Tr("清空"), role: .destructive) { clearHistory() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(isOwner ? "解散并退出群聊？" : "退出群聊？",
                            isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(isOwner ? "解散并退出" : "退出", role: .destructive) { quitGroup() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(kickMode == "kick" ? "把 TA 移出群聊？" : "禁言 TA？",
                            isPresented: Binding(get: { kickTarget != nil }, set: { if !$0 { kickTarget = nil } }),
                            titleVisibility: .visible) {
            if kickMode == "kick" {
                Button(Tr("移出群聊"), role: .destructive) { kick() }
            } else {
                Button(Tr("禁言"), role: .destructive) { muteMember() }
            }
            Button(Tr("取消"), role: .cancel) { kickTarget = nil }
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
                    Button(Tr("取消")) { showAnnounce = false; showRename = false }
                }
                if editable {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(Tr("保存")) { onSave() }.font(pf(16, .medium))
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
                app.show(Tr("群公告已更新"))
            }
        }
    }

    private func saveName() {
        let n = nameDraft.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { app.show(Tr("群名称不能为空")); return }
        Task {
            if let err = await API.shared.updateChatInfo(chatId: chat.id, name: n, announce: announce) {
                app.show(err)
            } else {
                showRename = false
                await app.loadChats()
                app.show(Tr("群名称已修改"))
            }
        }
    }

    private func clearHistory() {
        Task {
            if let err = await API.shared.clearChat(chatId: chat.id) {
                app.show(err)
            } else {
                app.show(Tr("聊天记录已清空"))
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
            HStack(spacing: 6) {
                Text("群聊成员（\(members.count)）")
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                /* 微信群管理那套：右上角一个「＋」加人、一个「－」切到删除模式（群主才有） */
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(C.label)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                if isOwner {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { removing.toggle() }
                    } label: {
                        Image(systemName: removing ? "checkmark" : "minus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(removing ? C.green : C.label)
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if loading && members.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.bottom, 18)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(members) { u in
                        VStack(spacing: 5) {
                            ZStack(alignment: .topLeading) {
                                Avatar(path: u.avatarPath, size: 50, radius: 6)
                                /* 删除模式：群主以外的人左上角挂一个红「－」，点它就移出 */
                                if removing && isOwner && u.id != app.me?.id {
                                    Button {
                                        kickMode = "kick"
                                        kickTarget = u
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(C.red)
                                            .background(Circle().fill(Color.white))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: -6, y: -6)
                                }
                            }
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
                                } label: { Label(Tr("移出群聊"), systemImage: "person.badge.minus") }
                                Button {
                                    kickMode = "mute"
                                    kickTarget = u
                                } label: { Label(Tr("禁言"), systemImage: "speaker.slash") }
                                Button {
                                    Task { _ = await API.shared.setMemberMuted(chatId: chat.id, userId: u.id, muted: false) }
                                } label: { Label(Tr("取消禁言"), systemImage: "speaker.wave.2") }
                            } else {
                                Button { } label: { Label(Tr("只有群主能管理成员"), systemImage: "info.circle") }
                            }
                        }
                    }
                    /* 最后一个格子是「＋」：拉人进群（微信就是这样排的） */
                    VStack(spacing: 5) {
                        Button { showAdd = true } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(C.hairline, lineWidth: 1)
                                    .frame(width: 50, height: 50)
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundColor(C.subLabel)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(Tr("加人")).font(pf(10.5)).foregroundColor(C.subLabel)
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
                else { app.show(Tr("只有群主能改群名称")) }
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
                Text(Tr("置顶聊天"))
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
                    Text(Tr("全员禁言"))
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
                Text(Tr("消息免打扰"))
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
                    Text(Tr("查找聊天记录")).font(pf(16)).foregroundColor(C.label)
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
                    Text(Tr("群二维码")).font(pf(16)).foregroundColor(C.label)
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
                    Text(Tr("清空聊天记录")).font(pf(16)).foregroundColor(C.label)
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
                    app.show(Tr("已删除该聊天"))
                }
            } label: {
                Text(Tr("删除该聊天"))
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

/* ============================================================
   单聊的「聊天信息」页 —— 微信里点右上「⋯」出来的就是这一页：
   · 顶上是对方：头像 + 昵称 + 星言号（点一下进名片）
   · 消息免打扰、置顶聊天
   · 音视频通话 / 查找聊天记录 / 设置当前聊天背景
   · 清空聊天记录
   · 删除该聊天
   ============================================================ */
struct DirectChatInfoView: View {
    @ObservedObject private var lang = LangStore.shared
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var peer: User?
    @State private var pinned = false
    @State private var muted = false
    @State private var showSearch = false
    @State private var showCard = false
    @State private var confirmClear = false
    @State private var confirmDelete = false
    @State private var showCall = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("聊天信息"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    peerCard
                    switchCard
                    toolCard
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
            if let r = try? await API.shared.chatMembers(chatId: chat.id) {
                peer = r.members.first { $0.id != app.me?.id }
            }
            /* 会话列表里没带成员时（比如从搜索进来的），按 id 再捞一次 */
            if peer == nil, let other = chat.memberIds?.first(where: { $0 != app.me?.id }) {
                peer = try? await API.shared.user(id: other)
            }
        }
        .sheet(isPresented: $showSearch) { ChatSearchView(chat: chat) }
        .sheet(isPresented: $showCard) {
            if let p = peer {
                ContactCardView(user: p,
                                onOpenChat: { _ in showCard = false },
                                onOpenMoments: { _ in showCard = false })
                    .environmentObject(app)
            }
        }
        .confirmationDialog(Tr("清空聊天记录？"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(Tr("清空"), role: .destructive) { clearHistory() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(Tr("删除该聊天？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) { deleteChat() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .confirmationDialog(Tr("音视频通话"), isPresented: $showCall, titleVisibility: .hidden) {
            Button(Tr("语音通话")) { start(video: false) }
            Button(Tr("视频通话")) { start(video: true) }
            Button(Tr("取消"), role: .cancel) { }
        }
    }

    /* ---------------------------------------------------------- 对方 */

    private var peerCard: some View {
        Button {
            if peer != nil { showCard = true }
        } label: {
            HStack(spacing: 12) {
                Avatar(path: peer?.avatarPath ?? "", size: 46, radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(peer?.name ?? chat.name).font(pf(17)).foregroundColor(C.label)
                    if let un = peer?.username, !un.isEmpty {
                        Text(Tr("星言号") + "：" + un).font(pf(13)).foregroundColor(C.subLabel)
                    }
                }
                Spacer(minLength: 8)
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 14)
            .frame(height: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    /* ---------------------------------------------------------- 开关 */

    private var switchCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(Tr("消息免打扰")).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { muted },
                    set: { v in
                        muted = v
                        Task {
                            muted = await API.shared.setMuted(chatId: chat.id, muted: v)
                            await app.loadChats()
                        }
                    }
                ))
                .labelsHidden()
                .tint(C.green)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            divider
            HStack(spacing: 10) {
                Text(Tr("置顶聊天")).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { pinned },
                    set: { v in
                        pinned = v
                        Task {
                            pinned = await API.shared.setPinned(chatId: chat.id, pinned: v)
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

    /* ---------------------------------------------------------- 功能行 */

    private var toolCard: some View {
        VStack(spacing: 0) {
            row(Tr("音视频通话")) { showCall = true }
            divider
            row(Tr("查找聊天记录")) { showSearch = true }
            divider
            row(Tr("设置当前聊天背景")) {
                app.show(Tr("换聊天背景：点「我 → 设置 → 聊天背景」"))
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
    }

    private func row(_ title: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 8)
                Chevron(size: 9, line: 1.6)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 危险操作 */

    private var dangerCard: some View {
        VStack(spacing: 0) {
            Button { confirmClear = true } label: {
                Text(Tr("清空聊天记录"))
                    .font(pf(16))
                    .foregroundColor(C.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            divider
            Button { confirmDelete = true } label: {
                Text(Tr("删除该聊天"))
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

    /* ---------------------------------------------------------- 干活 */

    private func start(video: Bool) {
        let p = peer
        CallCenter.shared.start(peerId: p?.id ?? "",
                                name: p?.name ?? chat.name,
                                avatar: p?.avatarPath ?? "",
                                video: video)
        dismiss()
    }

    private func clearHistory() {
        Task {
            if let err = await API.shared.clearChat(chatId: chat.id) {
                app.show(err)
            } else {
                app.show(Tr("聊天记录已清空"))
            }
        }
    }

    private func deleteChat() {
        Task {
            if let err = await API.shared.hideChat(chatId: chat.id) {
                app.show(err)
                return
            }
            await app.loadChats()
            dismiss()
            app.show(Tr("已删除该聊天"))
        }
    }
}

/* ============================================================
   群加人：从好友里多选，勾完点「完成」就拉进群。
   已经在群里的人不显示（拉重复了服务端也会拒）。
   ============================================================ */

struct GroupAddMembersView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let chat: Chat
    /// 已经在群里的人（不列出来）
    let existing: [String]
    /// 加完后回调（新进来的名字）
    var onDone: ([String]) -> Void

    @State private var keyword = ""
    @State private var picked: Set<String> = []
    @State private var busy = false

    private var candidates: [User] {
        let set = Set(existing)
        let base = app.contacts.filter { !set.contains($0.id) && $0.id != app.me?.id }
        guard !keyword.isEmpty else { return base }
        return base.filter { $0.name.contains(keyword) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("加人"), back: { dismiss() }) {
                Button { submit() } label: {
                    Text(busy ? Tr("加入中…") : Tr("完成"))
                        .font(pf(17))
                        .foregroundColor(picked.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty || busy)
            }

            SearchBoxCenter(text: $keyword)
                .padding(L.searchPad)

            if candidates.isEmpty {
                Text(Tr("没有可以邀请的好友了"))
                    .font(pf(14)).foregroundColor(C.subLabel)
                    .padding(.top, 40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(candidates) { u in
                            Button {
                                if picked.contains(u.id) { picked.remove(u.id) } else { picked.insert(u.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Avatar(path: u.avatarPath, size: 40, radius: 4)
                                    Text(u.name).font(pf(17)).foregroundColor(C.label).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: picked.contains(u.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(picked.contains(u.id) ? C.green : C.subLabel)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 60)
                                .background(C.cardBg)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            HairLine(inset: 68)
                        }
                    }
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }

    private func submit() {
        guard !picked.isEmpty, !busy else { return }
        busy = true
        let ids = Array(picked)
        Task {
            let r = await API.shared.addGroupMembers(chatId: chat.id, userIds: ids)
            busy = false
            if let err = r.error {
                app.show(err)
                return
            }
            onDone(r.added)
            dismiss()
        }
    }
}
