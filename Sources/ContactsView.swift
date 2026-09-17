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
                        app.show("加好友排在下一批")
                    } label: {
                        Text("＋")
                            .font(.system(size: 19))
                            .foregroundColor(C.label)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                }

                SearchBoxLeft(text: $keyword)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(C.pageBg)

                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        List {
                            if keyword.isEmpty {
                                ForEach(funcs.indices, id: \.self) { i in
                                    funcRow(funcs[i])
                                        .listRowInsets(EdgeInsets())
                                        .listRowSeparator(.hidden)
                                        .listRowBackground(Color.clear)
                                }
                            }

                            ForEach(sections) { section in
                                ForEach(section.users) { user in
                                    NavigationLink(value: user) {
                                        contactRow(user)
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(C.cardBg)
                                    .id(user.id == section.users.first?.id ? "letter-\(section.letter)" : user.id)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .environment(\.defaultMinListRowHeight, 0)
                        .scrollContentBackground(.hidden)
                        .background(C.cardBg)
                        .refreshable { await app.loadContacts() }

                        if keyword.isEmpty && !sections.isEmpty {
                            indexBar(proxy)
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
                } else {
                    ComingSoonView(title: key)
                }
            }
        }
        .task { await app.loadContacts() }
    }

    /* ---------------------------------------------------------- 顶部功能行 */

    private func funcRow(_ item: (String, String, Color, String)) -> some View {
        Button {
            app.show(item.0 + " 排在下一批")
        } label: {
            HStack(spacing: L.ctGap) {
                FuncIcon(markup: item.1, bg: item.2, size: L.avatar)
                Text(item.0)
                    .font(.system(size: 17))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
                Chevron(size: 9, line: 1.6)
                    .padding(.trailing, 3)
            }
            .padding(.horizontal, L.ctPadH)
            .frame(height: L.ctRowH)
            .background(C.cardBg)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuPressStyle())
    }

    private func contactRow(_ user: User) -> some View {
        HStack(spacing: L.ctGap) {
            Avatar(path: user.avatarPath, size: L.avatar, radius: 8)
            Text(user.name)
                .font(.system(size: 17))
                .foregroundColor(C.label)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, L.ctPadH)
        .frame(height: L.ctRowH)
        .contentShape(Rectangle())
    }

    /* ---------------------------------------------------------- 右侧 A-Z */

    private func indexBar(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 1) {
            SVGIcon(markup: I.searchRow, size: 13, color: C.arrow)
                .padding(.bottom, 3)
            ForEach(sections) { section in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("letter-\(section.letter)", anchor: .top)
                    }
                } label: {
                    Text(section.letter)
                        .font(.system(size: 12.5))
                        .foregroundColor(C.arrow)
                        .frame(width: 22, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 2)
    }
}

/* ============================================================ 个人名片 */

struct ContactCardView: View {
    let user: User
    var onOpenChat: (Chat) -> Void
    var onOpenMoments: (String) -> Void

    @EnvironmentObject var app: AppState
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
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(C.label)
                            if user.gender == "male" {
                                Circle().fill(Color(hex: 0x10AEFF)).frame(width: 14, height: 14)
                                    .overlay(Image(systemName: "person.fill").font(.system(size: 8)).foregroundColor(.white))
                            } else if user.gender == "female" {
                                Circle().fill(Color(hex: 0xFA6E9A)).frame(width: 14, height: 14)
                                    .overlay(Image(systemName: "person.fill").font(.system(size: 8)).foregroundColor(.white))
                            }
                        }
                        if let bio = user.bio, !bio.isEmpty {
                            Text(bio).font(.system(size: 14)).foregroundColor(C.subLabel)
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
                                    Text("朋友圈").font(.system(size: 16)).foregroundColor(C.label)
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
                            .font(.system(size: 17))
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
            Text(title).font(.system(size: 16)).foregroundColor(C.label)
            Spacer()
            Text(value).font(.system(size: 16)).foregroundColor(C.subLabel)
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
