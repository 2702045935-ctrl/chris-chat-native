import SwiftUI
import UIKit

/* ============================================================ 颜色 / 主题 */

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

enum Brand {
    static let green       = Color(hex: 0x07C160)
    static let red         = Color(hex: 0xFA5151)
    static let orange      = Color(hex: 0xFA9D3C)

    static let pageBg      = Color.dyn(0xEDEDED, 0x000000)
    static let cellBg      = Color.dyn(0xFFFFFF, 0x1C1C1E)
    static let navBg       = Color.dyn(0xEDEDED, 0x1C1C1E)
    static let barBg       = Color.dyn(0xF7F7F7, 0x1C1C1E)
    static let fieldBg     = Color.dyn(0xF2F2F2, 0x2C2C2E)

    static let label       = Color.dyn(0x181818, 0xEDEDED)
    static let subLabel    = Color.dyn(0x9E9E9E, 0x8E8E93)
    static let timeLabel   = Color.dyn(0xB2B2B2, 0x8E8E93)
    static let divider     = Color.dyn(0xE5E5E5, 0x2C2C2E)
    static let line        = Color.dyn(0xE5E5E5, 0x2C2C2E)

    static let bubbleMine  = Color.dyn(0x95EC69, 0x3EB575)
    static let bubbleOther = Color.dyn(0xFFFFFF, 0x2C2C2E)
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

/* ============================================================ 图片加载 */

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

/// 从「/uploads/xxx.png」「http://…」「data:image/…」三种写法加载图片
struct RemoteImage: View {
    let path: String
    var icon: String = "photo"

    @State private var image: UIImage?
    @State private var started = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image = image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.dyn(0xE9E9E9, 0x2C2C2E)
                        Image(systemName: icon)
                            .font(.system(size: max(10, min(geo.size.width, geo.size.height) * 0.40)))
                            .foregroundColor(Color.dyn(0xC4C4C4, 0x636366))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear {
            if !started { started = true; Task { await load() } }
        }
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
        } catch {
            // 加载失败就保持占位图
        }
    }
}

struct Avatar: View {
    let path: String
    var size: CGFloat = 48
    var radius: CGFloat = 5

    var body: some View {
        RemoteImage(path: path, icon: "person.fill")
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
            )
    }
}

/* ============================================================ 时间格式 */

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

    /// 会话列表右上角：今天 HH:mm / 昨天 / 星期三 / M月d日 / yyyy年M月d日
    static func list(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 99
        if days < 7 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "EEEE"
            return f.string(from: d)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    /// 聊天气泡上面的时间条
    static func bubble(_ s: String?) -> String {
        guard let d = date(s) else { return "" }
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(d) {
            f.dateFormat = "'昨天' HH:mm"
        } else {
            f.dateFormat = "M月d日 HH:mm"
        }
        return f.string(from: d)
    }

    static func minutesBetween(_ a: String?, _ b: String?) -> Int {
        guard let d1 = date(a), let d2 = date(b) else { return 9999 }
        return abs(Int(d2.timeIntervalSince(d1) / 60))
    }

    /// 朋友圈那种「3分钟前 / 2小时前 / 3天前」
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

/* ============================================================ 其它小工具 */

/// 中文取拼音首字母（通讯录分组用）
func pinyinInitial(_ text: String) -> String {
    guard !text.isEmpty else { return "#" }
    let first = String(text[text.startIndex])
    if first.range(of: "^[A-Za-z]$", options: .regularExpression) != nil {
        return first.uppercased()
    }
    var latin = first.applyingTransform(StringTransform.toLatin, reverse: false) ?? first
    latin = latin.applyingTransform(StringTransform.stripDiacritics, reverse: false) ?? latin
    latin = latin.trimmingCharacters(in: .whitespacesAndNewlines)
    if let c = latin.first, c.isLetter {
        return String(c).uppercased()
    }
    return "#"
}

struct HairLine: View {
    var inset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(Brand.divider)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

struct UnreadBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Brand.red))
        }
    }
}
