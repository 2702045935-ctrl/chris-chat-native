import SwiftUI

/// 按住说话时屏幕中间那个提示浮层。
/// 版式照微信那张参考图：**上面一行是「滑到这里 转文字」，中间是麦克风 + 音量波形，
/// 下面一行是主提示「松手 发语音」**；手指滑进哪个区域，哪一块就亮起来。
struct VoiceHUD: View {
    let seconds: Int
    let level: CGFloat
    let willCancel: Bool
    var willTranscribe: Bool = false
    var maxSeconds: Int = 60

    private var bars: Int { 9 }

    /// 主提示：过期/取消/转文字/正常 四种口气
    private var mainHint: String {
        if willCancel { return "松开手指，取消发送" }
        if willTranscribe { return "松手 转文字" }
        return "\(seconds)″　松手 发语音"
    }

    var body: some View {
        VStack(spacing: 12) {
            /* ① 上：转文字区（滑到这里高亮） */
            Text("滑到这里 转文字")
                .font(pf(13))
                .foregroundColor(willTranscribe ? .white : .white.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(willTranscribe ? C.green.opacity(0.95) : Color.white.opacity(0.12))
                )

            /* ② 中：麦克风 + 音量波形 */
            HStack(spacing: 14) {
                Image(systemName: willCancel ? "xmark" : "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(willCancel ? Color(hex: 0xFA5151) : .white)
                    .frame(width: 28)

                HStack(alignment: .center, spacing: 4) {
                    ForEach(0..<bars, id: \.self) { i in
                        let on = CGFloat(i + 1) / CGFloat(bars) <= max(0.12, level)
                        Capsule()
                            .fill(on ? (willCancel ? Color(hex: 0xFA5151) : C.green)
                                     : Color.white.opacity(0.22))
                            .frame(width: 3.5, height: 8 + CGFloat((i % 5)) * 5)
                    }
                }
                .frame(height: 32)
            }

            /* ③ 下：主提示 + 最后 10 秒的倒计时 */
            Text(mainHint)
                .font(pf(13))
                .foregroundColor(.white.opacity(0.92))

            if !willCancel && seconds >= maxSeconds - 10 {
                Text("还可以说 \(max(0, maxSeconds - seconds)) 秒")
                    .font(pf(11.5))
                    .foregroundColor(C.green)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(willCancel ? 0.72 : 0.58))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(willCancel ? Color(hex: 0xFA5151).opacity(0.85) : Color.white.opacity(0.12),
                        lineWidth: 1)
        )
    }
}
