import SwiftUI

/* ============================================================ 个人信息 */

struct ProfileEditView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var bio = ""
    @State private var region = ""
    @State private var gender = "male"
    @State private var phone = ""
    @State private var showPhoto = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "个人信息", back: { dismiss() }) {
                Button {
                    save()
                } label: {
                    Text(busy ? "保存中…" : "保存")
                        .font(pf(17))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        Button {
                            showPhoto = true
                        } label: {
                            HStack(spacing: 12) {
                                Text("头像").font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                Avatar(path: app.me?.avatarPath ?? "", size: 56, radius: 6)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 72)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        field("昵称", $nickname)
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        HStack(spacing: 12) {
                            Text("性别").font(pf(17)).foregroundColor(C.label)
                            Spacer()
                            Picker("", selection: $gender) {
                                Text("男").tag("male")
                                Text("女").tag("female")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        HairLine(inset: 16)
                        field("地区", $region)
                        HairLine(inset: 16)
                        field("个性签名", $bio)
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        field("手机号", $phone)
                    }

                    Text("手机号一年只能改一次；头像、昵称、地区、签名想改就改。")
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .onAppear {
            nickname = app.me?.nickname ?? ""
            bio = app.me?.bio ?? ""
            region = app.me?.region ?? ""
            gender = app.me?.gender == "female" ? "female" : "male"
            phone = app.me?.phone ?? ""
        }
        .sheet(isPresented: $showPhoto) {
            PhotoPicker { image in changeAvatar(image) }
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title).font(pf(17)).foregroundColor(C.label).frame(width: 76, alignment: .leading)
            TextField("", text: text)
                .font(pf(17))
                .foregroundColor(C.label)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private func changeAvatar(_ image: UIImage) {
        busy = true
        Task {
            if let url = try? await API.shared.upload(image: image) {
                await API.shared.updateMe(["avatar": url])
                app.me = try? await API.shared.me()
                app.show("头像换好了")
            }
            busy = false
        }
    }

    private func save() {
        busy = true
        Task {
            var fields: [String: Any] = [
                "nickname": nickname,
                "bio": bio,
                "region": region,
                "gender": gender
            ]
            if !phone.isEmpty && phone != (app.me?.phone ?? "") { fields["phone"] = phone }
            await API.shared.updateMe(fields)
            app.me = try? await API.shared.me()
            await app.loadContacts()
            busy = false
            app.show("已保存")
            dismiss()
        }
    }
}

/* ============================================================ 新的朋友 */

struct NewFriendsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var incoming: [User] = []
    @State private var outgoing: [User] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "新的朋友", back: { dismiss() })
            List {
                if loading && incoming.isEmpty && outgoing.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(C.cardBg)
                }
                if incoming.isEmpty && outgoing.isEmpty && !loading {
                    Text("还没有好友申请")
                        .font(pf(15))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(C.cardBg)
                }
                ForEach(incoming) { user in
                    HStack(spacing: 12) {
                        Avatar(path: user.avatarPath, size: 48, radius: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(user.name).font(pf(17)).foregroundColor(C.label)
                            Text("请求加你为好友").font(pf(13)).foregroundColor(C.subLabel)
                        }
                        Spacer()
                        Button("同意") { respond(user, true) }
                            .font(pf(15))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(C.green))
                        Button("拒绝") { respond(user, false) }
                            .font(pf(15))
                            .foregroundColor(C.subLabel)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 72)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(C.cardBg)
                }
                ForEach(outgoing) { user in
                    HStack(spacing: 12) {
                        Avatar(path: user.avatarPath, size: 48, radius: 8)
                        Text(user.name).font(pf(17)).foregroundColor(C.label)
                        Spacer()
                        Text("等待验证").font(pf(14)).foregroundColor(C.subLabel)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 72)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(C.cardBg)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(C.cardBg)
            .refreshable { await load() }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .task { await load() }
    }

    private func load() async {
        if let data = try? await API.shared.contactsFull() {
            incoming = data.incoming
            app.contacts = data.friends
        }
        loading = false
    }

    private func respond(_ user: User, _ accept: Bool) {
        guard let id = user.requestId else { return }
        Task {
            await API.shared.respondFriend(id, accept: accept)
            await load()
            app.show(accept ? "已添加好友" : "已拒绝")
        }
    }
}

/* ============================================================ 加好友 */

struct AddFriendView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "加好友", back: { dismiss() })
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(C.subLabel)
                    TextField("输入对方的用户名（微信号）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(pf(16))
                        .foregroundColor(C.label)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(C.searchBg))

                Button {
                    add()
                } label: {
                    Text(busy ? "发送中…" : "添加到通讯录")
                        .font(pf(17))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 8).fill(C.green))
                }
                .disabled(busy)

                if let message = message {
                    Text(message).font(pf(14)).foregroundColor(C.subLabel)
                }
                Text("对方用户名可以在他的名片里看到。")
                    .font(pf(12.5))
                    .foregroundColor(C.subLabel)
                Spacer()
            }
            .padding(16)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }

    private func add() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { message = "先填个用户名"; return }
        busy = true
        Task {
            do {
                try await API.shared.addFriend(username: name)
                message = "已发送好友申请，等对方同意"
                await app.loadContacts()
            } catch {
                message = (error as? APIError)?.errorDescription ?? "发送失败"
            }
            busy = false
        }
    }
}

/* ============================================================ 发起群聊 */

struct GroupCreateView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var onCreated: (Chat) -> Void

    @State private var name = ""
    @State private var picked: Set<String> = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "发起群聊", back: { dismiss() }) {
                Button {
                    create()
                } label: {
                    Text(busy ? "创建中…" : "完成")
                        .font(pf(17))
                        .foregroundColor(picked.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                TextField("群名称", text: $name)
                    .font(pf(16))
                    .foregroundColor(C.label)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(C.searchBg)
            .padding(12)

            List {
                ForEach(app.contacts) { user in
                    Button {
                        if picked.contains(user.id) { picked.remove(user.id) }
                        else { picked.insert(user.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Avatar(path: user.avatarPath, size: 40, radius: 6)
                            Text(user.name).font(pf(17)).foregroundColor(C.label)
                            Spacer()
                            Image(systemName: picked.contains(user.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(picked.contains(user.id) ? C.green : C.subLabel)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(C.cardBg)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(C.cardBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }

    private func create() {
        let groupName = name.trimmingCharacters(in: .whitespaces)
        if groupName.isEmpty { app.show("先填个群名称"); return }
        if picked.isEmpty { app.show("至少选一个好友"); return }
        busy = true
        Task {
            do {
                if let chat = try await API.shared.createGroup(name: groupName, memberIds: Array(picked)) {
                    await app.loadChats()
                    onCreated(chat)
                    dismiss()
                    app.show("群建好了")
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "创建失败")
            }
            busy = false
        }
    }
}

/* ============================================================ 服务（零钱 / 账单） */

struct ServiceView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var bills: [BillItem] = []
    @State private var loading = true
    @State private var rechargeAmount = ""
    @State private var showRecharge = false
    @State private var detailChat: Chat?
    @State private var detailInfo: TransferInfo?

    struct BillItem: Identifiable {
        let id: String
        let title: String
        let amount: Double
        let date: String
        let status: String
        var chat: Chat? = nil
        var info: TransferInfo? = nil
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "服务", back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("零钱").font(pf(15)).foregroundColor(C.subLabel)
                        Text("¥\(String(format: "%.2f", app.me?.balance ?? 0))")
                            .font(pf(30, .medium))
                            .foregroundColor(C.label)
                        HStack(spacing: 10) {
                            Button {
                                rechargeAmount = ""
                                showRecharge = true
                            } label: {
                                Text("充值")
                                    .font(pf(15))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 18)
                                    .frame(height: 34)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(C.green))
                            }
                            Button {
                                Task { await loadBills() }
                            } label: {
                                Text("刷新账单")
                                    .font(pf(15))
                                    .foregroundColor(C.label)
                                    .padding(.horizontal, 18)
                                    .frame(height: 34)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.dyn(0xF2F2F2, 0x2C2C2E)))
                            }
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(C.cardBg)

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    if loading {
                        ProgressView().padding(.vertical, 30)
                    } else if bills.isEmpty {
                        Text("还没有账单项")
                            .font(pf(15))
                            .foregroundColor(C.subLabel)
                            .padding(.vertical, 30)
                    } else {
                        ForEach(bills) { bill in
                            Button {
                                if let chat = bill.chat, let info = bill.info {
                                    detailChat = chat
                                    detailInfo = info
                                }
                            } label: {
                                VStack(spacing: 0) {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(bill.title).font(pf(16)).foregroundColor(C.label)
                                            Text(bill.date).font(pf(12.5)).foregroundColor(C.subLabel)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 3) {
                                            Text("¥\(String(format: "%.2f", bill.amount))")
                                                .font(pf(16, .medium))
                                                .foregroundColor(C.label)
                                            Text(bill.status).font(pf(12.5)).foregroundColor(C.subLabel)
                                        }
                                        Chevron(size: 9, line: 1.6)
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(height: 66)
                                    .background(C.cardBg)
                                    HairLine(inset: 16)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.navBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .sheet(isPresented: Binding(
            get: { detailInfo != nil },
            set: { if !$0 { detailInfo = nil; detailChat = nil } }
        )) {
            if let c = detailChat, let i = detailInfo {
                BillDetailView(chat: c, info: i)
            }
        }
        .alert("充值", isPresented: $showRecharge) {
            TextField("金额", text: $rechargeAmount).keyboardType(.decimalPad)
            Button("充值") { doRecharge() }
            Button("取消", role: .cancel) { }
        }
        .task { await loadBills() }
    }

    private func doRecharge() {
        guard let amount = Double(rechargeAmount), amount > 0 else {
            app.show("金额不对")
            return
        }
        Task {
            if let balance = try? await API.shared.recharge(amount) {
                app.me = try? await API.shared.me()
                app.show("充值成功，余额 ¥\(String(format: "%.2f", balance))")
            } else {
                app.show("充值失败")
            }
        }
    }

    private func loadBills() async {
        loading = true
        var found: [BillItem] = []
        for chat in app.chats.prefix(14) {
            guard let result = try? await API.shared.messages(chatId: chat.id, limit: 40) else { continue }
            for m in result.messages where m.kindName == "transfer" {
                guard let data = m.body.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let mine = (o["fromId"] as? String) == app.me?.id
                let amount = (o["amount"] as? Double) ?? 0
                let status = (o["status"] as? String) ?? "pending"
                let state = status == "received" ? (mine ? "已收款" : "已收款") :
                            (status == "refunded" ? "已退回" : "待收款")
                found.append(BillItem(id: (o["id"] as? String) ?? m.id,
                                      title: mine ? "转账给 \(chat.name)" : "\(chat.name) 转账给你",
                                      amount: amount,
                                      date: TimeFmt.bill(o["createdAt"] as? String ?? m.createdAt),
                                      status: state,
                                      chat: chat,
                                      info: TransferInfo(json: m.body)))
            }
        }
        bills = found.sorted { $0.date > $1.date }
        loading = false
    }
}
