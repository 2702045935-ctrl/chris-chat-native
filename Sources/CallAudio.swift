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
    /// 引擎的节点只 attach/connect 一次（重复 attach 会抛异常）
    private var wired = false
    /// 播放相关的操作都在这条串行队列上做（自愈重启可能 sleep 一下，不能堵主线程）
    private let playQueue = DispatchQueue(label: "chris.call.play")
    /// 播放端看门狗：引擎被系统/别的 App 掐停之后 2 秒内拉回来
    private var watchdog: DispatchSourceTimer?

    /* 播放端统计（诊断用）：「两边都在发帧、却听不到声音」这种问题，
       以前日志里只有「采集=ok」，根本看不出是哪一头不响。 */
    private(set) var framesIn = 0            // 服务器转过来的帧
    private(set) var framesScheduled = 0     // 真的排进播放器的帧
    private(set) var framesDropped = 0       // 播放器没起来时丢掉的帧

    /* 抖动/延迟守卫：pendingFrames = 还没排进播放器的帧；
       queuedUntil = 播放器里已经排到的时间点（40ms 一帧，纯时间推算，不靠 completion 回调 ——
       回调漏一次就会算错，上一版就是被这个拖成"排播比收到少一大截"，声音一顿一顿）。 */
    private var pendingFrames: [Data] = []
    private var queuedUntil = Date.distantPast
    /// 这一通里排得最长的一次延迟（>1.5 秒就会被丢帧压回来），上报出来看得见
    private var latencyPeak = 0.0

    /// 通话结束时上报给服务器，写进 call-trace.log
    var playDiag: String {
        "播放端 收到=\(framesIn) 排播=\(framesScheduled) 丢=\(framesDropped)"
            + " 延迟峰值=\(String(format: "%.1f", latencyPeak))s"
            + " 引擎=\(player.isRunning ? "跑" : "停")"
            + " 播放器=\(playerReady ? (playerNode.isPlaying ? "跑" : "停") : "没起")"
    }

    private var started = false
    /// 抢麦克风的重试任务（上一通刚结束、TRTC/铃声还占着的时候要靠它抢回来）
    private var startTask: Task<Void, Never>?
    /// 已经交给 TRTC 了：本通道彻底闭嘴 —— 连「重试抢麦」都不许再跑。
    /// 少了这个标志，切给腾讯之后这边还在抢麦克风，腾讯开了麦却采不到音，
    /// 表现就是「切到 TRTC 了、两边反而都没声音」（线上真出过）。
    private var handedOver = false
    /// 采集有没有真的跑起来（起不来时页面/日志能看到原因）
    var isRunning: Bool { started && capture.isRunning }
    /// 起不来时的原因（上报日志用）
    private(set) var lastError = ""
    private var pending = Data()                 // 攒够一帧再发

    /// 采到一帧就回调（交给长连接发出去）
    var onFrame: ((Data) -> Void)?
    /// 采集**真正**起来（或彻底失败）之后回调一次：
    /// 以前是 start() 一返回就去看 isRunning，那时候异步的 startRunning 还没跑完，
    /// 日志里就会写「采集=失败 原因:（空）」这种误报。
    var onStateChange: ((Bool) -> Void)?

    private var playFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
    }

    func start() {
        if handedOver { return }        // 麦克风已经交给 TRTC，别再去抢
        if started { return }
        startTask?.cancel()
        started = false
        lastError = ""
        pending.removeAll()
        framesIn = 0
        framesScheduled = 0
        framesDropped = 0
        queuedUntil = Date.distantPast
        latencyPeak = 0
        pendingFrames.removeAll()
        startWatchdog()

        /* 麦克风经常被「上一通电话 / TRTC 进房 / 铃声引擎」占着，一次抢不到就报错的话，
           整通电话对面就听不到你说话（假通）。这里改成最多抢 6 次、每次间隔 0.7 秒，
           中间把音频会话放开再抢。 */
        startTask = Task.detached { [weak self] in
            guard let self = self else { return }
            for attempt in 0..<6 {
                if Task.isCancelled || self.started || self.handedOver { return }
                self.configureSession()
                self.startPlayback()
                if self.startCaptureBlocking() {
                    self.started = true
                    self.lastError = ""
                    /* 抢麦中间可能把音频会话关过（setActive(false)）——
                       系统会顺手把播放引擎掐停，而以前播放端只建一次，
                       引擎一死整通电话就一个字都听不见（服务器那边看帧数还正常）。
                       这里每次抢到麦克风后再确认一次播放端是活的。 */
                    self.startPlayback()
                    DispatchQueue.main.async { self.onStateChange?(true) }
                    return
                }
                /* 没抢到：放开音频会话，等一下再抢 */
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
            }
            self.started = false
            DispatchQueue.main.async { self.onStateChange?(false) }
        }
    }

    func stop() {
        started = false
        startTask?.cancel()
        startTask = nil
        watchdog?.cancel()
        watchdog = nil
        captureQueue.async { [capture] in if capture.isRunning { capture.stopRunning() } }
        playQueue.sync {
            playerNode.stop()
            player.stop()
            playerReady = false
            queuedUntil = Date.distantPast
            pendingFrames.removeAll()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 把麦克风交给 TRTC：先停采集，并禁止后续任何重试抢麦
    func handOverToTRTC() {
        handedOver = true
        onFrame = nil
        stop()
    }

    /// 新的一通电话：复位「已交出」状态，让本通道可以再用
    func resetHandOver() { handedOver = false }

    /* ---------------------------------------------------------- 播放：只挂播放器的引擎 */

    /// 看门狗：通话期间每 2 秒看一眼播放引擎，停了就拉起来
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: playQueue)
        t.schedule(deadline: .now() + 1.5, repeating: 2.0)
        t.setEventHandler { [weak self] in
            guard let self = self, self.started, !self.handedOver else { return }
            self.startPlaybackOnQueue()
        }
        watchdog = t
        t.resume()
    }

    /// 从任意线程调用：把播放引擎搭好 / 拉起来（幂等）
    private func startPlayback() {
        playQueue.sync { startPlaybackOnQueue() }
    }

    private func startPlaybackOnQueue() {
        guard let fmt = playFormat else { return }
        if !wired {
            player.attach(playerNode)
            player.connect(playerNode, to: player.mainMixerNode, format: fmt)
            wired = true
        }
        /* 已经在跑就别折腾（这个函数会被看门狗、每帧播放反复调到） */
        if playerReady, player.isRunning, playerNode.isPlaying { return }
        _ = try? AVAudioSession.sharedInstance().setActive(true, options: [])
        player.prepare()
        for attempt in 0..<4 {
            if playerReady, player.isRunning, playerNode.isPlaying { return }
            do {
                if !player.isRunning { try player.start() }
                playerNode.play()
                if player.isRunning {
                    playerReady = true
                    return
                }
            } catch {
                lastError = (lastError.isEmpty ? "" : lastError + " / ") + "播放引擎: \(error.localizedDescription)"
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.25) }
        }
        /* 4 次都没起来：明说「播放端没起来」，别让日志继续只报「采集=ok」 */
        playerReady = false
        if !lastError.contains("播放引擎没起来") {
            lastError = (lastError.isEmpty ? "" : lastError + " / ") + "播放引擎没起来"
        }
    }

    /* ---------------------------------------------------------- 采集：AVCaptureSession */

    /// 配音频会话：每一轮抢麦之前都重新配一遍（上一通电话可能把它改过）
    private func configureSession() {
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
    }

    /// 配好采集并启动；这一轮没起来就返回 false（调用方会放开会话、过一会儿重试）
    private func startCaptureBlocking() -> Bool {
        if capture.isRunning { return true }
        capture.beginConfiguration()
        if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
        if capture.inputs.isEmpty {
            guard let dev = AVCaptureDevice.default(for: .audio) else {
                capture.commitConfiguration()
                lastError = "找不到麦克风设备"
                return false
            }
            guard let input = try? AVCaptureDeviceInput(device: dev), capture.canAddInput(input) else {
                capture.commitConfiguration()
                /* 权限状态写清楚：日志里一眼能看出是「没授权」还是「被别人占着」 */
                let st = AVCaptureDevice.authorizationStatus(for: .audio)
                lastError = st == .denied ? "麦克风权限被拒绝（去 设置→本 App→麦克风 打开）"
                    : (st == .notDetermined ? "麦克风权限还没授予（弹窗还没点）"
                       : "拿不到麦克风输入（可能被上一通/别的引擎占着）")
                return false
            }
            capture.addInput(input)
        }
        if capture.outputs.isEmpty {
            if capture.canAddOutput(audioOut) { capture.addOutput(audioOut) }
            audioOut.setSampleBufferDelegate(self, queue: captureQueue)
        }
        capture.commitConfiguration()
        var ok = false
        /* 用信号量 + 超时，而不是 captureQueue.sync：万一 startRunning 卡住，
           也只会让这一轮失败（下一轮重试），不会把线程挂死（挂死会被系统判成闪退）。 */
        let wait = DispatchSemaphore(value: 0)
        captureQueue.async { [capture] in
            if !capture.isRunning { capture.startRunning() }
            ok = capture.isRunning
            wait.signal()
        }
        _ = wait.wait(timeout: .now() + 4)
        if !ok { lastError = "AVCaptureSession 没能启动" }
        return ok
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
        guard !data.isEmpty else { return }
        framesIn += 1
        playQueue.async { [weak self] in self?.playOnQueue(data) }
    }

    private func playOnQueue(_ data: Data) {
        /* 引擎要是被掐停了（来电、别的 App 抢会话、我们自己抢麦时关过会话），
           这里先把它拉起来再排帧 —— 以前 playerReady 只要还是 true 就直接
           往一个已经停掉的引擎里 schedule，帧全被吞掉，表现就是「通话中但没声音」。 */
        if !(playerReady && player.isRunning && playerNode.isPlaying) { startPlaybackOnQueue() }
        guard playerReady, player.isRunning, let fmt = playFormat else {
            framesDropped += 1
            return
        }
        pendingFrames.append(data)
        drainPending(fmt)
    }

    /// 把待播的帧排进播放器：**排多少播多少**（中间不会断），
    /// 再用「排到什么时候」这个时间推算兜住延迟 —— 排得超过 1.5 秒就丢最老的压回 ~0.35 秒。
    /// 上一版是"只保留 3 帧"，结果播放端被拖慢（日志里 收到=286 排播=200），听着就是一顿一顿。
    private func drainPending(_ fmt: AVAudioFormat) {
        var until = max(Date(), queuedUntil)
        let queued = until.timeIntervalSinceNow
        if queued > 1.5, pendingFrames.count > 4 {
            var remain = queued
            while pendingFrames.count > 4, remain > 0.35 {
                pendingFrames.removeFirst()
                remain -= 0.04
                framesDropped += 1
            }
            until = Date().addingTimeInterval(max(0.04, remain))
        }
        while !pendingFrames.isEmpty {
            let d = pendingFrames.removeFirst()
            let frames = d.count / 2
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else {
                framesDropped += 1
                continue
            }
            buf.frameLength = AVAudioFrameCount(frames)
            guard let ch = buf.int16ChannelData else {
                framesDropped += 1
                continue
            }
            d.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(ch[0], base, frames * 2)
                }
            }
            playerNode.scheduleBuffer(buf, completionHandler: nil)
            framesScheduled += 1
            until = until.addingTimeInterval(0.04)
        }
        queuedUntil = until
        let now = queuedUntil.timeIntervalSinceNow
        if now > latencyPeak { latencyPeak = now }
    }

}
