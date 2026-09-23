import SwiftUI
import UIKit

/* ============================================================
   实时读 ScrollView 的 contentOffset（用 UIKit 订阅，比 SwiftUI 的
   PreferenceKey 稳得多）—— 会话页「下拉二楼」要靠它判断「是不是已经
   在最上面」，以前用 GeometryReader 读偏移经常读不到，导致拉不下来。
   ============================================================ */
struct ScrollOffsetProbe: UIViewRepresentable {
    final class Coordinator {
        var obs: NSKeyValueObservation?
        var scroll: UIScrollView?
        var report: (CGFloat) -> Void = { _ in }
    }

    var onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.report = onChange
        DispatchQueue.main.async {
            guard let sv = Self.findScroll(uiView) else { return }
            if context.coordinator.scroll !== sv {
                context.coordinator.scroll = sv
                context.coordinator.obs = sv.observe(\.contentOffset, options: [.new]) { s, _ in
                    context.coordinator.report(s.contentOffset.y)
                }
                context.coordinator.report(sv.contentOffset.y)
            }
        }
    }

    static func findScroll(_ view: UIView) -> UIScrollView? {
        var cur: UIView? = view
        while let v = cur {
            if let s = v as? UIScrollView { return s }
            cur = v.superview
        }
        return nil
    }
}
