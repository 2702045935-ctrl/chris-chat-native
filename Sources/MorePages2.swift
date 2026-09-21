import SwiftUI

/* ============================================================
   补齐功能清单用的第二批页面：
     · 群二维码（群聊信息页 → 群二维码，扫码进群）
     · 头像裁剪（选完头像先裁成正方形）
     · 界面语言（中文 / English）
   ============================================================ */

/* ---------------------------------------------------------- 界面语言 */

/// 极简多语言：只覆盖最显眼的那些文案（标签栏、设置、常用按钮）
enum Lang {
    static let key = "chris.lang"

    static var code: String {
        /* 没手动选过就跟随系统语言：系统是英文就用英文（选过就一直按选的来） */
        get {
            if let saved = UserDefaults.standard.string(forKey: key) { return saved }
            let sys = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return sys.hasPrefix("en") ? "en" : "zh"
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static var isEnglish: Bool { code == "en" }
    static func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }

    static var name: String {
        switch code {
        case "en": return "English"
        default: return "简体中文"
        }
    }
}

/* ---------------------------------------------------------- 群二维码 */

struct GroupQRView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var url = ""
    @State private var rows: [String] = []
    @State private var loading = true
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("群二维码"), back: { dismiss() }) {
                Button {
                    saveToAlbum()
                } label: {
                    Text(saved ? "已存" : "保存")
                        .font(pf(16, .medium))
                        .foregroundColor(C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(rows.isEmpty)
            }

            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.white)
                        if loading {
                            ProgressView()
                        } else if rows.isEmpty {
                            Text(Tr("二维码生成失败，稍后再试"))
                                .font(pf(13.5))
                                .foregroundColor(C.subLabel)
                        } else {
                            QRCanvas(rows: rows)
                                .frame(width: 228, height: 228)
                        }
                    }
                    .frame(width: 256, height: 256)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)

                    HStack(spacing: 10) {
                        Avatar(path: chat.avatar ?? "", size: 40, radius: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.name).font(pf(15.5, .medium)).foregroundColor(C.label)
                            Text("\(chat.memberCount ?? 0) 位成员").font(pf(12.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 60)
                    .background(RoundedRectangle(cornerRadius: 7).fill(C.cardBg))
                    .padding(.horizontal, 24)

                    Text(Tr("用手机扫码打开链接就能进群；没登录会先跳到登录页，登录完自动进群"))
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                    Spacer().frame(height: 30)
                }
                .padding(.top, 20)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            let r = await API.shared.groupInvite(chatId: chat.id)
            code = r.code
            url = r.url
            rows = r.rows
            loading = false
        }
    }

    private func saveToAlbum() {
        guard !rows.isEmpty else { return }
        let view = QRCanvas(rows: rows).frame(width: 600, height: 600)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let img = renderer.uiImage {
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            saved = true
            app.show(Tr("二维码已存到相册"))
            return
        }
        app.show(Tr("保存失败，可以截图"))
    }
}

/// 把服务端算好的二维码点阵画出来（1 = 黑）
struct QRCanvas: View {
    let rows: [String]

    var body: some View {
        GeometryReader { geo in
            let n = max(1, rows.count)
            let cell = geo.size.width / CGFloat(n + 4)      // 四周各留 2 格白边
            ZStack(alignment: .topLeading) {
                Color.white
                ForEach(0..<n, id: \.self) { y in
                    let line = Array(rows[y])
                    ForEach(0..<line.count, id: \.self) { x in
                        if line[x] == "1" {
                            Rectangle()
                                .fill(Color.black)
                                .frame(width: cell, height: cell)
                                .offset(x: CGFloat(x + 2) * cell, y: CGFloat(y + 2) * cell)
                        }
                    }
                }
            }
        }
    }
}

/* ---------------------------------------------------------- 头像裁剪 */

struct AvatarCropSheet: View {
    let image: UIImage
    var onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let side: CGFloat = 280          // 取景框边长

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text(Tr("拖动调整位置，双指缩放，圈里的就是要当头像的部分"))
                    .font(pf(12.5))
                    .foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)

                ZStack {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .scaleEffect(scale)
                        .offset(offset)
                        .clipped()
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: side, height: side)
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in offset = CGSize(width: lastOffset.width + v.translation.width,
                                                          height: lastOffset.height + v.translation.height) }
                        .onEnded { _ in lastOffset = offset }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(1, min(4, lastScale * v)) }
                        .onEnded { _ in lastScale = scale }
                )
                .cornerRadius(12)

                Button {
                    onDone(crop())
                    dismiss()
                } label: {
                    Text(Tr("就用这张"))
                        .font(pf(16, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(C.green)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                Spacer()
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(Tr("裁剪头像"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } } }
        }
    }

    /// 按当前缩放和位移把取景框里的那一块裁出来
    private func crop() -> UIImage {
        let w = image.size.width, h = image.size.height
        let base = max(side / w, side / h)          // scaledToFill 的基准比例
        let shown = CGSize(width: w * base * scale, height: h * base * scale)
        let originX = (shown.width - side) / 2 - offset.width
        let originY = (shown.height - side) / 2 - offset.height
        let sx = originX / (base * scale), sy = originY / (base * scale)
        let sw = side / (base * scale), sh = side / (base * scale)
        let rect = CGRect(x: max(0, sx), y: max(0, sy),
                          width: min(w, sw), height: min(h, sh))
        if let cg = image.cgImage?.cropping(to: CGRect(x: rect.minX * image.scale,
                                                       y: rect.minY * image.scale,
                                                       width: rect.width * image.scale,
                                                       height: rect.height * image.scale)) {
            return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
        }
        return image
    }
}
