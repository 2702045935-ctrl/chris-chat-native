import Foundation
import AVFoundation
import Combine

/* ============================================================
   铃声：来电铃声 + 回铃音（「嘟——」那种）

   不用打包音频文件，直接用 AVAudioEngine 现场合成正弦波音符，
   所以是**真的会响**，而且想加铃声只要加一行音阶。
   铃声在「我 → 个人信息 → 来电铃声」里能换、能试听。
   ============================================================ */

@MainActor
final class Ringtone: ObservableObject {
    static let shared = Ringtone()

    enum Kind { case none, incoming, ringback }

    struct Tone: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// 可选铃声（id 存在本机，来电时用）
    static let all: [Tone] = [
        Tone(id: "wechat", name: "默认"),
        Tone(id: "marimba", name: "马林巴"),
        Tone(id: "chime", name: "清脆"),
        Tone(id: "bubble", name: "气泡"),
        Tone(id: "pulse", name: "脉冲"),
        Tone(id: "classic", name: "经典电话"),
        Tone(id: "quiet", name: "轻柔")
    ]

    @Published private(set) var kind: Kind = .none
    @Published private(set) var previewing = ""
    @Published var current: String

    /// 当前铃声的名字（设置页那行显示用）
    var currentName: String {
        Ringtone.all.first(where: { $0.id == current })?.name ?? "默认"
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rate: Double = 44100
    private var previewTask: Task<Void, Never>?

    private init() {
        current = UserDefaults.standard.string(forKey: "chris.ringtone") ?? "wechat"
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
    }

    /* ---------------------------------------------------------- 对外 */

    /// 来电铃声响起来（重复播放，直到停）
    func startIncoming() { play(kind: .incoming) }
    /// 呼出时的回铃音（嘟——嘟——）
    func startRingback() { play(kind: .ringback) }

    func stop() {
        previewTask?.cancel()
        previewTask = nil
        previewing = ""
        kind = .none
        player.stop()
        deactivate()
    }

    /// 设置页试听：放 4 秒自己停
    func preview(_ id: String) {
        stop()
        previewing = id
        activate()
        guard let buf = makeBuffer(melody(id)) else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        if !engine.isRunning { try? engine.start() }
        player.play()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            if self.kind == .none { self.stop() }
        }
    }

    /* ---------------------------------------------------------- 内部 */

    private func play(kind: Kind) {
        self.kind = kind
        previewTask?.cancel()
        previewing = ""
        activate()
        guard let buf = makeBuffer(kind == .ringback ? Ringtone.ringback : melody(current)) else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    /// 通话铃声要能听见（静音键也响），所以用 playAndRecord + 外放
    private func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? s.setActive(true)
    }

    private func deactivate() {
        if engine.isRunning { engine.pause() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private struct Note {
        let freq: Double
        let dur: Double
    }

    /// 回铃音：响 1 秒、停 3 秒（就是打电话时听到的那个节奏）
    private static let ringback: [Note] = [Note(freq: 440, dur: 1.0), Note(freq: 0, dur: 3.0)]

    /// 每种铃声就是一段音阶
    private func melody(_ id: String) -> [Note] {
        switch id {
        case "marimba":
            return [.init(freq: 523, dur: 0.16), .init(freq: 659, dur: 0.16), .init(freq: 784, dur: 0.16),
                    .init(freq: 1046, dur: 0.30), .init(freq: 0, dur: 0.12),
                    .init(freq: 784, dur: 0.16), .init(freq: 1046, dur: 0.42), .init(freq: 0, dur: 0.5)]
        case "chime":
            return [.init(freq: 988, dur: 0.14), .init(freq: 1319, dur: 0.14), .init(freq: 1568, dur: 0.34),
                    .init(freq: 0, dur: 0.6)]
        case "bubble":
            return [.init(freq: 880, dur: 0.09), .init(freq: 0, dur: 0.05),
                    .init(freq: 1175, dur: 0.09), .init(freq: 0, dur: 0.05),
                    .init(freq: 880, dur: 0.09), .init(freq: 0, dur: 0.5)]
        case "pulse":
            return [.init(freq: 660, dur: 0.22), .init(freq: 0, dur: 0.10),
                    .init(freq: 660, dur: 0.22), .init(freq: 0, dur: 0.8)]
        case "classic":
            return [.init(freq: 440, dur: 0.4), .init(freq: 480, dur: 0.4), .init(freq: 0, dur: 1.4)]
        case "quiet":
            return [.init(freq: 587, dur: 0.5), .init(freq: 0, dur: 0.3), .init(freq: 494, dur: 0.6), .init(freq: 0, dur: 1.4)]
        default:   // 微信
            return [.init(freq: 659, dur: 0.16), .init(freq: 784, dur: 0.16), .init(freq: 988, dur: 0.16),
                    .init(freq: 1319, dur: 0.34), .init(freq: 0, dur: 0.18),
                    .init(freq: 988, dur: 0.16), .init(freq: 1175, dur: 0.16),
                    .init(freq: 1319, dur: 0.42), .init(freq: 0, dur: 0.6)]
        }
    }

    private func makeBuffer(_ notes: [Note]) -> AVAudioPCMBuffer? {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let total = notes.reduce(0.0) { $0 + $1.dur }
        let frames = AVAudioFrameCount(max(1, total * rate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              let ptr = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        var i = 0
        for n in notes {
            let count = Int(n.dur * rate)
            for k in 0..<count where i < Int(frames) {
                let t = Double(k) / rate
                var v = 0.0
                if n.freq > 0 {
                    // 正弦 + 一点二次谐波，前后淡入淡出，听起来像铃声而不是"滴"声
                    let env = min(1, min(t / 0.012, max(0, (n.dur - t) / 0.06)))
                    v = (sin(2 * .pi * n.freq * t) * 0.62 + sin(4 * .pi * n.freq * t) * 0.2) * env
                }
                ptr[i] = Float(v * 0.55)
                i += 1
            }
        }
        return buf
    }
}
