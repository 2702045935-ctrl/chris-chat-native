import SwiftUI
import UIKit

/* ============================================================
   尺寸：照网页版 m.css 里的 clamp(min, vw, max) 一条条搬过来，
   所以任何机型宽度下都和网页版算出来的一样。
   ============================================================ */

enum L {
    /// 屏幕逻辑宽度（根视图量到以后会写进来，等价于网页的 100vw）
    static var width: CGFloat = {
        if let w = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.bounds.width, w > 0 { return w }
        return UIScreen.main.bounds.width
    }()

    /// clamp(min, vw%, max)
    static func v(_ lo: CGFloat, _ vw: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(lo, width * vw / 100), hi)
    }

    static var safeTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 20
    }
    static var safeBottom: CGFloat {
        max(0, (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 0)
    }

    // 导航栏：网页里 398~425 宽时固定 48，其余走 clamp
    static var navH: CGFloat {
        if width >= 398 && width <= 425 { return 48 }
        return v(42, 11.4, 50)
    }
    static let tabH: CGFloat = 56

    // 会话列表（微信页）：12 + 48 + 12 = 72
    static let rowH: CGFloat = 72
    static var avatar: CGFloat { v(44, 12.3, 48) }
    static let rowPadL: CGFloat = 16
    static let rowPadR: CGFloat = 17
    static let rowGap: CGFloat = 13
    static let searchBoxH: CGFloat = 36
    static let searchPad: CGFloat = 8
    /// 参考图量出来：会话行分隔线从 x=76 开始
    static let dividerLeft: CGFloat = 76

    // 通讯录（按 vx 参考图：行 56、头像 40、左 16、间距 12、文字 x=68）
    static let ctRowH: CGFloat = 56
    static let ctAvatar: CGFloat = 40
    static let ctPadL: CGFloat = 16
    static let ctGap: CGFloat = 12
    static let ctIcon: CGFloat = 40
    static var ctTextX: CGFloat { ctPadL + ctAvatar + ctGap }

    // 发现页 / 我页（按 vx 参考图：行 56、图标 x18、文字 x58、组间线从 x56 开始）
    static let menuH: CGFloat = 56
    static let menuPadL: CGFloat = 18
    static let menuPadR: CGFloat = 16
    static let menuGap: CGFloat = 18
    static let menuIcon: CGFloat = 22
    static let groupGap: CGFloat = 8
    static var menuTextX: CGFloat { menuPadL + menuIcon + menuGap }
    /// 我页/发现页行内那条细线的左端
    static let menuLineInset: CGFloat = 56

    // 聊天页
    static var msgPad: CGFloat { v(10, 2.8, 12) }
    static var chatAvatar: CGFloat { v(38, 9.8, 42) }
    static var bubblePadH: CGFloat { v(11, 3, 12.6) }
    static var bubblePadV: CGFloat { v(9, 2.3, 9.8) }
    static let composerH: CGFloat = 56
    static let composerIconBox: CGFloat = 33
    static let composerIcon: CGFloat = 28
    static let inputH: CGFloat = 39

    // 朋友圈
    static let coverH: CGFloat = 380
    static var coverAvatar: CGFloat { v(52, 17.1, 72) }
    static let momentPadH: CGFloat = 22
    static let momentAvatar: CGFloat = 44
}

/* ============================================================ 颜色 */

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }
}

extension Color {
    init(hex: UInt32) { self = Color(UIColor(hex: hex)) }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color { Color(UIColor.dyn(light, dark)) }
}

/// 逐个色号对着网页版量出来的（浅色 / 深色）
enum C {
    static let pageBg      = Color.dyn(0xEDEDED, 0x0B0B0D)
    static let navBg       = Color.dyn(0xEDEDED, 0x18181A)
    static let tabBg       = Color.dyn(0xF7F7F7, 0x18181A)
    static let cardBg      = Color.dyn(0xFFFFFF, 0x1C1C1E)
    static let chatRowBg   = Color.dyn(0xFFFFFF, 0x2A2A2A)
    static let pinnedBg    = Color.dyn(0xF2F2F2, 0x333335)
    static let searchBg    = Color.dyn(0xFFFFFF, 0x2A2A2C)
    static let searchIcon  = Color.dyn(0xB2B2B2, 0x9A9A9E)
    static let searchIcon2 = Color.dyn(0x8C8C8C, 0x9A9A9E)
    static let searchBorder = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(hex: 0xF0F0F0)
    })
    /// 微信页那条白框：浅色下没有描边（就是一块纯白），深色下才有一条很淡的亮边
    static let searchBorderChats = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor.clear
    })
    static let name        = Color.dyn(0x1C1C1E, 0xF2F2F7)
    static let label       = Color.dyn(0x191919, 0xF2F2F7)
    static let preview     = Color.dyn(0xB2B2B2, 0xB2B2B2)
    static let time        = Color.dyn(0xC7C7CC, 0xC7C7CC)
    static let subLabel    = Color.dyn(0x999999, 0x8F8F8F)
    static let hairline    = Color.dyn(0xE5E5E5, 0x333335)
    static let navLine     = Color.dyn(0xE8E8E8, 0x2C2C2E)
    static let green       = Color.dyn(0x07C160, 0x3EB575)
    static let red         = Color(hex: 0xFA5151)
    static let orange      = Color(hex: 0xFF9500)
    static let tabInk      = Color.dyn(0x191919, 0xB5B5B5)
    static let bubbleMine  = Color.dyn(0x95EC69, 0x3EB575)
    static let bubbleOther = Color.dyn(0xFFFFFF, 0x2D2D30)
    static let bubbleText  = Color.dyn(0x191919, 0xEDEDED)
    static let msgTime     = Color(hex: 0xAEAEB2)
    static let link        = Color.dyn(0x576B95, 0x7D90A9)
    static let arrow       = Color.dyn(0xB2B2B2, 0x8A8A8E)
    static let ringInk     = Color(UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 1, blue: 1, alpha: 0.78)
            : UIColor(red: 25 / 255, green: 25 / 255, blue: 26 / 255, alpha: 0.62)
    })
    static let fieldBg     = Color.dyn(0xF2F2F2, 0x2C2C2E)
    static let iconGray    = Color.dyn(0x6F6F6F, 0x9A9A9A)

    // 登录页（网页版永远是深色那一套）
    static let loginBg     = Color(hex: 0x111111)
    static let loginCard   = Color(hex: 0x191919)
    static let loginText   = Color(hex: 0xEDEDED)
    static let loginGray   = Color(hex: 0x7F7F7F)
    static let loginLink   = Color(hex: 0x7D90A9)
    static let loginGreen  = Color(hex: 0x3EB575)
}

/* ============================================================
   字体：全站一律苹方（PingFang SC）。
   数字和英文也走苹方，不再落到 SF Pro 上，和手机微信一模一样。
   万一系统里没有苹方，自动退回系统字体，不会变成方框。
   ============================================================ */
/// 全站字号统一小一号（用户要求）：17→16、15→14、14→13、12→11
let fontScale: CGFloat = 0.94

func pf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    let scaled = max(9, (size * fontScale).rounded())
    var name = "PingFangSC-Regular"
    if weight == .medium {
        name = "PingFangSC-Medium"
    } else if weight == .semibold || weight == .bold || weight == .heavy || weight == .black {
        name = "PingFangSC-Semibold"
    } else if weight == .light || weight == .thin || weight == .ultraLight {
        name = "PingFangSC-Light"
    }
    if UIFont(name: name, size: scaled) != nil {
        return .custom(name, size: scaled)
    }
    return .system(size: scaled, weight: weight)
}

enum AppIconImage {
    static var image: UIImage? {
        for name in ["AppIcon60x60@3x", "AppIcon60x60@2x", "AppIcon60x60"] {
            if let p = Bundle.main.path(forResource: name, ofType: "png"), let img = UIImage(contentsOfFile: p) {
                return img
            }
        }
        return UIImage(named: "AppIcon60x60")
    }
}

/* ============================================================ 图片 */

final class ImageStore {
    static let shared = ImageStore()
    private var cache: [String: UIImage] = [:]
    private let lock = NSLock()
    func get(_ key: String) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }
    func put(_ key: String, _ img: UIImage) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = img
    }
}

struct RemoteImage: View {
    let path: String
    var icon: String = "photo"
    var mode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
                } else {
                    ZStack {
                        Color.dyn(0xE9E9E9, 0x2C2C2E)
                        Image(systemName: icon)
                            .font(pf(max(10, min(geo.size.width, geo.size.height) * 0.40)))
                            .foregroundColor(Color.dyn(0xC4C4C4, 0x636366))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear { if !started { started = true; Task { await load() } } }
    }

    private func load() async {
        if path.isEmpty { return }
        if let hit = ImageStore.shared.get(path) { image = hit; return }
        if path.hasPrefix("data:") {
            if let comma = path.firstIndex(of: ",") {
                let b64 = String(path[path.index(after: comma)...])
                if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   let img = UIImage(data: data) {
                    ImageStore.shared.put(path, img)
                    image = img
                }
            }
            return
        }
        guard let url = API.shared.assetURL(path) else { return }
        do {
            let (data, _) = try await API.shared.session.data(from: url)
            if let img = UIImage(data: data) {
                ImageStore.shared.put(path, img)
                image = img
            }
        } catch { }
    }
}

struct Avatar: View {
    let path: String
    var size: CGFloat = 48
    var radius: CGFloat = 6
    var circle = false

    var body: some View {
        RemoteImage(path: path, icon: "person.fill")
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.stroke(Color.black.opacity(0.05), lineWidth: 0.5))
    }

    private var shape: AnyShape {
        if circle { return AnyShape(Circle()) }
        return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/* ============================================================ 时间 */

enum TimeFmt {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    static func list(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days < 7 {
            f.dateFormat = "EEEE"
            return f.string(from: d)
        }
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    static func bubble(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let cal = Calendar.current
        let hm = DateFormatter()
        hm.locale = Locale(identifier: "zh_CN")
        hm.dateFormat = "h:mm"
        var clock = hm.string(from: d)
        clock = (cal.component(.hour, from: d) < 12 ? "上午 " : "下午 ") + clock
        if cal.isDateInToday(d) {
            return clock
        }
        if cal.isDateInYesterday(d) { return "昨天 " + clock }
        let day = DateFormatter()
        day.locale = Locale(identifier: "zh_CN")
        day.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return day.string(from: d) + " " + clock
    }

    static func minutesBetween(_ a: String?, _ b: String?) -> Int {
        guard let d1 = date(a), let d2 = date(b) else { return 9999 }
        return abs(Int(d2.timeIntervalSince(d1) / 60))
    }

    /// 账单里的时间：2026年9月13日 13:11:57（不带前导 0）
    static func bill(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 H:mm:ss"
        return f.string(from: d)
    }

    static func ago(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1 { return "刚刚" }
        if mins < 60 { return "\(mins)分钟前" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)小时前" }
        let days = hours / 24
        if days < 30 { return "\(days)天前" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}

/* ============================================================ 小零件 */

func pinyinInitial(_ text: String) -> String {
    guard !text.isEmpty else { return "#" }
    let first = String(text[text.startIndex])
    if first.range(of: "^[A-Za-z]$", options: .regularExpression) != nil {
        return first.uppercased()
    }
    var latin = first.applyingTransform(StringTransform.toLatin, reverse: false) ?? first
    latin = latin.applyingTransform(StringTransform.stripDiacritics, reverse: false) ?? latin
    latin = latin.trimmingCharacters(in: .whitespacesAndNewlines)
    if let c = latin.first, c.isLetter { return String(c).uppercased() }
    return "#"
}

/// 网页里是 1 个设备像素的发丝线
struct HairLine: View {
    var inset: CGFloat = 0
    var trailingInset: CGFloat = 0
    var color: Color = C.hairline
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
            .padding(.leading, inset)
            .padding(.trailing, trailingInset)
    }
}

/// 微信那个「›」：方块只留上/右两条边，再转 45°
struct Chevron: View {
    var size: CGFloat = 9
    var line: CGFloat = 1.6
    var color: Color = C.arrow
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: size, y: 0))
            p.addLine(to: CGPoint(x: size, y: size))
        }
        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .square, lineJoin: .miter))
        .frame(width: size, height: size)
        .rotationEffect(.degrees(45))
        .frame(width: size * 1.4, height: size * 1.4)
    }
}

struct UnreadBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(pf(11, .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(C.red))
        }
    }
}
