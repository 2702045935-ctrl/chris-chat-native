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
/// 视频气泡的尺寸（和微信一致）：按视频本身的横竖比例等比缩放，**不裁剪**。
/// 横屏：宽最多 250、高最多 170；竖屏：宽最多 190、高最多 250；太小/太扁兜一个最小边。
/// 老消息没记过宽高（w/h）就退回原来那个 160×205。
func videoBubbleSize(w: Int, h: Int) -> CGSize {
    let fw = CGFloat(w), fh = CGFloat(h)
    guard fw > 0, fh > 0 else { return CGSize(width: 160, height: 205) }
    let aspect = fw / fh
    let maxW: CGFloat = aspect >= 1 ? 250 : 190
    let maxH: CGFloat = aspect >= 1 ? 170 : 250
    var cw = maxW
    var ch = cw / aspect
    if ch > maxH { ch = maxH; cw = ch * aspect }
    /* 超宽幅/超窄幅：缩到最小边 110 以上，别成一条线 */
    if min(cw, ch) < 110 {
        let k = 110 / min(cw, ch)
        cw *= k; ch *= k
        if cw > maxW { let k2 = maxW / cw; cw *= k2; ch *= k2 }
        if ch > maxH { let k2 = maxH / ch; cw *= k2; ch *= k2 }
    }
    return CGSize(width: cw.rounded(), height: ch.rounded())
}

struct VideoBubble: View {
    let message: Message
    let mine: Bool
    var onOpen: (URL, UIImage?) -> Void = { _, _ in }

    private var info: (url: String, cover: String, seconds: Int, w: Int, h: Int) {
        let o = jsonDict(message.body)
        return ((o["url"] as? String) ?? "",
                (o["cover"] as? String) ?? "",
                (o["seconds"] as? Int) ?? 0,
                (o["w"] as? Int) ?? 0,
                (o["h"] as? Int) ?? 0)
    }

    /// 气泡尺寸：有视频本身的比例就按比例（微信逻辑），老消息退回 160×205
    private var size: CGSize { videoBubbleSize(w: info.w, h: info.h) }

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
            .frame(width: size.width, height: size.height)
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

/* ============================================================
   「发送中」的视频/实况气泡（微信的逻辑）：
   视频还在压缩/上传时，气泡就已经出来了 —— 封面 + 中间一圈进度 + 百分比，
   不用盯着「发送中…」几个字干等。
   ============================================================ */
struct SendingVideoBubble: View {
    var cover: UIImage?
    var progress: Double          // 0…1

    /// 尺寸和最终那条视频气泡一致（用封面的比例算），发送中→发送完不会跳一下
    private var size: CGSize {
        guard let c = cover, c.size.width > 0, c.size.height > 0 else {
            return videoBubbleSize(w: 0, h: 0)
        }
        return videoBubbleSize(w: Int(c.size.width), h: Int(c.size.height))
    }

    var body: some View {
        ZStack {
            if let c = cover {
                Image(uiImage: c)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.dyn(0xDDDDDD, 0x333333)
            }
            Color.black.opacity(0.42)
            /* 就一圈进度 + 中间那个百分比，**不写任何字**（微信就是这样，
               不出现"正在上传"这类文字）。 */
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: 3)
                        .frame(width: 38, height: 38)
                    /* 一开始也给一小段白弧：一出现就能看出"这是在传"，不是卡住的图标 */
                    Circle()
                        .trim(from: 0, to: max(0.04, min(1, progress)))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 38, height: 38)
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.95))
                }
                Text(progress > 0.01 ? "\(Int(min(1, progress) * 100))%" : "…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
