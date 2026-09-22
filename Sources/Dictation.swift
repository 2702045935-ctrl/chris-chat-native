import SwiftUI
import Speech
import AVFoundation

/// 聊天输入框里那个小喇叭：**语音转文字**（和微信一样）
/// 点一下开始听，边说文字边出现在输入框里；停口 1.4 秒自动收工，也可以再点一下停。
@MainActor
final class Dictation: NSObject, ObservableObject {
    @Published var listening = false
    @Published var text = ""
    @Published var error = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?
    private var silence: Timer?
    private var started = false

    /// 点一下开 / 点一下关
    func toggle(_ onText: @escaping (String) -> Void) {
        if listening || started { stop() } else { start(onText) }
    }

    func start(_ onText: @escaping (String) -> Void) {
        self.onText = onText
        text = ""
        error = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard st == .authorized else {
                    self.error = "没给语音识别权限：设置 → 隐私 → 语音识别 里打开"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.error = "没给麦克风权限：设置 → 隐私 → 麦克风 里打开"
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try? session.setActive(true, options: [])

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch {
            error = "麦克风打不开，等一下再试"
            return
        }
        listening = true
        started = true
        bumpSilence()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let result = result {
                    let s = result.bestTranscription.formattedString
                    self.text = s
                    self.onText?(s)
                    self.bumpSilence()
                    if result.isFinal { self.stop() }
                }
                if err != nil, self.listening { self.stop() }
            }
        }
    }

    /// 停口一会儿就自己收工（微信也是这样：说完就出字）
    private func bumpSilence() {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { _ in
            Task { @MainActor in self.stop() }
        }
    }

    func stop() {
        silence?.invalidate()
        silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
