import SwiftUI

/* ============================================================
   意见反馈（照微信那套）：
   · 先选分类：功能异常 / 产品建议 / 界面样式 / 其他
   · 写描述，右下角 0/200 字数，超了截断
   · 可以贴截图，最多 3 张（相册或拍照），点图可删
   · 联系方式（选填）
   · 提交后整页「感谢你的反馈」，下面还有「我的反馈」能看到官方回复
   ============================================================ */

struct FeedbackView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var category = "功能异常"
    @State private var content = ""
    @State private var contact = ""
    @State private var picked: [UIImage] = []
    @State private var busy = false
    @State private var done = false
    @State private var showPhoto = false
    @State private var showCamera = false
    @State private var showMine = false

    private let cats = ["功能异常", "产品建议", "界面样式", "其他"]
    private let maxLen = 200

    var body: some View {
        if done {
            VStack(spacing: 14) {
                Spacer(minLength: 60)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(C.green)
                Text(Tr("感谢你的反馈")).font(pf(18, .semibold)).foregroundColor(C.label)
                Text(Tr("我们会尽快处理，处理结果可以在「我的反馈」里看。"))
                    .font(pf(13.5)).foregroundColor(C.subLabel).multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    dismiss()
                } label: {
                    Text(Tr("返回")).font(pf(16, .medium)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 10).fill(C.green))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.top, 10)
                Spacer(minLength: 0)
            }
            .background(C.pageBg.ignoresSafeArea())
        } else {
            VStack(spacing: 0) {
                NavBar(title: Tr("意见反馈"), back: { dismiss() }) {
                    Button {
                        send()
                    } label: {
                        Text(busy ? Tr("提交中…") : Tr("提交"))
                            .font(pf(16, .medium))
                            .foregroundColor(content.isEmpty || busy ? C.subLabel : C.green)
                            .frame(height: L.navH)
                            .padding(.trailing, 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(content.isEmpty || busy)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        /* ① 分类：微信是列表，这里做成一行胶囊，点一下换一个 */
                        GroupCard {
                            HStack(spacing: 8) {
                                ForEach(cats, id: \.self) { c in
                                    Button {
                                        category = c
                                    } label: {
                                        Text(Tr(c))
                                            .font(pf(13.5))
                                            .foregroundColor(category == c ? .white : C.label)
                                            .padding(.horizontal, 12)
                                            .frame(height: 30)
                                            .background(Capsule().fill(category == c ? C.green : C.fieldBg))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 52)
                        }
                        .padding(.top, 8)

                        /* ② 描述 + 字数 + 截图 */
                        VStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                if content.isEmpty {
                                    Text(Tr("说说遇到的问题，或者你希望加什么功能…"))
                                        .font(pf(15)).foregroundColor(C.subLabel)
                                        .padding(.horizontal, 16).padding(.top, 14)
                                }
                                TextEditor(text: $content)
                                    .font(pf(15))
                                    .scrollContentBackground(.hidden)
                                    .frame(height: 150)
                                    .padding(.horizontal, 11)
                                    .padding(.top, 6)
                                    .onChange(of: content) { v in
                                        if v.count > maxLen { content = String(v.prefix(maxLen)) }
                                    }
                            }
                            HStack {
                                Spacer(minLength: 0)
                                Text("\(content.count)/\(maxLen)")
                                    .font(pf(12.5)).foregroundColor(C.subLabel)
                                    .padding(.trailing, 16).padding(.bottom, 8)
                            }
                            HairLine(inset: 16)
                            /* 截图：最多 3 张（+ 号加图，点图删） */
                            HStack(spacing: 10) {
                                ForEach(Array(picked.enumerated()), id: \.offset) { _, img in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: img)
                                            .resizable().scaledToFill()
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundColor(.white)
                                            .background(Circle().fill(Color.black.opacity(0.5)))
                                            .offset(x: 5, y: -5)
                                    }
                                    .onTapGesture {
                                        if let i = picked.firstIndex(where: { $0 === img }) { picked.remove(at: i) }
                                    }
                                }
                                if picked.count < 3 {
                                    Button { showPhoto = true } label: {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .stroke(Color.dyn(0xD9D9D9, 0x3A3A3C), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                            Image(systemName: "plus").font(.system(size: 20)).foregroundColor(C.subLabel)
                                        }
                                        .frame(width: 72, height: 72)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        .background(C.cardBg)
                        .padding(.top, 8)

                        /* ③ 联系方式 */
                        GroupCard {
                            HStack(spacing: 10) {
                                Text(Tr("联系方式")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 8)
                                TextField(Tr("手机号 / 账号（可不填）"), text: $contact)
                                    .font(pf(15))
                                    .multilineTextAlignment(.trailing)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            HairLine(inset: 16)
                        }
                        .padding(.top, 8)

                        /* ④ 我的反馈 */
                        GroupCard {
                            Button { showMine = true } label: {
                                HStack(spacing: 8) {
                                    Text(Tr("我的反馈")).font(pf(16)).foregroundColor(C.label)
                                    Spacer(minLength: 0)
                                    Text(Tr("看处理进度和回复")).font(pf(13)).foregroundColor(C.subLabel)
                                    Chevron(size: 8, line: 1.5)
                                }
                                .padding(.horizontal, 16).frame(height: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 8)

                        Text(Tr("截图可以帮我们更快定位问题；提交内容会存在你自己的服务器上。"))
                            .font(pf(12)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.top, 10)
                        Spacer().frame(height: 30)
                    }
                }
                .background(C.pageBg)
            }
            .background(C.pageBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .swipeBack { dismiss() }
            .hidesTabBar()
            .sheet(isPresented: $showPhoto) {
                PhotosPicker(limit: 3 - picked.count) { imgs in
                    picked.append(contentsOf: imgs.prefix(3 - picked.count))
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { img in
                    if picked.count < 3 { picked.append(img) }
                }
            }
            .sheet(isPresented: $showMine) {
                FeedbackHistoryView().environmentObject(app)
            }
        }
    }

    private func send() {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { app.show(Tr("先写点内容")); return }
        busy = true
        Task {
            /* 先把截图传上去（拿到的就是服务器路径），再提交反馈 */
            var urls: [String] = []
            for img in picked {
                if let u = try? await API.shared.upload(image: img) { urls.append(u) }
            }
            if let err = await API.shared.sendFeedback(content: text, contact: contact,
                                                       category: category, images: urls) {
                app.show(err)
            } else {
                content = ""
                contact = ""
                picked = []
                done = true
            }
            busy = false
        }
    }
}

/* 我的反馈：一条条列出来，处理中 / 已回复，回复内容直接显示在下面（和微信一样） */
struct FeedbackHistoryView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [API.MyFeedback] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的反馈"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    if loading {
                        ProgressView().padding(.top, 50)
                    } else if rows.isEmpty {
                        VStack(spacing: 8) {
                            SVGIcon(markup: I.service, size: 40, color: C.subLabel)
                            Text(Tr("还没有提交过反馈")).font(pf(14)).foregroundColor(C.subLabel)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        ForEach(rows) { r in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(Tr(r.category ?? "功能异常"))
                                        .font(pf(13)).foregroundColor(.white)
                                        .padding(.horizontal, 8).frame(height: 22)
                                        .background(Capsule().fill(C.green.opacity(0.85)))
                                    Spacer(minLength: 0)
                                    Text((r.status ?? "pending") == "replied" ? Tr("已回复") : Tr("处理中"))
                                        .font(pf(13))
                                        .foregroundColor((r.status ?? "pending") == "replied" ? C.green : C.subLabel)
                                }
                                Text(r.content ?? "").font(pf(15)).foregroundColor(C.label)
                                if let imgs = r.images, !imgs.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(Array(imgs.prefix(3).enumerated()), id: \.offset) { _, s in
                                            RemoteImage(path: s, mode: .fill, maxSide: 400)
                                                .frame(width: 62, height: 62)
                                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                                Text(fmt(r.createdAt)).font(pf(12)).foregroundColor(C.subLabel)
                                if let reply = r.reply, !reply.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(Tr("官方回复")).font(pf(12.5, .medium)).foregroundColor(C.green)
                                        Text(reply).font(pf(14)).foregroundColor(C.label)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(C.fieldBg))
                                }
                            }
                            .padding(14)
                            .background(C.cardBg)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 12).padding(.top, 10)
                        }
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            rows = await API.shared.myFeedback()
            loading = false
        }
    }

    private func fmt(_ s: String?) -> String {
        guard let s = s, s.count >= 16 else { return "" }
        return String(s.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}
