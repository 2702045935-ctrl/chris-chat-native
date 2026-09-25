import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/* ============================================================
   聊天里的「照片」入口 —— 支持三种：
     · 普通照片  → onImage
     · 视频      → onVideo（给一个临时文件 URL，调用方负责上传）
     · 实况照片  → onLive（实况 = 一张图 + 一小段视频，两个都给）
   为什么要单独写一个：老的 PhotoPicker 写死了 filter = .images、只 loadObject(UIImage)，
   选视频/实况时那个判断直接 false，什么都不发生（用户看到的就是「发不了」）。
   ============================================================ */

struct MediaPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    var onLive: (UIImage, URL) -> Void
    /// 只挑视频（朋友圈发视频用）
    var videosOnly: Bool = false

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = videosOnly ? .videos : .any(of: [.images, .videos, .livePhotos])
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MediaPicker
        init(_ p: MediaPicker) { parent = p }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { return }
            let hasMovie = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let hasImage = provider.canLoadObject(ofClass: UIImage.self) ||
                provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)

            /* 实况：同一个 provider 既能给图、也能给视频 —— 两个都取 */
            if hasMovie && hasImage {
                loadImage(provider) { img in
                    guard let img = img else { return }
                    self.loadMovie(provider) { url in
                        guard let url = url else { return }
                        DispatchQueue.main.async { self.parent.onLive(img, url) }
                    }
                }
                return
            }
            /* 视频 */
            if hasMovie {
                loadMovie(provider) { url in
                    guard let url = url else { return }
                    DispatchQueue.main.async { self.parent.onVideo(url) }
                }
                return
            }
            /* 普通照片 */
            loadImage(provider) { img in
                guard let img = img else { return }
                DispatchQueue.main.async { self.parent.onImage(img) }
            }
        }

        private func loadImage(_ p: NSItemProvider, _ done: @escaping (UIImage?) -> Void) {
            if p.canLoadObject(ofClass: UIImage.self) {
                p.loadObject(ofClass: UIImage.self) { obj, _ in done(obj as? UIImage) }
                return
            }
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done(data.flatMap { UIImage(data: $0) })
            }
        }

        /// 取视频文件：系统给的是临时文件，必须在回调里马上拷出来（出了回调就没了）
        private func loadMovie(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
            p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url = url else { done(nil); return }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chris-video-\(UUID().uuidString).mov")
                do {
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: url, to: dst)
                    done(dst)
                } catch { done(nil) }
            }
        }
    }
}

/* ============================================================
   朋友圈的相册入口（微信那个 ＋ / 「从相册选择」）：
   · 照片一次可以挑多张（最多 9 张，顺序就是选图顺序）
   · 挑到视频就按「一条视频」发（微信也是：视频和照片不混着发）
   · 实况照片按静态图算（朋友圈暂时按图片发）
   ============================================================ */

enum MomentPickResult {
    case images([UIImage])
    case video(URL)
}

struct MomentPicker: UIViewControllerRepresentable {
    /// 最多几张（微信 9 张）
    var limit: Int = 9
    var onResult: (MomentPickResult) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .any(of: [.images, .videos])       // 关键：照片和视频都能选
        cfg.selectionLimit = max(1, limit)
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MomentPicker
        init(_ p: MomentPicker) { parent = p }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            /* 挑到视频（实况不算，实况按照片发）→ 按一条视频走 */
            let movie = results.first { r in
                let p = r.itemProvider
                return p.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    && !p.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
            }
            if let mv = movie {
                loadMovie(mv.itemProvider) { url in
                    guard let url = url else { return }
                    DispatchQueue.main.async { self.parent.onResult(.video(url)) }
                }
                return
            }
            loadImages(results) { imgs in
                guard !imgs.isEmpty else { return }
                DispatchQueue.main.async { self.parent.onResult(.images(imgs)) }
            }
        }

        private func loadImage(_ p: NSItemProvider, _ done: @escaping (UIImage?) -> Void) {
            if p.canLoadObject(ofClass: UIImage.self) {
                p.loadObject(ofClass: UIImage.self) { obj, _ in done(obj as? UIImage) }
                return
            }
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done(data.flatMap { UIImage(data: $0) })
            }
        }

        /// 一次挑多张：全部取完一次性回调（顺序保持选择顺序）
        private func loadImages(_ results: [PHPickerResult], _ done: @escaping ([UIImage]) -> Void) {
            var out = [UIImage?](repeating: nil, count: results.count)
            let group = DispatchGroup()
            for (i, r) in results.enumerated() {
                group.enter()
                loadImage(r.itemProvider) { img in
                    out[i] = img
                    group.leave()
                }
            }
            group.notify(queue: .main) { done(out.compactMap { $0 }) }
        }

        private func loadMovie(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
            p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url = url else { done(nil); return }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chris-moment-\(UUID().uuidString).mov")
                do {
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: url, to: dst)
                    done(dst)
                } catch { done(nil) }
            }
        }
    }
}

/* ---------------------------------------------------------- 视频工具 */

enum MediaTool {
    /// 上传一个本地文件（走 /api/upload/raw 那条二进制通道，比 base64 省内存）
    static func upload(_ url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        let mime = (ext == "mov") ? "video/quicktime" : "video/mp4"
        /* 直接读文件会先把整段视频塞进内存（几十 MB 就很容易被系统杀掉），
           走 URLSession 的文件流上传 + 进度回调，内存友好还能出进度条。 */
        return try? await API.shared.uploadBinaryFile(url, mime: mime) { _ in }
    }

    /// 带进度的上传（视频发送时那个转圈进度条）。
    /// skipServerTranscode：这条已经在手机上压好了，让服务器别再压第二遍。
    static func upload(_ url: URL, onProgress: @escaping (Double) -> Void,
                       skipServerTranscode: Bool = false) async -> String? {
        let ext = url.pathExtension.lowercased()
        let mime = (ext == "mov") ? "video/quicktime" : "video/mp4"
        return try? await API.shared.uploadBinaryFile(url, mime: mime,
                                                     skipTranscode: skipServerTranscode,
                                                     onProgress: onProgress)
    }

    /// 视频时长（秒）
    static func seconds(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration))?.seconds ?? 0
        return max(1, Int(d.rounded()))
    }

    /// 视频的显示宽高（像素）。注意要带上 preferredTransform ——
    /// 手机竖着拍的视频 naturalSize 是 1920x1080 + 一个 90° 旋转，
    /// 不对它做变换就会把竖屏视频当成横屏，气泡尺寸正好反过来。
    static func aspect(_ url: URL) async -> (w: Int, h: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let sz = try? await track.load(.naturalSize),
              let tx = try? await track.load(.preferredTransform) else { return nil }
        let t = sz.applying(tx)
        let w = Int(abs(t.width).rounded())
        let h = Int(abs(t.height).rounded())
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// 取第一帧当封面（返回图片本身；调用方把它上传掉，拿服务器路径写进消息里）
    static func firstFrame(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 这个视频还需不需要压？
    /// 重编码是把整段视频一秒一秒重新算一遍，几十秒的视频要等十几秒 —— 用户感觉就是"发视频很慢"。
    /// 已经够小够清楚的（≤8MB、≤60 秒、长边 ≤1280）就直接发，不压；微信也是这么干的。
    static func needsCompress(_ url: URL) async -> Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        let asset = AVURLAsset(url: url)
        let secs = (try? await asset.load(.duration))?.seconds ?? 0
        var longSide = 0
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first,
           let sz = try? await track.load(.naturalSize) {
            longSide = Int(max(abs(sz.width), abs(sz.height)))
        }
        if size > 0, size <= 8 * 1024 * 1024, secs > 0, secs <= 60, longSide > 0, longSide <= 1280 {
            return false
        }
        return true
    }

    /// 压缩视频（微信默认就会压）：720p，压完再发；「原图」开关打开就跳过这一步。
    /// onProgress：0…1。AVAssetExportSession 自己不通知进度，只能轮询它的 progress。
    static func compress(_ url: URL, onProgress: ((Double) -> Void)? = nil) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("chris-send-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        /* 进度：AVAssetExportSession 的 progress 在有的机型/有的视频上会一直停在 0，
           用户看到的就是「进度条一直不动」。所以再叠一层**时间估算**兜底：
           压缩耗时大约跟视频时长成正比，按 0.5 倍时长估，取两者较大的那个，
           真压完再跳到 1。这样进度条始终在动。 */
        let t0 = Date()
        let secs = (try? await asset.load(.duration))?.seconds ?? 10
        let guessSpan = max(1.5, min(60, secs * 0.5))
        let poll = Task {
            while !Task.isCancelled {
                let real = Double(export.progress)
                let elapsed = Date().timeIntervalSince(t0)
                let guess = min(0.95, elapsed / guessSpan)
                onProgress?(max(real, guess))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        poll.cancel()
        onProgress?(1)
        return export.status == .completed ? out : nil
    }
}

/* ============================================================
   选完之后的发送预览页（和微信一致）：
     · 左边预览，底部两个开关：「原图」和「实况」（实况只在实况照片时出现）
     · 点「发送」才真发出去；不点就取消，不会误发
   ============================================================ */

struct MediaSendSheet: View {
    enum Payload {
        case image(UIImage)
        case video(URL, UIImage?)          // 视频文件 + 预览图
        case live(UIImage, URL)            // 实况：静态图 + 那一小段动效
    }

    let payload: Payload
    /// (要不要按实况发, 要不要发原图)
    var onSend: (Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var liveOn = false        // 微信：实况默认关，按静态图发
    @State private var originalOn = false    // 默认压缩

    private var isLive: Bool { if case .live = payload { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                preview
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                if isLive {
                    toggleRow(Tr("实况"), sub: Tr("打开后对方长按可以看这段动效（两边都是 iPhone 才有效）"), on: $liveOn)
                }
                toggleRow(Tr("原图"), sub: Tr("不压缩，画质最好但发得慢、对方加载慢"), on: $originalOn)

                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Text(Tr("取消"))
                            .font(.system(size: 16))
                            .foregroundColor(C.label)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dyn(0xEFEFF1, 0x2C2C2E)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSend(liveOn, originalOn)
                        dismiss()
                    } label: {
                        Text(Tr("发送"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var preview: some View {
        switch payload {
        case .image(let img):
            Image(uiImage: img).resizable().scaledToFit()
        case .video(_, let cover):
            if let c = cover {
                Image(uiImage: c).resizable().scaledToFit()
                    .overlay(Image(systemName: "play.circle.fill").font(.system(size: 46)).foregroundColor(.white.opacity(0.9)))
            } else {
                Image(systemName: "video.fill").font(.system(size: 54)).foregroundColor(.white.opacity(0.8))
            }
        case .live(let img, _):
            Image(uiImage: img).resizable().scaledToFit()
                .overlay(alignment: .topLeading) {
                    Text(Tr("实况")).font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                        .padding(12)
                }
        }
    }

    private func toggleRow(_ title: String, sub: String, on: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundColor(C.label)
                Text(sub).font(.system(size: 12)).foregroundColor(C.subLabel)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on).labelsHidden()
        }
    }
}
