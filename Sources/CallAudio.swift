import Foundation
import AVFoundation

/* ============================================================
   语音通话的「服务器转发」通道（兜底方案）
   为什么要有它：有些运营商（比如中国移动 4G）把到 TURN 服务器的通道全挡了，
   手机连一个中继候选都拿不到，WebRTC 就永远接不通。
   这条路走 App 一直在用的那条 WebSocket（wss/443），运营商挡不住：
     · 麦克风 → 16kHz 单声道 PCM → 40 毫秒一帧 → base64 → 长连接发出去
     · 收到对方的帧 → 直接丢给播放器
   服务端只是原样转发（action: 'audio'），1 帧 1280 字节，够小。
   ============================================================ */
final class CallAudioPipe {
    static let shared = CallAudioPipe()

    /// 每帧多少采样（16000Hz × 0.04s = 640）
    private let sampleRate: Double = 16000
    private let frameSamples = 640

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false
    /// 采集有没有真的跑起来（起不来时页面/日志能看到原因）
    var isRunning: Bool { started && engine.isRunning }
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
                                    options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        } catch {
            lastError = "setCategory 失败: \(error.localizedDescription)"
        }
        do { try session.setActive(true, options: []) } catch {
            lastError = (lastError.isEmpty ? "" : lastError + " / ") + "setActive 失败: \(error.localizedDescription)"
        }

        let input = engine.inputNode
        var inFormat = input.inputFormat(forBus: 0)
        /* 有时候会话刚激活，输入格式还是 0：等一小会儿再来一次 */
        var tries = 0
        while (inFormat.sampleRate <= 0 || inFormat.channelCount == 0) && tries < 8 {
            Thread.sleep(forTimeInterval: 0.15)
            inFormat = input.inputFormat(forBus: 0)
            tries += 1
        }
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            lastError = (lastError.isEmpty ? "" : lastError + " / ")
                + "输入没就绪 fmt=\(Int(inFormat.sampleRate))/\(inFormat.channelCount)ch"
            return
        }

        engine.attach(player)
        if let f = playFormat { engine.connect(player, to: engine.mainMixerNode, format: f) }

        /* tap 用 nil（让引擎用它自己的原生格式）—— 指定格式时真机上经常直接起不来 */
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.feed(buf, from: buf.format)
        }
        /* 引擎启动：失败或者「起来了但没在跑」都重试（iOS 上很常见，重试几次就好了） */
        var lastStartError: Error? = nil
        for attempt in 0..<4 {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.3)
                try? session.setActive(true, options: [])
            }
            engine.prepare()
            do {
                try engine.start()
                if engine.isRunning { started = true; lastStartError = nil; break }
                lastStartError = NSError(domain: "CallAudio", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "start 了但没运行"])
            }
            catch {
                lastStartError = error
            }
        }
        guard started else {
            lastError = (lastError.isEmpty ? "" : lastError + " / ")
                + "engine 起不来: \((lastStartError as NSError?)?.localizedDescription ?? "未知")"
                + " fmt=\(Int(inFormat.sampleRate))/\(inFormat.channelCount)ch"
            try? input.removeTap(onBus: 0)
            return
        }
        player.play()
    }

    func stop() {
        guard started else { return }
        started = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 把采集到的 buffer 转成 16kHz 单声道 Int16，攒成 40ms 一帧发走
    private func feed(_ buf: AVAudioPCMBuffer, from inFormat: AVAudioFormat) {
        guard let target = playFormat,
              let converter = AVAudioConverter(from: inFormat, to: target) else { return }
        let ratio = target.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
        var done = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return buf
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
        guard started, let fmt = playFormat else { return }
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
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}
