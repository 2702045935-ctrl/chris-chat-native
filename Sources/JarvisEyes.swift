import SwiftUI

/* AI 助手的小头像：仿微信「小微」那种 —— 一颗白白圆润的小脸 + 两只大眼睛。
   会眨眼（偶尔连眨两下）、会左右瞟、会微微抬头低头、还会呼吸，
   放在会话页顶栏最左边，点一下进 AI 助手的对话。 */
struct JarvisEyesAvatar: View {
    var size: CGFloat = 28

    /// 0 = 睁着，1 = 闭上
    @State private var blink: CGFloat = 0
    /// -1 看左 · 1 看右
    @State private var lookX: CGFloat = 0
    /// -1 看下 · 1 看上
    @State private var lookY: CGFloat = 0.15
    /// 0~1 呼吸
    @State private var breathe: CGFloat = 0
    /// 轻轻点头
    @State private var nod: CGFloat = 0

    @State private var alive = false

    private var eyeW: CGFloat { size * 0.20 }
    private var eyeH: CGFloat { size * 0.30 }

    var body: some View {
        ZStack {
            /* 白白的小脸（带一点上亮下暗，别太平） */
            Circle()
                .fill(LinearGradient(colors: [Color.white, Color(hexString: "#EDF1F7")],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(Color(hexString: "#DCE2EC"), lineWidth: 0.7))
                .shadow(color: Color.black.opacity(0.12), radius: 1.5, y: 0.5)

            HStack(spacing: size * 0.185) {
                eye
                eye
            }
            .offset(y: size * 0.015)
        }
        .frame(width: size, height: size)
        .scaleEffect(1 + breathe * 0.05)
        .offset(y: nod * size * 0.03)
        .task { await runLoops() }
    }

    private var eye: some View {
        Capsule()
            .fill(Color(hexString: "#1B1D22"))
            .frame(width: eyeW, height: max(size * 0.035, eyeH * (1 - blink * 0.94)))
            /* 眼珠跟着左右瞟、偶尔抬一下眼皮 */
            .offset(x: lookX * size * 0.055, y: -lookY * size * 0.028)
            /* 眼睛里那点高光，看着更像活的 */
            .overlay(alignment: .top) {
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: eyeW * 0.36, height: eyeW * 0.36)
                    .offset(x: -eyeW * 0.14, y: eyeH * 0.10)
                    .opacity(blink > 0.6 ? 0 : 1)
            }
            .animation(.easeInOut(duration: 0.42), value: lookX)
            .animation(.easeInOut(duration: 0.42), value: lookY)
    }

    /* 一只「活」的动画循环：眨眼、瞟一瞟、呼吸、轻轻点头各自按自己的节奏来 */
    private func runLoops() async {
        guard !alive else { return }
        alive = true

        /* 呼吸 + 点头：慢慢来回 */
        withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) { breathe = 1 }
        withAnimation(.easeInOut(duration: 2.9).repeatForever(autoreverses: true)) { nod = 1 }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await blinkLoop() }
            group.addTask { await glanceLoop() }
        }
    }

    /* 眨眼：2.2~4.6 秒一次，三成概率连眨两下 */
    private func blinkLoop() async {
        while !Task.isCancelled {
            let gap = Double.random(in: 2.2...4.6)
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
            if Task.isCancelled { return }
            await blinkOnce()
            if Bool.random() && Double.random(in: 0...1) < 0.3 {
                try? await Task.sleep(nanoseconds: 160_000_000)
                if Task.isCancelled { return }
                await blinkOnce()
            }
        }
    }

    private func blinkOnce() async {
        withAnimation(.easeInOut(duration: 0.085)) { blink = 1 }
        try? await Task.sleep(nanoseconds: 105_000_000)
        withAnimation(.easeInOut(duration: 0.13)) { blink = 0 }
    }

    /* 左右瞟：自己走自己的节奏，和眨眼错开 */
    private func glanceLoop() async {
        while !Task.isCancelled {
            let x: CGFloat = [CGFloat(-1), 1].randomElement() ?? 1
            withAnimation(.easeInOut(duration: 0.7)) {
                lookX = x * CGFloat.random(in: 0.45...1)
                lookY = CGFloat.random(in: -0.35...0.35)
            }
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 1.3...2.6) * 1_000_000_000))
        }
    }
}
