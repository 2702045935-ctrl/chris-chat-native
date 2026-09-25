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

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .any(of: [.images, .videos, .livePhotos])
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

/* ---------------------------------------------------------- 视频工具 */

enum MediaTool {
    /// 上传一个本地文件（走 /api/upload/raw 那条二进制通道，比 base64 省内存）
    static func upload(_ url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let mime = (ext == "mov") ? "video/quicktime" : "video/mp4"
        return try? await API.shared.uploadBinary(data, mime: mime)
    }

    /// 视频时长（秒）
    static func seconds(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration))?.seconds ?? 0
        return max(1, Int(d.rounded()))
    }

    /// 取第一帧当封面（返回 dataURL，服务端会把图存下来）
    static func firstFrame(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image else { return nil }
        let img = UIImage(cgImage: cg)
        guard let data = img.jpegData(compressionQuality: 0.82) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// 压缩视频（微信默认就会压）：720p，压完再发；「原图」开关打开就跳过这一步
    static func compress(_ url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("chris-send-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
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
