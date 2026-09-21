import SwiftUI

/* 贾维斯AI 的头像：两颗会动的小眼睛（会眨、会左右瞟一眼）
   用在会话列表最左边那一格（和头像同尺寸同圆角） */
struct JarvisEyesAvatar: View {
    var size: CGFloat = 40

    @State private var blink = false
    @State private var look: CGFloat = 0
    @State private var pulse = false

    private var eyeW: CGFloat { size * 0.19 }
    private var eyeH: CGFloat { size * 0.26 }

    var body: some View {
        ZStack {
            /* 深色底 + 一点青色光晕，像机器人的脸 */
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(hexString: "#12161F"), Color(hexString: "#1E2A38")],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(hexString: "#39D2C0").opacity(pulse ? 0.55 : 0.15), lineWidth: 1)
                )
            HStack(spacing: size * 0.16) {
                eye
                eye
            }
            .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .onAppear {
            /* 每隔 3 秒眨一下 */
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.10)) { blink = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(.easeInOut(duration: 0.14)) { blink = false }
                }
            }
            /* 左右瞟：慢慢来回晃 */
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { look = 1 }
            /* 呼吸光晕 */
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var eye: some View {
        Capsule()
            .fill(Color(hexString: "#8FF5E6"))
            .frame(width: eyeW, height: blink ? size * 0.035 : eyeH)
            .offset(x: look * size * 0.035)
            .animation(.easeInOut(duration: 1.6), value: look)
    }
}
