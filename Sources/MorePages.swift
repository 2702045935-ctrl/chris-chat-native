import SwiftUI

/* ============================================================
   补齐「产品功能清单」里缺的那几页：
     · 群列表（通讯录 → 群聊）
     · 查找聊天记录（聊天页「⋯」→ 查找聊天记录）
     · 银行卡 / 绑定银行卡（钱包）
     · 意见反馈、关于我们 / 版本更新（设置）
     · 密码找回（登录页 → 忘记密码）
   ============================================================ */

/* ---------------------------------------------------------- 群列表 */

struct GroupListView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    var onOpenChat: (Chat) -> Void

    private var groups: [Chat] {
        app.chats.filter { $0.type == "group" }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("群聊"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    if groups.isEmpty {
                        Text(Tr("还没有群聊，在「＋ → 发起群聊」里建一个"))
                            .font(pf(13.5))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        GroupCard {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { idx, chat in
                                Button {
                                    dismiss()
                                    onOpenChat(chat)
                                } label: {
                                    HStack(spacing: 12) {
                                        Avatar(path: chat.avatar ?? "", size: 44, radius: 6)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(chat.name)
                                                .font(pf(16.5))
                                                .foregroundColor(C.label)
                                                .lineLimit(1)
                                            Text("\(chat.memberCount ?? 0) 位成员")
                                                .font(pf(12.5))
                                                .foregroundColor(C.subLabel)
                                        }
                                        Spacer(minLength: 0)
                                        Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                                    }
                                    .padding(.horizontal, 16)
                                    .frame(height: 62)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if idx < groups.count - 1 { HairLine(inset: 72) }
                            }
                        }
                        .padding(.top, 8)
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await app.loadChats() }
    }
}

/* ---------------------------------------------------------- 查找聊天记录 */

struct ChatSearchView: View {
    let chat: Chat
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var hits: [FoundMessage] = []
    @State private var busy = false
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("查找聊天记录"), back: { dismiss() })

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(C.searchIcon)
                TextField("搜索这个聊天的聊天记录", text: $keyword)
                    .font(pf(15))
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { search() }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        hits = []
                        done = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(C.searchIcon2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(C.searchBg))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if busy {
                ProgressView().padding(.top, 30)
            } else if hits.isEmpty {
                Text(done ? "没找到相关聊天记录" : "输入关键字，在服务器上翻这个会话的全部历史")
                    .font(pf(13.5))
                    .foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        GroupCard {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { idx, m in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(m.content ?? "")
                                        .font(pf(15.5))
                                        .foregroundColor(C.label)
                                        .lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text((m.senderName ?? "") + " · " + TimeFmt.bubble(m.createdAt ?? ""))
                                        .font(pf(12))
                                        .foregroundColor(C.subLabel)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                if idx < hits.count - 1 { HairLine(inset: 16) }
                            }
                        }
                        .padding(.top, 4)
                        Spacer().frame(height: 30)
                    }
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onAppear { focused = true }
    }

    private func search() {
        let q = keyword.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; done = false; return }
        busy = true
        focused = false
        Task {
            hits = await API.shared.searchMessages(chatId: chat.id, query: q)
            busy = false
            done = true
        }
    }
}

/* ---------------------------------------------------------- 银行卡 */

struct BankCardsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cards: [BankCard] = []
    @State private var loading = true
    @State private var showAdd = false
    @State private var bank = "招商银行"
    @State private var number = ""
    @State private var holder = ""
    @State private var busy = false

    /// 可选银行（从服务器拉，带品牌色；拉不到就用下面这份兜底）
    @State private var bankList: [API.BankInfo] = []
    private var banks: [String] {
        let names = bankList.map { $0.name }
        return names.isEmpty
            ? ["工商银行", "建设银行", "农业银行", "中国银行", "招商银行", "交通银行", "邮储银行", "其他银行"]
            : names
    }

    /// 这家银行的品牌色（服务器给了就用，没给就按名字兜一个）
    private func bankColor(_ name: String) -> Color {
        if let c = bankList.first(where: { $0.name == name })?.color,
           case let hex = c.replacingOccurrences(of: "#", with: ""),
           hex.count == 6, let v = Int(hex, radix: 16) {
            return Color(hex: UInt32(v))
        }
        let table: [String: Int] = ["工商银行": 0xC8161D, "建设银行": 0x0B4DA2, "农业银行": 0x0E8B4A,
                                    "中国银行": 0xB01F24, "招商银行": 0xC7000B, "交通银行": 0x1B4E9B,
                                    "邮储银行": 0x0E7B40, "中信银行": 0xD0202F, "民生银行": 0x0E5EA8,
                                    "浦发银行": 0x0A4C8B, "兴业银行": 0x1F4C9C, "光大银行": 0x8B1A2B,
                                    "平安银行": 0xF36F21, "广发银行": 0xC8102E, "华夏银行": 0x0E5EA8,
                                    "微众银行": 0x0E9C6B, "网商银行": 0x1F7BE0]
        return Color(hex: UInt32(table[name] ?? 0x8A8A8E))
    }

    private func bankShort(_ name: String) -> String {
        if let s = bankList.first(where: { $0.name == name })?.short, !s.isEmpty { return s }
        return String(name.prefix(1))
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("银行卡"), back: { dismiss() }) {
                Button {
                    showAdd = true
                } label: {
                    Text(Tr("绑定"))
                        .font(pf(16, .medium))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    if loading {
                        ProgressView().padding(.top, 40)
                    } else if cards.isEmpty {
                        Text("还没有绑定银行卡\n点右上角「绑定」加一张")
                            .font(pf(13.5))
                            .foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 50)
                    } else {
                        GroupCard {
                            ForEach(Array(cards.enumerated()), id: \.element.id) { idx, c in
                                HStack(spacing: 12) {
                                    Image(systemName: "creditcard.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(C.green)
                                        .frame(width: 34, height: 34)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(C.searchBg))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.bank ?? "银行卡")
                                            .font(pf(16))
                                            .foregroundColor(C.label)
                                        Text(((c.type ?? "储蓄卡") + " · 尾号 \(c.tail ?? "****")") + ((c.holder ?? "").isEmpty ? "" : " · \(c.holder!)"))
                                            .font(pf(12.5))
                                            .foregroundColor(C.subLabel)
                                    }
                                    Spacer(minLength: 0)
                                    Button {
                                        unbind(c.id)
                                    } label: {
                                        Text(Tr("解绑"))
                                            .font(pf(13.5))
                                            .foregroundColor(C.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 66)
                                if idx < cards.count - 1 { HairLine(inset: 62) }
                            }
                        }
                        .padding(.top, 8)
                    }
                    Text(Tr("只保存银行、尾号和持卡人，完整卡号不会留在手机上。"))
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await reload() }
        .task { bankList = await API.shared.banks() }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    private var addSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    /* 银行：横向摆一排名牌小方块（每家一个品牌色），跟微信一样点一下就选中 */
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Tr("选择银行")).font(pf(15)).foregroundColor(C.label)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(banks, id: \.self) { name in
                                    let on = (bank == name)
                                    Button { bank = name } label: {
                                        HStack(spacing: 6) {
                                            Text(bankShort(name))
                                                .font(pf(13, .semibold))
                                                .foregroundColor(.white)
                                                .frame(width: 22, height: 22)
                                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                    .fill(bankColor(name)))
                                            Text(name).font(pf(14)).foregroundColor(on ? C.label : C.subLabel)
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(height: 36)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(on ? C.searchBg : C.cardBg))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(on ? C.green : C.hairline, lineWidth: on ? 1.4 : 0.5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    HairLine(color: C.navLine)
                    HairLine(color: C.navLine)
                    field("卡号") {
                        TextField("16~19 位卡号", text: $number)
                            .keyboardType(.numberPad)
                    }
                    HairLine(color: C.navLine)
                    field("持卡人") {
                        TextField("姓名", text: $holder)
                    }
                    Button {
                        add()
                    } label: {
                        Text(busy ? "绑定中…" : "确认绑定")
                            .font(pf(16, .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(C.green)
                            .cornerRadius(12)
                    }
                    .disabled(busy)
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                }
                .padding(.top, 10)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(Tr("绑定银行卡"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { showAdd = false } } }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ c: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            c()
        }
        .font(pf(15))
        .frame(height: 54)
        .padding(.horizontal, 14)
        .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
    }

    private func reload() async {
        cards = await API.shared.bankCards()
        loading = false
    }

    private func add() {
        let n = number.trimmingCharacters(in: .whitespaces)
        let h = holder.trimmingCharacters(in: .whitespaces)
        if n.count < 16 { app.show(Tr("卡号要 16~19 位")); return }
        if h.isEmpty { app.show(Tr("请填持卡人姓名")); return }
        busy = true
        Task {
            if let err = await API.shared.addBankCard(bank: bank, number: n, holder: h) {
                app.show(err)
            } else {
                app.show(Tr("绑定成功"))
                showAdd = false
                number = ""
                holder = ""
                await reload()
            }
            busy = false
        }
    }

    private func unbind(_ id: String) {
        Task {
            if let err = await API.shared.deleteBankCard(id: id) {
                app.show(err)
            } else {
                app.show(Tr("已解绑"))
                await reload()
            }
        }
    }
}

/* ---------------------------------------------------------- 意见反馈 */

struct FeedbackView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var contact = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("意见反馈"), back: { dismiss() }) {
                Button {
                    send()
                } label: {
                    Text(busy ? "提交中…" : "提交")
                        .font(pf(16, .medium))
                        .foregroundColor(content.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text(Tr("说说遇到的问题，或者你希望加什么功能…"))
                                .font(pf(15))
                                .foregroundColor(C.subLabel)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                        }
                        TextEditor(text: $content)
                            .font(pf(15))
                            .scrollContentBackground(.hidden)
                            .frame(height: 170)
                            .padding(.horizontal, 11)
                            .padding(.top, 6)
                    }
                    .background(C.cardBg)

                    GroupCard {
                        HStack(spacing: 10) {
                            Text(Tr("联系方式")).font(pf(16)).foregroundColor(C.label)
                            Spacer(minLength: 8)
                            TextField("手机号 / 微信号（可不填）", text: $contact)
                                .font(pf(15))
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                        HairLine(inset: 16)
                    }
                    .padding(.top, 8)

                    Text(Tr("提交后会存到服务器 data/feedback.jsonl，后台「用户反馈」里能看。"))
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private func send() {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { app.show(Tr("先写点内容")); return }
        busy = true
        Task {
            if let err = await API.shared.sendFeedback(content: text, contact: contact) {
                app.show(err)
            } else {
                content = ""
                contact = ""
                app.show(Tr("感谢反馈，已经收到"))
                dismiss()
            }
            busy = false
        }
    }
}

/* ---------------------------------------------------------- 关于我们 / 版本更新 */

struct AboutView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var latest = ""
    @State private var appName = "CHRIS 聊天"
    @ObservedObject private var push = PushCenter.shared
    /// 服务器那边推送配置好没（没配好就是「等服务器配置」）
    @State private var pushServerReady = false

    private var pushText: String {
        if !push.authorized { return Tr("通知权限没开") }
        if push.token.isEmpty { return push.lastError.isEmpty ? Tr("登记中…") : push.lastError }
        if pushServerReady { return Tr("已开启") }
        return Tr("等服务器配置")
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("关于我们"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Group {
                            if let img = AppIconImage.image {
                                Image(uiImage: img).resizable()
                            } else {
                                RoundedRectangle(cornerRadius: 16).fill(C.green)
                            }
                        }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        Text(appName)
                            .font(pf(19, .semibold))
                            .foregroundColor(C.label)
                        Text("版本 1.0（打包 \(AppInfo.build)）")
                            .font(pf(13))
                            .foregroundColor(C.subLabel)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)

                    GroupCard {
                        Button {
                            checkVersion()
                        } label: {
                            HStack {
                                Text(Tr("版本更新")).font(pf(16)).foregroundColor(C.label)
                                Spacer()
                                Text(checking ? "检查中…" : (latest.isEmpty ? "检查更新" : latest))
                                    .font(pf(14))
                                    .foregroundColor(C.subLabel)
                                Chevron(size: 9, line: 1.6).padding(.trailing, 3)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 16)
                        HStack {
                            Text(Tr("服务器")).font(pf(16)).foregroundColor(C.label)
                            Spacer()
                       Text(API.shared.base)
                               .font(pf(13))
                               .foregroundColor(C.subLabel)
                               .lineLimit(1)
                               .truncationMode(.middle)
                       }
                       .padding(.horizontal, 16)
                       .frame(height: 52)
                        HairLine(inset: 16)
                        /* 推送自检：权限同意没、服务器那边配好没、这台手机登记过没 */
                        HStack {
                            Text(Tr("推送通知")).font(pf(16)).foregroundColor(C.label)
                            Spacer()
                            Text(pushText)
                                .font(pf(13))
                                .foregroundColor(C.subLabel)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                    }

                    Text(Tr("自建即时通讯：账号、聊天记录、朋友圈都存在你自己的服务器上，不上传第三方。"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            if let b = await API.shared.branding(), let n = b.appName, !n.isEmpty { appName = n }
            if let s = await API.shared.pushStatus() { pushServerReady = (s.configured == true && s.enabled == true) }
        }
    }

    private func checkVersion() {
        checking = true
        Task {
            if let v = await API.shared.serverVersion() {
                latest = v.isEmpty ? "已是最新" : "服务器版本 \(v)"
            } else {
                latest = "连不上服务器"
            }
            checking = false
        }
    }
}

/* ---------------------------------------------------------- 密码找回 */

/* ---------------------------------------------------------- 生日选择 */

struct BirthdayPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var birthday: String

    @State private var date = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .padding(.top, 10)
                Spacer()
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(Tr("选择生日"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Tr("确定")) {
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd"
                        birthday = f.string(from: date)
                        dismiss()
                    }
                    .font(pf(16, .medium))
                }
            }
            .onAppear {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                if let d = f.date(from: birthday) { date = d }
                else {
                    var c = DateComponents()
                    c.year = 2000; c.month = 1; c.day = 1
                    date = Calendar.current.date(from: c) ?? Date()
                }
            }
        }
    }
}

struct ResetPasswordSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    field {
                        TextField("手机号", text: $phone).keyboardType(.numberPad)
                    }
                    HairLine(color: C.navLine)
                    field {
                        TextField("验证码", text: $code).keyboardType(.numberPad)
                        Button(Tr("获取验证码")) { sendCode() }
                            .font(.system(size: 14))
                            .foregroundColor(C.loginGreen)
                    }
                    HairLine(color: C.navLine)
                    field {
                        SecureField("新密码（至少 6 位）", text: $newPassword)
                    }

                    if let e = error {
                        Text(e).font(.system(size: 13)).foregroundColor(C.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }

                    Button { submit() } label: {
                        Text(busy ? "请稍候…" : "重置密码并登录")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(LoginTheme.accent)
                            .cornerRadius(16)
                    }
                    .disabled(busy)
                    .padding(.top, 20)

                    Text(Tr("验证码和「手机号登录」共用，5 分钟内有效。重置后其他设备会自动退出登录。"))
                        .font(.system(size: 12.5))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(Tr("密码找回"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } } }
        }
    }

    private func field<Content: View>(@ViewBuilder _ c: () -> Content) -> some View {
        HStack(spacing: 8) { c() }
            .font(.system(size: 15))
            .frame(height: 54)
            .padding(.horizontal, 14)
            .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
    }

    private func sendCode() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.count < 5 { error = "请填写手机号"; return }
        error = nil
        Task {
            do {
                if let dev = try await API.shared.phoneCode(phone: p) {
                    code = dev
                    app.show("验证码：\(dev)")
                } else { app.show(Tr("验证码已发送")) }
            } catch { self.error = (error as? APIError)?.errorDescription ?? "发送失败" }
        }
    }

    private func submit() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || code.isEmpty { error = "请填手机号和验证码"; return }
        if newPassword.count < 6 { error = "新密码至少 6 位"; return }
        busy = true
        error = nil
        Task {
            let r = await API.shared.resetPassword(phone: p, code: code, newPassword: newPassword)
            if let err = r.error {
                error = err
                busy = false
                return
            }
            do {
                /* 重置接口已经把登录态发下来了（Set-Cookie → App 收进 token），
                   这里只要把自己的资料拉回来就行；不用再走一次登录，
                   也就不会被登录滑动验证挡住。 */
                app.me = try? await API.shared.me()
                dismiss()
            } catch {
                self.error = (error as? APIError)?.errorDescription ?? "重置成功，但自动登录失败，请用新密码登录"
                busy = false
            }
        }
    }
}
