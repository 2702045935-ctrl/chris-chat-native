import SwiftUI

/// 和微信一样：从屏幕左边缘往右一滑就回上一页，手指全程跟手，松手弹回或退出
struct SwipeBackModifier: ViewModifier {
    let enabled: Bool
    let onBack: () -> Void

    @State private var offsetX: CGFloat = 0
    @State private var tracking = false

    private var width: CGFloat { max(1, L.width) }

    func body(content: Content) -> some View {
        ZStack {
            content
                .offset(x: offsetX)
                /* 侧滑返回一旦开始，就把页面的点击关掉 ——
                   否则手指从某一行上起滑、松手时这一行会被当成「点了一下」（用户反馈的误触）。 */
                .allowsHitTesting(!tracking)
                .overlay(
                    Color.black
                        .opacity(0.16 * Double(min(1, offsetX / width)))
                        .allowsHitTesting(false)
                )
        }
        .background(C.pageBg)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { value in
                    guard enabled else { return }
                    if !tracking {
                        guard value.startLocation.x <= 34 else { return }
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        guard value.translation.width > 0 else { return }
                        tracking = true
                    }
                    offsetX = max(0, value.translation.width)
                }
                .onEnded { value in
                    guard tracking else { return }
                    tracking = false
                    let far = offsetX > width * 0.28
                    let fast = value.predictedEndTranslation.width > width * 0.4
                    if far || fast {
                        withAnimation(.easeOut(duration: 0.2)) { offsetX = width }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            onBack()
                            offsetX = 0
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.22)) { offsetX = 0 }
                    }
                }
        )
        .onAppear { tracking = false; offsetX = 0 }
    }
}

extension View {
    /// 左边缘右滑返回（和手机微信一样）
    func swipeBack(_ enabled: Bool = true, onBack: @escaping () -> Void) -> some View {
        modifier(SwipeBackModifier(enabled: enabled, onBack: onBack))
    }
}
