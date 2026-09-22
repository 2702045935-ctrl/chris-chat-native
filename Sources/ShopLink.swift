import SwiftUI
import SafariServices
import UIKit

/* ============================================================
   AI 发来的「点外卖 / 买东西」卡片
   —— 不甩一串网址给用户：App 直接跳（装了淘宝就跳淘宝 App，
   没装就用 App 内的 Safari 打开），点卡片也能再跳一次。
   ============================================================ */

struct ShopLink: Hashable {
    var title: String
    var sub: String
    var url: String
    var scheme: String

    /// 服务端把卡片内容放在消息的 content 里（JSON）
    init?(json: String) {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        title = (o["title"] as? String) ?? "打开"
        sub = (o["sub"] as? String) ?? ""
        url = (o["url"] as? String) ?? ""
        scheme = (o["scheme"] as? String) ?? ""
        if url.isEmpty && scheme.isEmpty { return nil }
    }
}

/// 点了卡片 / 自动跳：先试 App 的 scheme（装了淘宝就直接进淘宝），
/// 不行再交给外面的 inApp 回调（App 内 Safari 打开网页）
@MainActor
enum ShopOpener {
    static func open(_ link: ShopLink, inApp: @escaping (URL) -> Void) {
        if !link.scheme.isEmpty, let u = URL(string: link.scheme), UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
            return
        }
        if let u = URL(string: link.url) { inApp(u) }
    }
}

/// App 内的 Safari（不跳出我们的 App）
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: cfg)
        vc.preferredControlTintColor = UIColor(red: 0.34, green: 0.42, blue: 0.58, alpha: 1)
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }
}

/// sheet(item:) 要 Identifiable
struct WebURL: Identifiable {
    let id = UUID()
    var url: URL
}

/// 聊天里那张卡片
struct ShopLinkCard: View {
    let link: ShopLink
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(hexString: "#FF5000"))
                    Text("淘")
                        .font(pf(16, .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title)
                        .font(pf(15, .medium))
                        .foregroundColor(C.bubbleText)
                        .lineLimit(1)
                    Text(link.sub)
                        .font(pf(12))
                        .foregroundColor(C.subLabel)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Text(Tr("打开"))
                    .font(pf(12, .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(hexString: "#FF5000")))
            }
            .padding(10)
            .frame(width: 232, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dyn(0xFFFFFF, 0x2C2C2E)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.dyn(0xE8E8E8, 0x3A3A3C), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
