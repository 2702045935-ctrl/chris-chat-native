import SwiftUI

/* ============================================================ 个人信息 */

struct ProfileEditView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @ObservedObject private var ring = Ringtone.shared
    @State private var showRingtone = false
    @State private var bio = ""
    @State private var region = ""
    @State private var gender = "male"
    @State private var phone = ""
    @State private var birthday = ""
    @State private var showBirthday = false
    @State private var showPhoto = false
    @State private var busy = false
    @State private var cropImage: UIImage?
    @State private var showMyQR = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("个人信息"), back: { dismiss() }) {
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
                                Text(Tr("头像")).font(pf(17)).foregroundColor(C.label)
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
                        HairLine(inset: 16)
                        /* 星言号（只读）+ 我的二维码：和微信一样排在这一屏最上面 */
                        HStack(spacing: 12) {
                            Text(Tr("星言号")).font(pf(17)).foregroundColor(C.label)
                                .frame(width: 76, alignment: .leading)
                            Text(app.me?.username ?? "-")
                                .font(pf(17))
                                .foregroundColor(C.subLabel)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        HairLine(inset: 16)
                        Button {
                            showMyQR = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("我的二维码")).font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                SVGIcon(markup: I.qr, size: 18, color: C.arrow)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        HStack(spacing: 12) {
                            Text(Tr("性别")).font(pf(17)).foregroundColor(C.label)
                            Spacer()
                            Picker("", selection: $gender) {
                                Text(Tr("男")).tag("male")
                                Text(Tr("女")).tag("female")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        HairLine(inset: 16)
                        field("地区", $region)
                        HairLine(inset: 16)
                        /* 生日（对应功能清单里的「生日」）：点一下弹出日期选择 */
                        Button {
                            showBirthday = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("生日")).font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                Text(birthday.isEmpty ? "未设置" : birthday)
                                    .font(pf(15))
                                    .foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        field("个性签名", $bio)
                    }

                    Rectangle().fill(C.pageBg).frame(height: 8)

                    GroupCard {
                        field("手机号", $phone)
                    }

                    GroupCard {
                        Button {
                            showRingtone = true
                        } label: {
                            HStack(spacing: 12) {
                                Text(Tr("来电铃声")).font(pf(17)).foregroundColor(C.label)
                                Spacer()
                                Text(ring.currentName)
                                    .font(pf(15))
                                    .foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(Tr("手机号一年只能改一次；头像、昵称、地区、签名想改就改。"))
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
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear {
            nickname = app.me?.nickname ?? ""
            bio = app.me?.bio ?? ""
            region = app.me?.region ?? ""
            gender = app.me?.gender == "female" ? "female" : "male"
            phone = app.me?.phone ?? ""
            birthday = app.me?.birthday ?? ""
        }
        .sheet(isPresented: $showPhoto) {
            /* 先裁成正方形再上传（对应功能清单里的「头像裁剪」） */
            PhotoPicker { image in cropImage = image }
        }
        .sheet(isPresented: Binding(get: { cropImage != nil },
                                    set: { if !$0 { cropImage = nil } })) {
            if let img = cropImage {
                AvatarCropSheet(image: img) { cropped in
                    changeAvatar(cropped)
                    cropImage = nil
                }
            }
        }
        .sheet(isPresented: $showRingtone) {
            RingtonePicker()
        }
        .sheet(isPresented: $showBirthday) {
            BirthdayPickerSheet(birthday: $birthday)
        }
        .sheet(isPresented: $showMyQR) { MyQRView() }
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
                app.show(Tr("头像换好了"))
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
                "gender": gender,
                "birthday": birthday
            ]
            if !phone.isEmpty && phone != (app.me?.phone ?? "") { fields["phone"] = phone }
            await API.shared.updateMe(fields)
            app.me = try? await API.shared.me()
            await app.loadContacts()
            busy = false
            app.show(Tr("已保存"))
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
            NavBar(title: Tr("新的朋友"), back: { dismiss() })
            List {
                if loading && incoming.isEmpty && outgoing.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(C.cardBg)
                }
                if incoming.isEmpty && outgoing.isEmpty && !loading {
                    Text(Tr("还没有好友申请"))
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
                            Text(Tr("请求加你为好友")).font(pf(13)).foregroundColor(C.subLabel)
                        }
                        Spacer()
                        Button(Tr("同意")) { respond(user, true) }
                            .font(pf(15))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 6).fill(C.green))
                        Button(Tr("拒绝")) { respond(user, false) }
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
                        Text(Tr("等待验证")).font(pf(14)).foregroundColor(C.subLabel)
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
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
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
            NavBar(title: Tr("加好友"), back: { dismiss() })
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(C.subLabel)
                    TextField("输入对方的用户名（星言号）", text: $username)
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
                Text(Tr("对方用户名可以在他的名片里看到。"))
                    .font(pf(12.5))
                    .foregroundColor(C.subLabel)
                Spacer()
            }
            .padding(16)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
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
            NavBar(title: Tr("发起群聊"), back: { dismiss() }) {
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
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private func create() {
        let groupName = name.trimmingCharacters(in: .whitespaces)
        if groupName.isEmpty { app.show(Tr("先填个群名称")); return }
        if picked.isEmpty { app.show(Tr("至少选一个好友")); return }
        busy = true
        Task {
            do {
                if let chat = try await API.shared.createGroup(name: groupName, memberIds: Array(picked)) {
                    await app.loadChats()
                    onCreated(chat)
                    dismiss()
                    app.show(Tr("群建好了"))
                }
            } catch {
                app.show((error as? APIError)?.errorDescription ?? "创建失败")
            }
            busy = false
        }
    }
}

/* ============================================================ 服务（照微信参考图重做）
   尺寸全部对着参考图量出来的数字（iPhone @3x，420×912pt）：
     · 卡片左右各内缩 8、卡与卡之间空 8、圆角 7
     · 绿卡：高 144，底色 #2AAE67；左右两半居中（图标 28 / 名字 18 / 小字 12 白 50%）
     · 白卡：分类标题行 48（灰 14）+ 每行格子 92 + 底部 20
     · 格子：4 列均分，图标 28、图标下 18.5、文字 13（黑）
   内容全部来自后台「服务页」模块（GET /api/service），拉不到就用内置那套兜底；
   钱包那一半显示零钱余额，账单列表接在所有分类下面（原来的功能没丢）。 */

struct ServiceView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    @State private var cfg: ServiceConfig?
    @State private var bills: [BillItem] = []
    @State private var loading = true
    @State private var rechargeAmount = ""
    @State private var showRecharge = false
    @State private var showMore = false
    @State private var showWallet = false
    @State private var showBillsPage = false
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

    /// 一格（四列网格里的一个）
    private struct Cell: Identifiable {
        let id: String
        let label: String
        let color: Color
        let svg: String
        let action: String
    }

    /// 一张白卡 = 一个分类
    private struct Group: Identifiable {
        let id: String
        let title: String
        let cells: [Cell]
        var style: ServiceGroupStyle? = nil
    }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)

    /// 样式（绿卡背景 / 图标大小 / 字体）：后台「服务页 → 样式」里配，取不到就用参考图那套默认值
    private var st: ServiceStyle { cfg?.style ?? ServiceStyle() }

    /// 分类：后台配的优先，没有就用内置那套（内容和参考图一致）
    private var groups: [Group] {
        if let list = cfg?.groups, !list.isEmpty {
            return list.compactMap { g in
                let cells = (g.items ?? []).filter { $0.enabled != false }.map { it in
                    Cell(id: it.id,
                         label: it.label,
                         color: Color(hexString: it.color ?? "#1180E0", fallback: 0x1180E0),
                         svg: SvcIcon.markup(it.icon, it.svg),
                         action: it.action ?? "soon")
                }
                return cells.isEmpty ? nil : Group(id: g.id, title: g.title, cells: cells, style: g.style)
            }
        }
        return ServiceFallback.groups.map { pair in
            Group(id: pair.0, title: pair.0, cells: pair.1.map { row in
                Cell(id: row.0, label: row.0,
                     color: Color(hexString: row.2, fallback: 0x1180E0),
                     svg: SvcIcon.markup(row.1, nil), action: "soon")
            })
        }
    }

    private var balanceText: String { "¥" + String(format: "%.2f", app.me?.balance ?? 0) }
    /// 绿卡右边的零钱：后台开了「金额打星号」就显示 ¥****
    private var walletSubText: String { (st.maskAmount ?? true) ? "¥****" : balanceText }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: cfg?.title ?? "服务", back: { dismiss() }) {
                Button { showMore = true } label: {
                    Text("⋯")
                        .font(pf(22))
                        .foregroundColor(C.label)
                        .frame(width: 44, height: L.navH)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if cfg?.card?.enabled != false { greenCard.padding(.top, 13) }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                        groupCard(g).padding(.top, topGap(idx))
                    }
                    billsCard.padding(.top, 8)
                    Color.clear.frame(height: 24)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .navigationDestination(isPresented: $showWallet) { WalletView() }
        .navigationDestination(isPresented: $showBillsPage) { BillsView() }
        .confirmationDialog(Tr("服务"), isPresented: $showMore, titleVisibility: .hidden) {
            Button(Tr("刷新账单")) { Task { await loadBills() } }
            Button(Tr("充值")) { rechargeAmount = ""; showRecharge = true }
            Button(Tr("取消"), role: .cancel) { }
        }
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
            Button(Tr("充值")) { doRecharge() }
            Button(Tr("取消"), role: .cancel) { }
        }
        .task {
            await loadConfig()
            await loadBills()
        }
        // 有转账 / 余额变动 → 账单立刻刷新
        .onChange(of: realtime.event) { ev in
            if ev.type == "transfer" || ev.type == "balance" { Task { await loadBills() } }
            if ev.type == "ui" { Task { await loadConfig() } }
        }
    }

    /* ---------------------------------------------------------- 绿卡：收付款 / 钱包 */

    private var greenCard: some View {
        let c = cfg?.card
        let bg = Color(hexString: c?.bg ?? "#2AAE67", fallback: 0x2AAE67)
        let s = st
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(bg)
            /* 后台填了背景图就用图，没填就只用底色 */
            if let img = s.cardImage, !img.isEmpty {
                RemoteImage(path: img)
                    .frame(maxWidth: .infinity)
                    .frame(height: s.cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            HStack(alignment: .top, spacing: 0) {
                halfView(c?.left, label: "收付款", icon: "svc.pay", action: "pay", sub: "")
                halfView(c?.right, label: "钱包", icon: "svc.wallet", action: "wallet", sub: walletSubText)
            }
            .padding(.horizontal, 25)
            .padding(.top, 33)
        }
        .frame(height: s.cardHeight)
        .padding(.horizontal, 8)
    }

    private func halfView(_ h: ServiceHalf?, label fallbackLabel: String,
                          icon fallbackIcon: String, action fallbackAction: String, sub fallbackSub: String) -> some View {
        let rawLabel = h?.label ?? ""
        let label = rawLabel.isEmpty ? fallbackLabel : rawLabel
        let rawSub = h?.sub ?? ""
        let sub = rawSub.isEmpty ? fallbackSub : rawSub
        let s = st
        return Button {
            run(h?.action ?? fallbackAction, label)
        } label: {
            VStack(spacing: 0) {
                SVGIcon(markup: SvcIcon.markup(h?.icon ?? fallbackIcon, h?.svg), size: s.icon, color: s.cardText)
                    .frame(width: s.icon, height: s.icon)
                Text(label)
                    .font(pf(s.cardNameSize))
                    .foregroundColor(s.cardText)
                    .padding(.top, 17)
                if !sub.isEmpty {
                    MoneyLabel(text: sub, size: s.cardSubSizeV, curSize: s.curFontSize,
                               color: s.cardText.opacity(s.cardSubOpacityV))
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /* ---------------------------------------------------------- 白卡：分类标题 + 四列格子 */

    private func groupCard(_ g: Group) -> some View {
        let s = st
        /* 版块自己的「上 / 下」在 topGap() 里处理（块与块之间的空隙）；
           标题行高、每行高、行间距、留白都是参考图那套固定值。左右固定 8pt。 */
        return VStack(spacing: 0) {
            Text(g.title)
                .font(pf(s.titleSize))
                .foregroundColor(s.titleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16.7)
                .frame(height: s.titleHeight)

            LazyVGrid(columns: cols, spacing: 0) {
                ForEach(g.cells) { c in
                    Button {
                        run(c.action, c.label)
                    } label: {
                        VStack(spacing: 0) {
                            SVGIcon(markup: c.svg, size: s.icon, color: c.color)
                                .frame(width: s.icon, height: s.icon)
                            Text(c.label)
                                .font(pf(s.textSize))
                                .foregroundColor(s.gridText)
                                .lineLimit(1)
                                .padding(.top, 18.5)
                        }
                        .padding(.top, 14)
                        .frame(maxWidth: .infinity)
                        .frame(height: s.cellHeight, alignment: .top)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(C.cardBg))
        .padding(.horizontal, 8)
    }

    /// 版块之间的空隙 = 上一块的「块下间距」+ 这一块的「块上间距」
    /// （默认：上一块 8、这一块 0 → 和参考图一样空 8pt；后台怎么调都不会挨在一起）
    private func topGap(_ idx: Int) -> CGFloat {
        guard idx > 0 else { return 8 }
        let prev = groups[idx - 1].style?.gapBottom ?? 8
        let cur = groups[idx].style?.gapTop ?? 0
        return CGFloat(max(8, prev + cur))
    }

    /* ---------------------------------------------------------- 账单（原来那一套，接在下面） */

    private var billsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(Tr("账单"))
                    .font(pf(14))
                    .foregroundColor(Color.dyn(0x7A7A7A, 0x8A8A8A))
                Spacer(minLength: 0)
                Text(balanceText)
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                Button {
                    showBillsPage = true
                } label: {
                    Text(Tr("全部账单"))
                        .font(pf(13))
                        .foregroundColor(C.green)
                        .padding(.leading, 14)
                }
                .buttonStyle(.plain)
                Button {
                    rechargeAmount = ""
                    showRecharge = true
                } label: {
                    Text(Tr("充值"))
                        .font(pf(13))
                        .foregroundColor(C.green)
                        .padding(.leading, 14)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16.7)
            .frame(height: 48)

            if loading {
                ProgressView().padding(.vertical, 26)
            } else if bills.isEmpty {
                Text(Tr("还没有账单项"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .padding(.vertical, 26)
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
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text("¥\(String(format: "%.2f", bill.amount))")
                                        .font(pfMoney(16))
                                        .foregroundColor(C.label)
                                    Text(bill.status).font(pf(12.5)).foregroundColor(C.subLabel)
                                }
                                Chevron(size: 9, line: 1.6)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 66)
                            HairLine(inset: 16)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(C.cardBg))
        .padding(.horizontal, 8)
        .padding(.bottom, 20)
    }

    /* ---------------------------------------------------------- 动作 */

    private func run(_ action: String, _ label: String) {
        switch action {
        case "wallet":
            showWallet = true          // 进「钱包」页（照参考图做的那一页）
        case "pay":
            app.show(Tr("收付款：还没接后端，先把页面做出来"))
        default:
            app.show("「\(label)」还没接后端，先把页面做出来")
        }
    }

    private func loadConfig() async {
        if let got = try? await API.shared.serviceConfig() {
            cfg = got
        }
    }

    private func doRecharge() {
        guard let amount = Double(rechargeAmount), amount > 0 else {
            app.show(Tr("金额不对"))
            return
        }
        Task {
            if let balance = try? await API.shared.recharge(amount) {
                app.me = try? await API.shared.me()
                app.show("充值成功，余额 ¥\(String(format: "%.2f", balance))")
            } else {
                app.show(Tr("充值失败"))
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
                let state = status == "received" ? "已收款" :
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
