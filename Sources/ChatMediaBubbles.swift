import SwiftUI
import AVFoundation

/// 解析气泡里的 JSON（图片/视频消息的内容都是一小段 JSON）
private func jsonDict(_ s: String) -> [String: Any] {
    guard let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

/* ============================================================
   聊天里的两种新气泡（和微信一致）：
   · 视频消息：封面 + 播放三角 + 时长；点一下全屏播放
   · 实况照片：静态图 + 左上角「实况」角标；**长按播那一小段**
   播放复用视频号那套（AVPlayerLayer + 播放器池）。
   ============================================================ */

/// 视频气泡
struct VideoBubble: View {
    let message: Message
    let mine: Bool
    var onOpen: (URL, UIImage?) -> Void = { _, _ in }

    private var info: (url: String, cover: String, seconds: Int) {
        let o = jsonDict(message.body)
        return ((o["url"] as? String) ?? "",
                (o["cover"] as? String) ?? "",
                (o["seconds"] as? Int) ?? 0)
    }

    private var width: CGFloat { min(230, 132 + CGFloat(min(info.seconds, 40)) * 2.2) }

    var body: some View {
        Button {
            let u = info.url
            let full = u.hasPrefix("http") ? u : API.shared.base + u
            if let url = URL(string: full) { onOpen(url, nil) }
        } label: {
            ZStack {
                if !info.cover.isEmpty {
                    RemoteImage(path: info.cover, mode: .fill, maxSide: 1280)
                } else {
                    Color.dyn(0xDDDDDD, 0x333333)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.35), radius: 6)
                if info.seconds > 0 {
                    VStack { Spacer()
                        HStack { Spacer()
                            Text(String(format: "%02d:%02d", info.seconds / 60, info.seconds % 60))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                        }
                    }
                    .padding(7)
                }
            }
            .frame(width: width, height: width * 1.28)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 实况照片气泡：静态图 + 「实况」角标，长按播动效
struct LivePhotoBubble: View {
    let message: Message
    var onPlay: (URL) -> Void = { _ in }

    @State private var pressed = false

    private var info: (image: String, video: String) {
        let o = jsonDict(message.body)
        return ((o["image"] as? String) ?? "", (o["video"] as? String) ?? "")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(path: info.image, mode: .fill, maxSide: 1600)
            Text(Tr("实况"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.42)))
                .padding(7)
        }
        .frame(width: 150, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .scaleEffect(pressed ? 0.97 : 1)
        .onLongPressGesture(minimumDuration: 0.25, pressing: { p in
            pressed = p
            if !p { return }
            let v = info.video
            let full = v.hasPrefix("http") ? v : API.shared.base + v
            if let url = URL(string: full) { onPlay(url) }
        }, perform: { })
    }
}

/// 全屏播放一个视频（聊天里点视频气泡用它）
struct VideoPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let p = player {
                PlayerLayerView(player: p).ignoresSafeArea()
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(12)
                Spacer()
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            p.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                   object: p.currentItem, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
            player = p
            p.play()
        }
        .onDisappear { player?.pause(); player = nil }
    }
}
