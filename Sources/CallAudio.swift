import Foundation
import AVFoundation
import CoreMedia

/* ============================================================
   语音通话的「服务器转发」通道（兜底方案）
   为什么要有它：有些运营商（比如中国移动 4G）把到 TURN 服务器的通道全挡了，
   手机连一个中继候选都拿不到，WebRTC 就永远接不通。
   这条路走 App 一直在用的那条 WebSocket（wss/443），运营商挡不住：
     · 麦克风 → 16kHz 单声道 PCM → 40 毫秒一帧 → base64 → 长连接发出去
     · 收到对方的帧 → 直接丢给播放器
   服务端只是原样转发（action: 'audio'），1 帧 1280 字节，够小。
   ============================================================ */
final class CallAudioPipe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = CallAudioPipe()

    /// 每帧多少采样（16000Hz × 0.04s = 640）
    private let sampleRate: Double = 16000
    private let frameSamples = 640

    /* 采集用 AVCaptureSession（录视频那套音频管线）：
       它自己管音频会话，不像 AVAudioEngine.inputNode 那样容易被会话状态卡住
       —— 之前「engine 起不来」就是栽在这儿。 */
    private let capture = AVCaptureSession()
    private let audioOut = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "chris.call.capture")

    /* 播放单独一个「只挂播放器」的引擎：不带输入，一定起得来 */
    private let player = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playerReady = false

    private var started = false
    /// 采集有没有真的跑起来（起不来时页面/日志能看到原因）
    var isRunning: Bool { started && capture.isRunning }
    /// 起不来时的原因（上报日志用）
    private(set) var lastError = ""
    private var pending = Data()                 // 攒够一帧再发

    /// 采到一帧就回调（交给长连接发出去）
    var onFrame: ((Data) -> Void)?

    private var playFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
    }

    func start() {
        guard !started else { return }
        started = false
        lastError = ""
        pending.removeAll()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth])
        } catch {
            lastError = "setCategory 失败: \(error.localizedDescription)"
        }
        do { try session.setActive(true, options: []) } catch {
            lastError = (lastError.isEmpty ? "" : lastError + " / ") + "setActive 失败: \(error.localizedDescription)"
        }

        startPlayback()
        startCapture()
    }

    func stop() {
        guard started else { return }
        started = false
        captureQueue.async { [capture] in if capture.isRunning { capture.stopRunning() } }
        playerNode.stop()
        player.stop()
        playerReady = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /* ---------------------------------------------------------- 播放：只挂播放器的引擎 */

    private func startPlayback() {
        guard !playerReady, let fmt = playFormat else { return }
        player.attach(playerNode)
        player.connect(playerNode, to: player.mainMixerNode, format: fmt)
        player.prepare()
        for attempt in 0..<4 {
            do {
                try player.start()
                if player.isRunning {
                    playerNode.play()
                    playerReady = true
                    return
                }
            } catch {
                lastError = (lastError.isEmpty ? "" : lastError + " / ") + "播放引擎: \(error.localizedDescription)"
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.25); try? AVAudioSession.sharedInstance().setActive(true, options: []) }
        }
    }

    /* ---------------------------------------------------------- 采集：AVCaptureSession */

    private func startCapture() {
        capture.beginConfiguration()
        if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
        guard let dev = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: dev),
              capture.canAddInput(input) else {
            capture.commitConfiguration()
            lastError = (lastError.isEmpty ? "" : lastError + " / ") + "拿不到麦克风输入"
            return
        }
        capture.addInput(input)
        audioOut.setSampleBufferDelegate(self, queue: captureQueue)
        if capture.canAddOutput(audioOut) { capture.addOutput(audioOut) }
        capture.commitConfiguration()

        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.capture.startRunning()
            DispatchQueue.main.async {
                self.started = self.capture.isRunning
                if !self.started {
                    self.lastError = (self.lastError.isEmpty ? "" : self.lastError + " / ") + "AVCaptureSession 没能启动"
                }
            }
        }
    }

    /// 采集回调：CMSampleBuffer → 16kHz 单声道 Int16 → 攒够 40ms 发一帧
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        var streamDesc = asbd.pointee
        guard let inFormat = AVAudioFormat(streamDescription: &streamDesc),
              let target = playFormat,
              let converter = AVAudioConverter(from: inFormat, to: target) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                                                          frameCount: Int32(frames),
                                                          into: inBuf.mutableAudioBufferList) == noErr else { return }
        let outCap = AVAudioFrameCount(Double(frames) * target.sampleRate / inFormat.sampleRate + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
        var done = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        pending.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        let frameBytes = frameSamples * 2
        while pending.count >= frameBytes {
            let chunk = pending.prefix(frameBytes)
            pending.removeFirst(frameBytes)
            onFrame?(Data(chunk))
        }
    }

    /// 播放对方传来的一帧（16kHz 单声道 Int16）
    func play(_ data: Data) {
        guard playerReady, let fmt = playFormat else { return }
        let frames = data.count / 2
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        guard let ch = buf.int16ChannelData else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(ch[0], base, frames * 2)
            }
        }
        playerNode.scheduleBuffer(buf, completionHandler: nil)
    }
}
