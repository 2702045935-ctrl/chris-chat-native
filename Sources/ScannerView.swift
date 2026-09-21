import SwiftUI
import AVFoundation

/* 扫到的内容统一在这里处理：群二维码 → 进群；6 位数字 → 确认别的设备登录；其它 → 原样提示 */
@MainActor
func handleScanned(_ text: String, app: AppState) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    /* 群二维码：链接里带 c=邀请码 */
    if let r = t.range(of: "c=") {
        var code = String(t[r.upperBound...])
        if let amp = code.firstIndex(of: "&") { code = String(code[..<amp]) }
        code = code.trimmingCharacters(in: .whitespaces)
        if !code.isEmpty {
            Task {
                if let err = await API.shared.joinByInvite(code: code) {
                    app.show(err)
                } else {
                    await app.loadChats()
                    app.show(L("已加入群聊"))
                }
            }
            return
        }
    }
    /* 网页版授权登录出的 6 位数字：扫了就等于确认那台设备登录 */
    if t.count == 6, t.allSatisfy({ $0.isNumber }) {
        Task {
            if let err = await API.shared.pairApprove(code: t) {
                app.show(err)
            } else {
                app.show(L("已确认，那台设备登录成功"))
            }
        }
        return
    }
    /* 其它内容：是链接就原样显示，是文字就先当微信号试试加好友 */
    if t.hasPrefix("http") {
        app.show(L("扫到链接：") + t)
        return
    }
    if t.count >= 3, t.count <= 24, !t.contains(" ") {
        Task {
            do {
                try await API.shared.addFriend(username: t)
                app.show("已向 \(t) 发送好友请求")
            } catch {
                app.show(L("扫到：") + t)
            }
        }
        return
    }
    app.show(L("扫到：") + t)
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if denied {
                VStack(spacing: 12) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.8))
                    Text(L("没有相机权限"))
                        .font(pf(17, .medium))
                        .foregroundColor(.white)
                    Text(L("到「设置 → Luchat → 相机」里打开权限再回来"))
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
                        Text(L("扫一扫"))
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
                    Text(L("群二维码扫了直接进群；网页登录出的 6 位数码扫了就是确认登录"))
                        .font(pf(12))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                }
            }
        }
        .statusBarHidden(false)
        .onAppear { askPermission() }
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
