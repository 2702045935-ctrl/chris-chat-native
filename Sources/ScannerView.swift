import SwiftUI
import AVFoundation
import CoreImage
import Vision

/* ============================================================
   相册二维码识别（跑在后台线程）
   ① Vision（VNDetectBarcodesRequest）：新版系统识别率最高，倾斜、有背景的照片也能认；
   ② 认不到再用老的 CIDetector 兜一次（老系统上它反而稳）。
   两条都认不到才提示「没找到二维码」——保证每次点相册都有明确结果，不会静默失败。
   ============================================================ */
enum AlbumScan {
    /// 相册里的照片分两种方向：UIImage 记在 imageOrientation 里（相机拍的原图、截图转存的），
    /// cgImage 本身是"躺平"的。以前固定按 .up 去识别，竖着拍的图等于转了 90°，当然认不出来。
    /// 这里：先按图片自己的方向识别，再把 4 个方向都试一遍兜底。
    static func decode(_ image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let own = cgOrientation(image.imageOrientation)
        let orders: [CGImagePropertyOrientation] = [own, .up, .right, .down, .left]
        var tried = Set<String>()
        for o in orders {
            let key = "\(o.rawValue)"
            if tried.contains(key) { continue }
            tried.insert(key)
            if let hit = vision(cg, o) { return hit }
        }
        /* 老办法兜底：CIImage(image:) 会带上方向信息 */
        let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                             options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        if let ci = CIImage(image: image),
           let feats = det?.features(in: ci) as? [CIQRCodeFeature],
           let s = feats.compactMap({ $0.messageString }).first(where: { !$0.isEmpty }) {
            return s
        }
        return nil
    }

    private static func vision(_ cg: CGImage, _ o: CGImagePropertyOrientation) -> String? {
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr, .code128, .ean13, .ean8]
        let handler = VNImageRequestHandler(cgImage: cg, orientation: o, options: [:])
        guard (try? handler.perform([req])) != nil else { return nil }
        return (req.results ?? []).compactMap({ $0.payloadStringValue }).first(where: { !$0.isEmpty })
    }

    private static func cgOrientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/* 扫到的内容统一在这里处理：群二维码 → 进群；6 位数字 → 确认别的设备登录；其它 → 原样提示 */
@MainActor
func handleScanned(_ text: String, app: AppState) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    /* 收付款码：付款码（18 位数字 / pay.html?c=）和收款码（pay.html?u=）都在这里拦下来，
       先问服务器「这是谁的码、要收多少钱」，再弹确认付款页 */
    let isPayCode = (t.count == 18 && t.allSatisfy({ $0.isNumber }))
        || (t.contains("pay.html") && (t.contains("?c=") || t.contains("&c=") || t.contains("?u=") || t.contains("&u=")))
    if isPayCode {
        Task { @MainActor in
            do {
                let info = try await API.shared.payResolve(text: t)
                /* 扫一扫是整页盖在最上面的，等它收起来再弹付款页（不然会被盖住） */
                try? await Task.sleep(nanoseconds: 400_000_000)
                app.payScanText = t
                app.payScan = info
            } catch {
                app.show((error as? APIError)?.errorDescription ?? Tr("这不是收付款码"))
            }
        }
        return
    }
    /* 别人的个人二维码：链接里带 u=个人码 → 直接加好友 */
    if let r = t.range(of: "u="), t.contains("add.html") {
        var code = String(t[r.upperBound...])
        if let amp = code.firstIndex(of: "&") { code = String(code[..<amp]) }
        code = code.trimmingCharacters(in: .whitespaces)
        /* 扫到自己的码：微信会提示「这是你自己的二维码」（个人码是「用户名.串」这种格式） */
        let myName = (app.me?.username ?? "").lowercased()
        if !code.isEmpty, !myName.isEmpty, code.lowercased().hasPrefix(myName + ".") {
            app.show(Tr("这是你自己的二维码，发给朋友扫才能加你"))
            return
        }
        if !code.isEmpty {
            Task {
                let res = await API.shared.addByCode(code)
                app.show(res.user == nil ? res.message : (res.message + "：" + (res.user?.name ?? "")))
                if res.message.contains("好友") { await app.loadContacts() }
            }
            return
        }
        app.show(Tr("这个二维码里没有个人信息"))
        return
    }
    /* 有些老版本的二维码里只写了一串个人码（没有链接）：形如 friend001.XyZ123 → 也当加好友 */
    if !t.contains(" "), t.contains("."), t.count >= 6, t.count <= 40,
       t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) {
        Task {
            let res = await API.shared.addByCode(t)
            if res.user != nil {
                app.show(res.message + "：" + (res.user?.name ?? ""))
                if res.message.contains("好友") { await app.loadContacts() }
            } else {
                app.show(Tr("扫到：") + t)
            }
        }
        return
    }
    /* 群二维码：链接里带 c=邀请码 */
    if let r = t.range(of: "c=") {
        var code = String(t[r.upperBound...])
        if let amp = code.firstIndex(of: "&") { code = String(code[..<amp]) }
        code = code.trimmingCharacters(in: .whitespaces)
        if !code.isEmpty {
            Task {
                let res = await API.shared.joinByInvite(code: code)
                if let err = res.error {
                    app.show(err)
                } else {
                    await app.loadChats()
                    app.show(Tr("已加入群聊"))
                    /* 微信那样：扫完群二维码直接进这个群聊（不只是提示一句） */
                    if let cid = res.chatId, !cid.isEmpty {
                        NotificationCenter.default.post(name: .chrisOpenChat, object: nil,
                                                       userInfo: ["chatId": cid])
                    }
                }
            }
            return
        }
        app.show(Tr("这个群二维码里没有邀请码"))
        return
    }
    /* 网页版授权登录出的 6 位数字：扫了就等于确认那台设备登录 */
    if t.count == 6, t.allSatisfy({ $0.isNumber }) {
        Task {
            if let err = await API.shared.pairApprove(code: t) {
                app.show(err)
            } else {
                app.show(Tr("已确认，那台设备登录成功"))
            }
        }
        return
    }
    /* 其它内容：是链接就原样显示，是文字就先当微信号试试加好友 */
    if t.hasPrefix("http") {
        app.show(Tr("扫到链接：") + t)
        return
    }
    if t.count >= 3, t.count <= 24, !t.contains(" ") {
        Task {
            do {
                try await API.shared.addFriend(username: t)
                app.show("已向 \(t) 发送好友请求")
            } catch {
                app.show(Tr("扫到：") + t)
            }
        }
        return
    }
    app.show(Tr("扫到：") + t)
}

/* ============================================================
   扫一扫：相机扫二维码
   · 扫到群二维码链接（join.html?c=邀请码）→ 直接进群
   · 扫到 6 位数字 → 当成「设备确认登录」的码，确认后网页就登上了
   · 其他内容 → 原样提示出来
   ============================================================ */

struct ScannerView: View {
    var onFound: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var torch = false
    @State private var denied = false
    @State private var hint = "把二维码放进框里，自动识别"
    /* 微信扫一扫下面那个「相册」：从相册里挑一张带二维码的图片来识别 */
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if denied {
                VStack(spacing: 12) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.8))
                    Text(Tr("没有相机权限"))
                        .font(pf(17, .medium))
                        .foregroundColor(.white)
                    Text(Tr("到「设置 → Luchat → 相机」里打开权限再回来"))
                        .font(pf(13))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else {
                CameraPreview(torch: $torch) { text in
                    onFound(text)
                    dismiss()
                }
                .ignoresSafeArea()

                ScanFrame()
                    .frame(width: 250, height: 250)

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
                        Text(Tr("扫一扫"))
                            .font(pf(17, .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button { torch.toggle() } label: {
                            Image(systemName: torch ? "bolt.fill" : "bolt.slash")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(torch ? Color.yellow : .white)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color.black.opacity(0.35)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    Spacer()

                    Text(hint)
                        .font(pf(13.5))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.35)))
                    Text(Tr("群二维码扫了直接进群；网页登录出的 6 位数码扫了就是确认登录"))
                        .font(pf(12))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 8)

                    /* 相册：扫相册里的二维码图片（微信扫一扫底部左边那个） */
                    Button { AlbumPicker.present { image in scanAlbum(image) } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 22))
                            Text(busy ? Tr("识别中…") : Tr("相册"))
                                .font(pf(13))
                        }
                        .foregroundColor(.white)
                        .frame(width: 74, height: 66)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                }
            }
        }
        .statusBarHidden(false)
        .onAppear { askPermission() }
    }

    /// 识别相册里的二维码
    /// 以前的写法有两个毛病：① 直接在主线程跑 CIDetector，一张大图能把界面卡住好几秒（看着像「没反应」）；
    /// ② CIDetector 对这种照片里的二维码识别率一般，倾斜/反光/带背景就认不出来。
    /// 现在改成后台线程 + 先用系统的 Vision（识别率高得多），认不到再用 CIDetector 兜一次。
    private func scanAlbum(_ image: UIImage) {
        busy = true
        hint = Tr("正在识别…")
        Task.detached(priority: .userInitiated) {
            let text = AlbumScan.decode(image)
            await MainActor.run {
                busy = false
                if let t = text, !t.isEmpty {
                    hint = ""
                    onFound(t)
                    dismiss()
                } else {
                    hint = Tr("这张图里没找到二维码，换一张清楚点的试试")
                }
            }
        }
    }

    private func askPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            denied = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { denied = !ok }
            }
        default:
            denied = true
        }
    }
}

/// 四个角的取景框
private struct ScanFrame: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, len: CGFloat = 34, lw: CGFloat = 3
            ZStack {
                RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.28), lineWidth: 1)
                corner(w: len, lw: lw).position(x: len / 2, y: len / 2)
                corner(w: len, lw: lw).rotationEffect(.degrees(90)).position(x: w - len / 2, y: len / 2)
                corner(w: len, lw: lw).rotationEffect(.degrees(180)).position(x: w - len / 2, y: h - len / 2)
                corner(w: len, lw: lw).rotationEffect(.degrees(270)).position(x: len / 2, y: h - len / 2)
            }
        }
    }

    private func corner(w: CGFloat, lw: CGFloat) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: w))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: w, y: 0))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        .frame(width: w, height: w)
    }
}

/// 相机预览 + 二维码识别
private struct CameraPreview: UIViewRepresentable {
    @Binding var torch: Bool
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        context.coordinator.start(in: view, torch: torch)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setTorch(torch)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "chris.scanner")
        private var device: AVCaptureDevice?
        private var done = false
        private let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func start(in view: PreviewView, torch: Bool) {
            guard let dev = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: dev) else { return }
            device = dev
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                output.metadataObjectTypes = [.qr, .ean13, .ean8, .code128]
            }
            session.commitConfiguration()
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            queue.async { [session] in if !session.isRunning { session.startRunning() } }
        }

        func stop() {
            queue.async { [session] in if session.isRunning { session.stopRunning() } }
        }

        func setTorch(_ on: Bool) {
            guard let dev = device, dev.hasTorch else { return }
            try? dev.lockForConfiguration()
            dev.torchMode = on ? .on : .off
            dev.unlockForConfiguration()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !done else { return }
            for obj in objects {
                guard let code = obj as? AVMetadataMachineReadableCodeObject,
                      let text = code.stringValue, !text.isEmpty else { continue }
                done = true
                stop()
                onCode(text)
                return
            }
        }
    }
}
