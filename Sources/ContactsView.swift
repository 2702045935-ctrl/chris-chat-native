import SwiftUI

struct ContactSection: Identifiable {
    var id: String { letter }
    let letter: String
    let users: [User]
}

struct ContactRow: View {
    let user: User

    var body: some View {
        HStack(spacing: 12) {
            Avatar(path: user.avatarPath, size: 40, radius: 4)
            Text(user.name)
                .font(.system(size: 17))
                .foregroundColor(Brand.label)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .contentShape(Rectangle())
    }
}

struct ContactsView: View {
    @EnvironmentObject var app: AppState

    @State private var keyword = ""
    @State private var path = NavigationPath()

    private var filtered: [User] {
        guard !keyword.isEmpty else { return app.contacts }
        return app.contacts.filter { $0.name.contains(keyword) || ($0.username ?? "").contains(keyword) }
    }

    private var sections: [ContactSection] {
        var buckets: [String: [User]] = [:]
        for user in filtered {
            buckets[pinyinInitial(user.name), default: []].append(user)
        }
        return buckets.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }.map { key in
            ContactSection(letter: key, users: (buckets[key] ?? []).sorted { $0.name < $1.name })
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 8) {
                SearchBar(text: $keyword)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.users) { user in
                                NavigationLink(value: user) {
                                    ContactRow(user: user)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Brand.cellBg)
                            }
                        } header: {
                            Text(section.letter)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Brand.subLabel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                                .background(Brand.pageBg)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Brand.cellBg)
                .refreshable { await app.loadContacts() }
            }
            .background(Brand.cellBg)
            .navigationTitle("通讯录")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: User.self) { user in
                ContactCardView(user: user) { chat in
                    path.append(chat)
                }
            }
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
        }
        .task { await app.loadContacts() }
    }
}

/* ============================================================ 个人名片 */

struct ContactCardView: View {
    let user: User
    var onOpenChat: (Chat) -> Void

    @EnvironmentObject var app: AppState
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    Avatar(path: user.avatarPath, size: 64, radius: 8)
                    HStack(spacing: 6) {
                        Text(user.name)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(Brand.label)
                        if user.gender == "male" {
                            Image(systemName: "mustache.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: 0x10AEFF))
                        } else if user.gender == "female" {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: 0xFA6E9A))
                        }
                    }
                    if let bio = user.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 14))
                            .foregroundColor(Brand.subLabel)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .background(Brand.cellBg)

                GroupCard {
                    row("微信号", user.username ?? "-")
                    HairLine(inset: 16)
                    row("地区", (user.region?.isEmpty == false) ? user.region! : "未设置")
                    if let phone = user.phone, !phone.isEmpty {
                        HairLine(inset: 16)
                        row("电话", phone)
                    }
                }

                Button {
                    openChat()
                } label: {
                    Text(busy ? "打开中…" : "发消息")
                        .font(.system(size: 17))
                        .foregroundColor(Brand.green)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.cellBg))
                }
                .disabled(busy)
                .padding(.horizontal, 16)

                Spacer().frame(height: 30)
            }
        }
        .background(Brand.pageBg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16))
                .foregroundColor(Brand.label)
            Spacer()
            Text(value)
                .font(.system(size: 16))
                .foregroundColor(Brand.subLabel)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func openChat() {
        if user.id == app.me?.id, let first = app.chats.first(where: { $0.title == user.name }) {
            onOpenChat(first)
            return
        }
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

