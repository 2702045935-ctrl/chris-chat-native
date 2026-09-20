import SwiftUI

/// 按住说话时屏幕中间那个提示浮层（麦克风 + 音量条 + "松开发送，上滑取消"）
struct VoiceHUD: View {
    let seconds: Int
    let level: CGFloat
    let willCancel: Bool

    private var bars: Int { 9 }

    var body: some View {
        VStack(spacing: 14) {
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

            Text(willCancel ? "松开手指，取消发送" : "\(seconds)″ 松开发送，上滑取消")
                .font(pf(13))
                .foregroundColor(.white.opacity(0.92))
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
