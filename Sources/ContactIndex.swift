import SwiftUI

/// 通讯录右侧的 A–Z 索引：和网页版一样 27 个字母全都在，
/// 点一下或**按着上下拖**都能跳分组，中间还会弹一个黑色大字气泡。
struct ContactIndexBar: View {
    static let letters: [String] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ#".map { String($0) }

    var available: Set<String>
    var onPick: (String) -> Void
    var onSearch: () -> Void

    private let padV: CGFloat = 4.2
    private let searchBox: CGFloat = 15
    private let searchGap: CGFloat = 4

    /* 字号 / 行距 / 颜色都从后台「界面文字」读（ctIdxSize / ctIdxItemH / ctIdxColor），
       以前这里写死 12.5 和 #B2B2B2，所以后台改了手机上没反应 */
    private var fontSize: CGFloat { max(6, L.ctIdxSize) }
    private var rowH: CGFloat { max(fontSize, L.ctIdxItemH) }
    private var pitch: CGFloat { rowH }
    private var listTop: CGFloat { padV + searchBox + searchGap }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSearch) {
                SVGIcon(markup: I.searchBig, size: 13, color: C.ctIdxColor)
                    .frame(width: searchBox, height: searchBox)
            }
            .buttonStyle(.plain)
            .padding(.bottom, searchGap)

            ForEach(Self.letters, id: \.self) { L in
                Text(L)
                    .font(pf(fontSize))
                    .foregroundColor(C.ctIdxColor)
                    .frame(height: rowH)
            }
        }
        .padding(.vertical, padV)
        .frame(width: 22)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let y = value.location.y - listTop
                    let i = max(0, min(Self.letters.count - 1, Int(floor(y / pitch))))
                    onPick(Self.letters[i])
                }
        )
    }
}

/// 拖动索引时中间弹出来的黑色大字气泡（网页版是 78×78、圆角 14、黑 62%）
struct LetterBubble: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(pf(36, .semibold))
            .foregroundColor(.white)
            .frame(width: 78, height: 78)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.62))
            )
            .allowsHitTesting(false)
    }
}
