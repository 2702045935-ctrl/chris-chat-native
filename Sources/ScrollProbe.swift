import SwiftUI
import UIKit

/* ============================================================
   实时读 ScrollView 的 contentOffset（用 UIKit 订阅，比 SwiftUI 的
   PreferenceKey 稳得多）—— 会话页「下拉二楼」要靠它判断「是不是已经
   在最上面」，以前用 GeometryReader 读偏移经常读不到，导致拉不下来。
   ============================================================ */
struct ScrollOffsetProbe: UIViewRepresentable {
    final class Coordinator {
        var obsOffset: NSKeyValueObservation?
        var obsDrag: NSKeyValueObservation?
        var scroll: UIScrollView?
        var report: (CGFloat) -> Void = { _ in }
        var reportDrag: (Bool) -> Void = { _ in }
    }

    var onChange: (CGFloat) -> Void
    /// 手指是不是正按着拖（微信那套「下拉二楼」要在松手那一下做判断，光有偏移不够）
    var onDragChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.report = onChange
        context.coordinator.reportDrag = onDragChange
        DispatchQueue.main.async {
            guard let sv = Self.findScroll(uiView) else { return }
            if context.coordinator.scroll !== sv {
                context.coordinator.scroll = sv
                /* 列表很短（没几条会话）时默认不会回弹，下拉二楼就拉不出来 —— 强制打开 */
                sv.alwaysBounceVertical = true
                context.coordinator.obsOffset = sv.observe(\.contentOffset, options: [.new]) { s, _ in
                    context.coordinator.report(s.contentOffset.y)
                }
                context.coordinator.obsDrag = sv.observe(\.isDragging, options: [.new]) { s, _ in
                    context.coordinator.reportDrag(s.isDragging)
                }
                context.coordinator.report(sv.contentOffset.y)
                context.coordinator.reportDrag(sv.isDragging)
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
