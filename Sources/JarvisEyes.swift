import SwiftUI

/* 贾维斯的小头像：仿微信「小微」那种 —— 一颗白白圆润的小脸 + 两只黑眼睛
   会眨眼、会左右瞟，放在会话页顶栏最左边。 */
struct JarvisEyesAvatar: View {
    var size: CGFloat = 26

    @State private var blink = false
    @State private var look: CGFloat = 0
    @State private var tilt: Double = 0

    private var eyeW: CGFloat { size * 0.165 }
    private var eyeH: CGFloat { size * 0.235 }

    var body: some View {
        ZStack {
            /* 白白的小脸（带一点上亮下暗，别太平） */
            Circle()
                .fill(LinearGradient(colors: [Color.white, Color(hexString: "#EDF1F7")],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color(hexString: "#DCE2EC"), lineWidth: 0.7))
                .shadow(color: Color.black.opacity(0.12), radius: 1.5, y: 0.5)

            HStack(spacing: size * 0.19) {
                eye
                eye
            }
            .offset(y: size * 0.01)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(tilt))
        .onAppear {
            /* 眨眼：每 3 秒眨一下，偶尔连眨两下（更像活的） */
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.09)) { blink = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                    withAnimation(.easeInOut(duration: 0.13)) { blink = false }
                }
            }
            /* 左右瞟 */
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { look = 1 }
            /* 轻轻歪头 */
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { tilt = 4 }
        }
    }

    private var eye: some View {
        Capsule()
            .fill(Color(hexString: "#1B1D22"))
            .frame(width: eyeW, height: blink ? size * 0.03 : eyeH)
            .offset(x: look * size * 0.028)
            .animation(.easeInOut(duration: 1.8), value: look)
    }
}
