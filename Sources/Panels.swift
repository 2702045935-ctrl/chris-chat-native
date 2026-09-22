import SwiftUI

var panelH: CGFloat { L.v(198, 53, 240) }

/* ============================================================ 表情面板 */

let emojiAll: [String] = [
    "😄", "😖", "😍", "😳", "😎", "😭", "😚", "🤐",
    "😴", "😢", "😅", "😡", "😛", "😁", "😲", "😔",
    "😎", "😰", "😫", "🤢", "🤭", "😊", "🙄", "😤",
    "🤤", "😪", "😱", "😅", "😃", "🫡", "💪", "🤬",

    "🤔", "🤫", "😵", "😩", "😞", "💀", "🔨", "👋",
    "😅", "🤧", "👏", "😳", "😏", "😤", "😤", "🥱",
    "😒", "🥺", "😢", "😏", "😘", "😨", "🥺", "🔪",
    "🍉", "🍺", "🏀", "🏓", "☕", "🍚", "🐷", "🌹",

    "🥀", "😘", "❤️", "💔", "🎂", "⚡", "💣", "🗡️",
    "⚽", "🐞", "💩", "🌙", "☀️", "🎁", "🤗", "👍",
    "👎", "🤝", "✌️", "🙏", "😉", "👊", "👌", "🕺",
    "🥶", "😤", "🌀", "🙇", "🔄", "🏃", "👋", "🤩",

    "👍", "👏", "🙏", "✌️", "❤️", "🌹", "🎁", "🎉",
    "🔥", "⭐", "🌈", "🎵", "☕", "🎂", "🧧", "☀️",
    "🌙", "☁️", "🌧️", "❄️", "🐱", "🐶", "🐼", "🐰",
    "🐷", "🐵", "🐯", "🐟", "🍎", "🍓", "🍉", "🍺"
]

/* ============================================================ 我们自己的表情（OpenMoji 那套，后台不用配） */
enum EmojiSet {
    static let names = ["smile", "grin", "laugh", "joy", "rofl", "wink", "love", "kiss",
                        "cool", "shy", "smirk", "think", "wow", "doubt", "sweat", "shh",
                        "cry", "sob", "angry", "sleep", "pray", "clap", "ok", "thumb",
                        "heart", "fire", "gift", "redpacket", "party", "money"]
    static var ours: [String] { names }
    static func url(_ i: Int) -> String { "/uploads/emj2-" + names[max(0, min(i, names.count - 1))] + ".png" }
}

/// 表情小图（九宫格里的一个）
struct StickerThumb: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            guard let u = API.shared.assetURL(url) else { return }
            if let data = try? await API.shared.assetData(u) { image = UIImage(data: data) }
        }
    }
}

struct EmojiPanel: View {
    @Binding var draft: String
    var onSend: () -> Void
    var onDelete: () -> Void
    /// 点我们自己的表情：以图片消息发出去（系统 emoji 那套一个都没动，只是多一页）
    var onSendSticker: ((String) -> Void)? = nil

    @State private var page = 0

    private let perPage = 32
    private var pages: [[String]] {
        stride(from: 0, to: emojiAll.count, by: perPage).map { start in
            Array(emojiAll[start..<min(start + perPage, emojiAll.count)])
        }
    }

    /// 系统表情那一页（原样）
    private func unicodePage(_ p: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 0) {
            ForEach(pages[p].indices, id: \.self) { i in
                Button {
                    draft += pages[p][i]
                } label: {
                    Text(pages[p][i])
                        .font(pf(L.v(23, 6.6, 28)))
                        .frame(maxWidth: .infinity)
                        .frame(height: panelH * 0.80 / 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, L.v(6, 2, 10))
        .padding(.top, L.v(6, 2, 10))
    }

    /// 我们自己的表情（多出来的一页，不替换系统那套）
    private var stickerPage: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 0) {
            ForEach(EmojiSet.ours.indices, id: \.self) { i in
                Button {
                    onSendSticker?(EmojiSet.url(i))
                } label: {
                    StickerThumb(url: EmojiSet.url(i))
                        .frame(maxWidth: .infinity)
                        .frame(height: panelH * 0.80 / 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, L.v(6, 2, 10))
        .padding(.top, L.v(6, 2, 10))
        .overlay(alignment: .top) {
            Text(Tr("我们的表情"))
                .font(pf(11))
                .foregroundColor(C.subLabel)
                .padding(.top, 2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(0..<(pages.count + 1), id: \.self) { p in
                    Group {
                        if p < pages.count {
                            unicodePage(p)
                        } else {
                            stickerPage
                        }
                    }
                    .tag(p)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 0) {
                HStack(spacing: L.v(5, 1.6, 7)) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.dyn(0xBFBFBF, 0xB8B8B8) : Color.dyn(0xCFCFCF, 0x4A4A4A))
                            .frame(width: L.v(5, 1.5, 7), height: L.v(5, 1.5, 7))
                    }
                }
                Spacer()
                Button(action: onDelete) {
                    SVGIcon(markup: I.deleteKey, size: L.v(22, 6.4, 26), color: C.iconGray)
                        .frame(width: L.v(36, 10, 42), height: L.v(26, 7.4, 30))
                }
                .buttonStyle(.plain)
                Button(action: onSend) {
                    Text(Tr("发送"))
                        .font(pf(15))
                        .foregroundColor(draft.isEmpty ? C.subLabel : Color(hex: 0x0D0D0D))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(draft.isEmpty ? Color.dyn(0xE8E8E8, 0x3A3A3C) : C.green)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, L.v(12, 3.8, 16))
            .frame(height: L.v(38, 10.4, 46))
        }
        .frame(height: panelH)
        .background(C.tabBg)
    }
}

/* ============================================================ ＋ 面板 */

struct PlusPanel: View {
    let items: [PlusItem]
    var onTap: (PlusItem) -> Void

    @State private var page = 0
    private let perPage = 8

    private var pages: [[PlusItem]] {
        stride(from: 0, to: max(1, items.count), by: perPage).map { start in
            Array(items[start..<min(start + perPage, items.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { p in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: L.v(8, 2.8, 13)), count: 4),
                              spacing: L.v(8, 2.8, 13)) {
                        ForEach(pages[p].indices, id: \.self) { i in
                            let item = pages[p][i]
                            Button {
                                onTap(item)
                            } label: {
                                VStack(spacing: L.v(4, 1.6, 7)) {
                                    SVGIcon(markup: I.plus(item.icon),
                                            size: L.v(24, 7, 29),
                                            color: C.label)
                                    Text(item.label ?? "")
                                        .font(pf(L.v(10.5, 3, 12)))
                                        .foregroundColor(C.subLabel)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: (panelH - L.v(22, 6, 26) - L.v(24, 7.6, 32)) / 2)
                                .background(RoundedRectangle(cornerRadius: L.v(6, 2, 9), style: .continuous).fill(C.cardBg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, L.v(10, 3.2, 14))
                    .padding(.top, L.v(10, 3.2, 14))
                    .tag(p)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: L.v(5, 1.6, 7)) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.dyn(0xBFBFBF, 0xB8B8B8) : Color.dyn(0xCFCFCF, 0x4A4A4A))
                        .frame(width: L.v(5, 1.5, 7), height: L.v(5, 1.5, 7))
                }
            }
            .frame(height: L.v(22, 6, 26))
        }
        .frame(height: panelH)
        .background(C.tabBg)
    }
}

/* ============================================================ 礼物面板 */

struct GiftPanel: View {
    let gifts: [Gift]
    var onTap: (Gift) -> Void

    @State private var page = 0
    private let perPage = 8

    private var pages: [[Gift]] {
        stride(from: 0, to: max(1, gifts.count), by: perPage).map { start in
            Array(gifts[start..<min(start + perPage, gifts.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if gifts.isEmpty {
                Text(Tr("礼物还没配"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { p in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: L.v(8, 2.8, 13)), count: 4),
                                  spacing: L.v(8, 2.8, 13)) {
                            ForEach(pages[p].indices, id: \.self) { i in
                                let g = pages[p][i]
                                Button {
                                    onTap(g)
                                } label: {
                                    VStack(spacing: L.v(3, 1.2, 5)) {
                                        Text(g.icon ?? "🎁").font(pf(L.v(22, 6.4, 27)))
                                        Text(g.name ?? "礼物")
                                            .font(pf(L.v(10.5, 3, 12)))
                                            .foregroundColor(C.subLabel)
                                            .lineLimit(1)
                    Text("¥\(Int(g.price ?? 0))")
                        .font(pfMoney(L.v(10, 2.8, 11.5)))
                                            .foregroundColor(C.red)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: (panelH - L.v(22, 6, 26) - L.v(24, 7.6, 32)) / 2)
                                    .background(RoundedRectangle(cornerRadius: L.v(6, 2, 9), style: .continuous).fill(C.cardBg))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, L.v(10, 3.2, 14))
                        .padding(.top, L.v(10, 3.2, 14))
                        .tag(p)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: L.v(5, 1.6, 7)) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.dyn(0xBFBFBF, 0xB8B8B8) : Color.dyn(0xCFCFCF, 0x4A4A4A))
                            .frame(width: L.v(5, 1.5, 7), height: L.v(5, 1.5, 7))
                    }
                }
                .frame(height: L.v(22, 6, 26))
            }
        }
        .frame(height: panelH)
        .background(C.tabBg)
    }
}

/* ============================================================ 位置 */

struct LocationSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSend: (String) -> Void

    @State private var name = "我的位置"
    @State private var lat = "31.491200"
    @State private var lng = "120.311900"
    @State private var addr = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(Tr("位置名称"))) {
                    TextField("我的位置", text: $name)
                }
                Section(header: Text(Tr("经纬度（北纬 / 东经）"))) {
                    HStack {
                        Text(Tr("纬度")).foregroundColor(.secondary)
                        TextField("31.4912", text: $lat).keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text(Tr("经度")).foregroundColor(.secondary)
                        TextField("120.3119", text: $lng).keyboardType(.numbersAndPunctuation)
                    }
                    if !addr.isEmpty {
                        Text(addr).font(pf(13)).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(Tr("发送位置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button(Tr("取消")) { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Tr("发送")) {
                        let payload = "{\"lat\":\(Double(lat) ?? 0),\"lng\":\(Double(lng) ?? 0),\"name\":\"\(name)\",\"addr\":\"\(addr)\"}"
                        onSend(payload)
                        dismiss()
                    }
                }
            }
        }
    }
}
