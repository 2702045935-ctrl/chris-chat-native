import Foundation
import AVFoundation
import Combine
import UIKit

/* ============================================================
   按住说话（语音消息）
     · 按住麦克风开始录音（m4a / AAC，16k 单声道，够清楚又不占流量）
     · 手指上滑 60pt 取消；松手发送
     · 录完上传到服务器的 /uploads，再发一条 kind=audio 的消息
   点一下语音气泡就能播放（VoicePlayer）。
   ============================================================ */

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    static let shared = VoiceRecorder()

    @Published private(set) var recording = false
    @Published private(set) var seconds = 0
    @Published private(set) var level: CGFloat = 0        // 0…1，界面画音量
    @Published private(set) var willCancel = false

    private var rec: AVAudioRecorder?
    private var ticker: Timer?
    private var fileURL: URL?
    private var startedAt = Date()

    private override init() { super.init() }

    /// 按住：开始录（会先要麦克风权限）
    func begin() async -> Bool {
        guard !recording else { return true }
        guard await Permission.ask(.audio) else { return false }

        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default,
                           options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        r.isMeteringEnabled = true
        r.record()
        rec = r
        fileURL = url
        startedAt = Date()
        seconds = 0
        level = 0
        willCancel = false
        recording = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.tick() }
        }
        return true
    }

    private func tick() {
        guard let r = rec else { return }
        seconds = Int(Date().timeIntervalSince(startedAt))
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)          // -160…0
        level = CGFloat(max(0.04, min(1, (db + 55) / 55)))
    }

    /// 手指上滑就准备取消
    func drag(_ dy: CGFloat) { willCancel = dy < -60 }

    /// 松手：返回要发的文件；取消 / 时间太短返回 nil
    func end() -> (url: URL, seconds: Int)? {
        guard let r = rec, let url = fileURL else {
            recording = false
            return nil
        }
        let secs = Int(Date().timeIntervalSince(startedAt).rounded())
        let cancelled = willCancel || secs < 1
        r.stop()
        rec = nil
        ticker?.invalidate()
        ticker = nil
        recording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (url, max(1, secs))
    }

    func cancel() {
        willCancel = true
        _ = end()
    }
}

/* ---------------------------------------------------------- 播放 */

@MainActor
final class VoicePlayer: NSObject, ObservableObject {
    static let shared = VoicePlayer()

    /// 正在播哪条（消息 id），界面拿它显示播放状态
    @Published private(set) var playingID = ""
    private var player: AVAudioPlayer?
    /// 已经下载过的那几条语音（免得每点一次都重新下）
    private var cache: [String: Data] = [:]

    private override init() { super.init() }

    func toggle(id: String, url: URL) {
        if playingID == id { stop(); return }
        stop()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
        playingID = id
        /* 语音文件在服务器上（/uploads/xxx.m4a）：
           以前这里直接 AVAudioPlayer(contentsOf: 网络地址) —— 它只认本地文件，
           所以点了一点声音都没有。现在先带登录令牌把文件下下来，再用 data 播。 */
        let key = url.absoluteString
        if let hit = cache[key], let p = try? AVAudioPlayer(data: hit) {
            p.delegate = self
            p.prepareToPlay()
            p.play()
            player = p
            return
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let data = try await API.shared.assetData(url)
                guard !data.isEmpty else { self.playingID = ""; return }
                self.cache[key] = data
                if self.cache.count > 24 { self.cache.removeValue(forKey: self.cache.keys.first ?? "") }
                /* 下载期间用户可能已经点了别的/点了停 */
                guard self.playingID == id else { return }
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.prepareToPlay()
                p.play()
                self.player = p
            } catch {
                self.playingID = ""
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension VoicePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
