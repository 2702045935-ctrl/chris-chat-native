import SwiftUI
import UIKit

/* ============================================================
   界面配置：服务器上 data/ui.json 里能改字号、行高、头像大小、颜色。
   改完把 App 从后台划掉重新打开就生效 —— 不用重新装包。
   ============================================================ */
enum UIConfig {
    private static var numbers: [String: CGFloat] = [:]
    private static var strings: [String: String] = [:]
    static var scale: CGFloat = 0.94

    static func num(_ key: String, _ def: CGFloat) -> CGFloat { numbers[key] ?? def }

    static func color(_ key: String, _ light: UInt32, _ dark: UInt32) -> Color {
        guard let raw = strings[key] else { return Color.dyn(light, dark) }
        let parts = raw.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }
        func hex(_ s: String) -> UInt32? { UInt32(s.replacingOccurrences(of: "#", with: ""), radix: 16) }
        let l = parts.count > 0 ? (hex(parts[0]) ?? light) : light
        let d = parts.count > 1 ? (hex(parts[1]) ?? l) : l
        return Color.dyn(l, d)
    }

    static func apply(_ json: [String: Any]) {
        var n: [String: CGFloat] = [:]
        var s: [String: String] = [:]
        for (k, v) in json {
            if let d = v as? Double { n[k] = CGFloat(d) }
            else if let i = v as? Int { n[k] = CGFloat(i) }
            else if let b = v as? Bool { n[k] = b ? 1 : 0 }
            else if let t = v as? String { s[k] = t }
        }
        numbers = n
        strings = s
        if let sc = n["fontScale"], sc > 0.5, sc < 1.6 { scale = sc }
    }
}

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

    /// 服务器上 data/ui.json 里的覆盖值（改这个文件 + 重开 App 就生效，不用重装）
    static func o(_ key: String, _ def: CGFloat) -> CGFloat { UIConfig.num(key, def) }

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
        let def: CGFloat = (width >= 398 && width <= 425) ? 48 : v(42, 11.4, 50)
        return o("navH", def)
    }
    static var tabH: CGFloat { o("tabH", 56) }
    static var tabIcon: CGFloat { o("tabIcon", 23) }
    static var tabIconBox: CGFloat { o("tabIconBox", 24) }
    static var tabLabel: CGFloat { o("tabLabel", 11) }

    // 会话列表（微信页）：12 + 48 + 12 = 72
    static var rowH: CGFloat { o("chatRowH", 72) }
    static var avatar: CGFloat { o("chatAvatar", v(44, 12.3, 48)) }
    static var rowPadL: CGFloat { o("chatPadL", 16) }
    static var rowPadR: CGFloat { o("chatPadR", 17) }
    static var rowGap: CGFloat { o("chatGap", 13) }
    static var rowNameSize: CGFloat { o("chatNameSize", 17) }
    static var rowPreviewSize: CGFloat { o("chatPreviewSize", 14) }
    static var rowTimeSize: CGFloat { o("chatTimeSize", 12) }
    static var searchBoxH: CGFloat { o("searchBoxH", 36) }
    static var searchPad: CGFloat { o("searchPad", 8) }
    /// 参考图量出来：会话行分隔线从 x=76 开始
    static var dividerLeft: CGFloat { o("dividerLeft", 76) }

    // 通讯录（按 vx 参考图：行 56、头像 40、左 16、间距 12、文字 x=68）
    static var ctRowH: CGFloat { o("ctRowH", 56) }
    static var ctAvatar: CGFloat { o("ctAvatar", 40) }
    static var ctPadL: CGFloat { o("ctPadL", 16) }
    static var ctGap: CGFloat { o("ctGap", 12) }
    static var ctIcon: CGFloat { o("ctIcon", 40) }
    static var ctNameSize: CGFloat { o("ctNameSize", 16) }
    static var ctHeadH: CGFloat { o("ctHeadH", 28) }
    static var ctHeadSize: CGFloat { o("ctHeadSize", 15) }
    static var ctIdxSize: CGFloat { o("ctIdxSize", 12.5) }
    static var ctIdxItemH: CGFloat { o("ctIdxItemH", 16.5) }
    static var ctTextX: CGFloat { ctPadL + ctAvatar + ctGap }

    // 发现页 / 我页（按 vx 参考图：行 56、图标 x18、文字 x58、组间线从 x56 开始）
    static var menuH: CGFloat { o("menuH", 56) }
    static var menuPadL: CGFloat { o("menuPadL", 18) }
    static var menuPadR: CGFloat { o("menuPadR", 16) }
    static var menuGap: CGFloat { o("menuGap", 18) }
    static var menuIcon: CGFloat { o("menuIcon", 22) }
    static var menuTextSize: CGFloat { o("menuTextSize", 17) }
    static var groupGap: CGFloat { o("groupGap", 8) }
    static var menuTextX: CGFloat { menuPadL + menuIcon + menuGap }
    /// 我页/发现页行内那条细线的左端
    static var menuLineInset: CGFloat { o("menuLineInset", 56) }

    // 聊天页
    static var msgPad: CGFloat { v(10, 2.8, 12) }
    static var chatAvatar: CGFloat { v(38, 9.8, 42) }
    static var bubblePadH: CGFloat { v(11, 3, 12.6) }
    static var bubblePadV: CGFloat { v(9, 2.3, 9.8) }
    static var composerH: CGFloat { o("composerH", 56) }
    static var composerIconBox: CGFloat { o("composerIconBox", 33) }
    static var composerIcon: CGFloat { o("composerIcon", 28) }
    static var inputH: CGFloat { o("inputH", 39) }
    static var chatFontSize: CGFloat { o("chatFontSize", 17) }
    static var msgTimeSize: CGFloat { o("msgTimeSize", 14) }

    // 朋友圈
    static var coverH: CGFloat { o("coverH", 380) }
    static var coverAvatar: CGFloat { v(52, 17.1, 72) }
    static var momentPadH: CGFloat { o("momentPadH", 22) }
    static var momentAvatar: CGFloat { o("momentAvatar", 44) }
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
    /// "#6F8A38" 这种字符串颜色
    init(hexString: String, fallback: UInt32 = 0x6F8A38) {
        let s = hexString.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        self = Color(UIColor(hex: UInt32(s, radix: 16) ?? fallback))
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color { Color(UIColor.dyn(light, dark)) }
}

/// 逐个色号对着网页版量出来的（浅色 / 深色）
enum C {
    // 颜色也能在 data/ui.json 里改（写成 "#浅色|#深色"）
    static var pageBg      : Color { UIConfig.color("pageBg", 0xEDEDED, 0x0B0B0D) }
    static var navBg       : Color { UIConfig.color("navBg", 0xEDEDED, 0x18181A) }
    static var tabBg       : Color { UIConfig.color("tabBg", 0xF7F7F7, 0x18181A) }
    static var cardBg      : Color { UIConfig.color("cardBg", 0xFFFFFF, 0x1C1C1E) }
    static var chatRowBg   : Color { UIConfig.color("chatRowBg", 0xFFFFFF, 0x2A2A2A) }
    static var pinnedBg    : Color { UIConfig.color("pinnedBg", 0xF2F2F2, 0x333335) }
    static var searchBg    : Color { UIConfig.color("searchBg", 0xFFFFFF, 0x2A2A2C) }
    static var searchIcon  : Color { UIConfig.color("searchIcon", 0xB2B2B2, 0x9A9A9E) }
    static var searchIcon2 : Color { UIConfig.color("searchIcon2", 0x8C8C8C, 0x9A9A9E) }
    static let searchBorder = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(hex: 0xF0F0F0)
    })
    /// 微信页那条白框：浅色下没有描边（就是一块纯白），深色下才有一条很淡的亮边
    static let searchBorderChats = Color(UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor.clear
    })
    static var name        : Color { UIConfig.color("nameColor", 0x1C1C1E, 0xF2F2F7) }
    static var label       : Color { UIConfig.color("labelColor", 0x191919, 0xF2F2F7) }
    static var preview     : Color { UIConfig.color("previewColor", 0xB2B2B2, 0xB2B2B2) }
    static var time        : Color { UIConfig.color("timeColor", 0xC7C7CC, 0xC7C7CC) }
    static var subLabel    : Color { UIConfig.color("subLabelColor", 0x999999, 0x8F8F8F) }
    static var hairline    : Color { UIConfig.color("lineColor", 0xE5E5E5, 0x333335) }
    static var navLine     : Color { UIConfig.color("navLineColor", 0xE8E8E8, 0x2C2C2E) }
    static var green       : Color { UIConfig.color("greenColor", 0x07C160, 0x3EB575) }
    static var red         : Color { UIConfig.color("redColor", 0xFA5151, 0xFA5151) }
    static var orange      : Color { UIConfig.color("orangeColor", 0xFF9500, 0xFF9500) }
    static var tabInk      : Color { UIConfig.color("tabInkColor", 0x191919, 0xB5B5B5) }
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
var fontScale: CGFloat { UIConfig.scale }

func pf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    let scaled = max(9, (size * fontScale).rounded())
    var want = "PingFangSC-Regular"
    if weight == .medium {
        want = "PingFangSC-Medium"
    } else if weight == .semibold || weight == .bold || weight == .heavy || weight == .black {
        want = "PingFangSC-Semibold"
    } else if weight == .light || weight == .thin || weight == .ultraLight {
        want = "PingFangSC-Light"
    }
    if UIFont(name: want, size: scaled) != nil {
        return .custom(want, size: scaled)
    }
    // 兜底：把系统里所有苹方字体列出来，按想要的字重挑一个
    for family in UIFont.familyNames where family.lowercased().contains("pingfang") {
        let names = UIFont.fontNames(forFamilyName: family)
        if names.contains(want) { return .custom(want, size: scaled) }
        if let fallback = names.first { return .custom(fallback, size: scaled) }
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

/* ============================================================
   UI 图标：管理后台「UI 图标」页换过的图标，App 打开时拉一份下来，
   这里存着「标识 → 新的图标」。新图标可以是：
     ① 一段 <svg> 代码   ② 一张图片地址（/uploads/xxx.png）   ③ 一个 emoji
   标识写在每个内置 SVG 的 data-key 里（比如 i.moments、plus.photo），
   系统图标用 sf:xxx（比如 sf:message）。
   ============================================================ */

enum IconOverrides {
    static var map: [String: String] = [:]

    static func custom(_ key: String) -> String? {
        if let v = map[key], !v.isEmpty { return v }
        return nil
    }

    /// 从内置 SVG 里读 data-key
    private static func keyOf(_ markup: String) -> String? {
        guard let r = markup.range(of: "data-key=\"") else { return nil }
        let rest = markup[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let k = String(rest[rest.startIndex..<end])
        return k.isEmpty ? nil : k
    }

    /// 有自定义就用自定义的，没有就用内置那一段
    static func markup(_ builtin: String) -> String {
        if let k = keyOf(builtin), let v = custom(k) { return v }
        return builtin
    }
}

/// 能画四种东西：SVG / 图片 / 文字（emoji）/ 系统图标兜底
struct FlexIcon: View {
    var custom: String?
    var size: CGFloat
    var color: Color
    var symbol: String
    var weight: Font.Weight = .regular

    var body: some View {
        if let v = custom, !v.isEmpty {
            if v.hasPrefix("<svg") {
                SVGIcon(markup: v, size: size, color: color)
            } else if v.hasPrefix("http") || v.hasPrefix("/uploads") || v.hasPrefix("data:") {
                RemoteImage(path: v).frame(width: size, height: size)
            } else {
                Text(v)
                    .font(.system(size: size * 0.86))
                    .foregroundColor(color)
                    .frame(width: size, height: size)
            }
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundColor(color)
                .frame(width: size, height: size)
        }
    }
}
