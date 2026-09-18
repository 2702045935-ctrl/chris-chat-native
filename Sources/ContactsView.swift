import SwiftUI

struct ContactSection: Identifiable {
    var id: String { letter }
    let letter: String
    let users: [User]
}

struct ContactsView: View {
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var path = NavigationPath()
    @State private var bubble: String?
    @State private var bubbleTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @ObservedObject private var realtime = Realtime.shared

    private let funcs: [(String, String, Color, String)] = [
        ("新的朋友", I.newFriends, Color(hex: 0xF0A75C), "newFriends"),
        ("仅聊天的朋友", I.chatOnly, Color(hex: 0x9A9AA0), "chatOnly"),
        ("标签", I.tag, Color(hex: 0x6D9ED6), "tags"),
        ("服务号", I.service, Color(hex: 0x6D9ED6), "service"),
        ("企业微信联系人", I.workMate, Color(hex: 0x4FA383), "work"),
        ("我的企业", I.myWork, Color(hex: 0x4FA383), "myWork")
    ]

    private var filtered: [User] {
        let sorted = app.contacts.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        guard !keyword.isEmpty else { return sorted }
        return sorted.filter { $0.name.contains(keyword) || ($0.username ?? "").contains(keyword) }
    }

    private var sections: [ContactSection] {
        var order: [String] = []
        var map: [String: [User]] = [:]
        for u in filtered {
            let k = pinyinInitial(u.name)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(u)
        }
        return order.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { ContactSection(letter: $0, users: map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                NavBar(title: "通讯录") {
                    Button {
                        path.append("addFriend")
                    } label: {
                        Text("＋")
                            .font(pf(19))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }

                SearchBoxCenter(text: $keyword, externalFocus: $searchFocused)
                    .padding(L.searchPad)
                    .background(C.pageBg)

                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if keyword.isEmpty {
                                    VStack(spacing: 0) {
                                        ForEach(funcs.indices, id: \.self) { i in
                                            funcRow(funcs[i])
                                            if i < funcs.count - 1 {
                                                HairLine(inset: L.ctTextX)
                                            }
                                        }
                                    }
                                    .background(C.cardBg)
                                }

                                ForEach(sections) { section in
                                    // 字母分组头（A/B/C…，参考图里就在左边 x16，一行 28 高）
                                    HStack(spacing: 0) {
                                        Text(section.letter)
                                            .font(pf(L.ctHeadSize))
                                            .foregroundColor(Color(hex: 0x737373))
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.leading, 16)
                                    .frame(height: L.ctHeadH)
                                    .background(C.cardBg)
                                    .id("letter-\(section.letter)")

                                    ForEach(section.users.indices, id: \.self) { i in
                                        let user = section.users[i]
                                        VStack(spacing: 0) {
                                            if i > 0 { HairLine(inset: L.ctTextX) }
                                            NavigationLink(value: user) {
                                                contactRow(user)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .background(C.cardBg)
                                        .id(user.id)
                                    }
                                }
                            }
                        }
                        .background(C.cardBg)
                        .refreshable { await app.loadContacts() }

                        if keyword.isEmpty && !sections.isEmpty {
                            ContactIndexBar(
                                available: Set(sections.map { $0.letter }),
                                onPick: { L in
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        proxy.scrollTo("letter-\(L)", anchor: .top)
                                    }
                                    showBubble(L)
                                },
                                onSearch: {
                                    keyword = ""
                                    searchFocused = true
                                }
                            )
                            .padding(.trailing, 8)
                            .frame(maxHeight: .infinity, alignment: .center)
                        }

                        if let b = bubble {
                            LetterBubble(letter: b)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .offset(y: -56)
                        }
                    }
                }
            }
            .background(C.pageBg.ignoresSafeArea(edges: .bottom))
            .background(C.navBg.ignoresSafeArea(edges: .top))
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: User.self) { user in
                ContactCardView(user: user,
                                onOpenChat: { chat in path.append(chat) },
                                onOpenMoments: { id in path.append("moments:" + id) })
            }
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
            .navigationDestination(for: String.self) { key in
                if key.hasPrefix("moments:") {
                    let uid = String(key.dropFirst(8))
                    MomentsView(target: app.contacts.first { $0.id == uid })
                } else if key == "newFriends" {
                    NewFriendsView()
                } else if key == "addFriend" {
                    AddFriendView()
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        .task { await app.loadContacts() }
        // 有人加你 / 改资料 / 上下线 → 通讯录立刻刷新
        .onChange(of: realtime.event) { ev in
            if ev.type == "friend" || ev.type == "presence" || ev.type == "profile" || ev.user != nil {
                Task { await app.loadContacts() }
            }
        }
    }

    private func showBubble(_ letter: String) {
        bubble = letter
        bubbleTask?.cancel()
        bubbleTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { bubble = nil }
        }
    }

    /* ---------------------------------------------------------- 顶部功能行 */

    private func funcRow(_ item: (String, String, Color, String)) -> some View {
        Button {
            switch item.3 {
            case "newFriends": path.append("newFriends")
            case "chatOnly": app.show("仅聊天的朋友：只有聊天记录、没加好友的人会出现在这里")
            case "tags": app.show("标签：还没建过标签")
            case "service": app.show("服务号：暂时没有关注的服务号")
            case "work": app.show("企业微信联系人：还没绑定微信企业")
            default: app.show("我的企业：还没创建企业")
            }
        } label: {
            HStack(spacing: L.ctGap) {
                FuncIcon(markup: item.1, bg: item.2, size: L.ctIcon)
                Text(item.0)
                    .font(pf(L.ctNameSize))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
            }
            .padding(.leading, L.ctPadL)
            .frame(height: L.ctRowH)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }

    private func contactRow(_ user: User) -> some View {
        HStack(spacing: L.ctGap) {
            Avatar(path: user.avatarPath, size: L.ctAvatar, radius: 6)
            Text(user.name)
                .font(pf(L.ctNameSize))
                .foregroundColor(C.label)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, L.ctPadL)
        .frame(height: L.ctRowH)
        .contentShape(Rectangle())
    }

    /* ---------------------------------------------------------- 右侧 A-Z */

    private func indexBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            ForEach(sections) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("letter-\(section.letter)", anchor: .top)
                    }
                } label: {
                    Text(section.letter)
                        .font(pf(L.ctIdxSize))
                        .foregroundColor(Color(hex: 0x555555))
                        .frame(width: 22, height: L.ctIdxItemH)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 5.7)
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/* ============================================================ 个人名片 */

struct ContactCardView: View {
    let user: User
    var onOpenChat: (Chat) -> Void
    var onOpenMoments: (String) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var thumbs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "", back: nil) {
                EmptyView()
            }
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Avatar(path: user.avatarPath, size: 64, radius: 8)
                        HStack(spacing: 6) {
                            Text(user.name)
                                .font(pf(20, .medium))
                                .foregroundColor(C.label)
                            if user.gender == "male" {
                                Circle().fill(Color(hex: 0x10AEFF)).frame(width: 14, height: 14)
                                    .overlay(Image(systemName: "person.fill").font(pf(8)).foregroundColor(.white))
                            } else if user.gender == "female" {
                                Circle().fill(Color(hex: 0xFA6E9A)).frame(width: 14, height: 14)
                                    .overlay(Image(systemName: "person.fill").font(pf(8)).foregroundColor(.white))
                            }
                        }
                        if let bio = user.bio, !bio.isEmpty {
                            Text(bio).font(pf(14)).foregroundColor(C.subLabel)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .background(C.cardBg)

                    Spacer().frame(height: 8)

                    GroupCard {
                        infoRow("微信号", user.username ?? "-")
                        HairLine(inset: 16)
                        infoRow("地区", (user.region?.isEmpty == false) ? user.region! : "未设置")
                        if let phone = user.phone, !phone.isEmpty {
                            HairLine(inset: 16)
                            infoRow("电话", phone)
                        }
                        if !thumbs.isEmpty {
                            HairLine(inset: 16)
                            Button {
                                onOpenMoments(user.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("朋友圈").font(pf(16)).foregroundColor(C.label)
                                    Spacer()
                                    HStack(spacing: 4) {
                                        ForEach(thumbs.prefix(4), id: \.self) { p in
                                            RemoteImage(path: p)
                                                .frame(width: 44, height: 44)
                                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                        }
                                    }
                                    Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 64)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer().frame(height: 8)

                    Button {
                        openChat()
                    } label: {
                        Text(busy ? "打开中…" : "发消息")
                            .font(pf(17))
                            .foregroundColor(C.green)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(C.cardBg)
                    }
                    .disabled(busy)

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .task {
            if let list = try? await API.shared.moments(userId: user.id) {
                thumbs = list.flatMap { $0.images ?? [] }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer()
            Text(value).font(pf(16)).foregroundColor(C.subLabel)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func openChat() {
        busy = true
        Task {
            if let chat = try? await API.shared.openDirect(userId: user.id) {
                onOpenChat(chat)
            } else {
                app.show("打不开聊天")
            }
            busy = false
        }
    }
}
