import SwiftUI
import Foundation

/* C 回调必须是全局函数（闭包会捕获上下文，编译不过） */
private func chrisExceptionHandler(_ ex: NSException) {
    CrashCatcher.report("NSException", "\(ex.name.rawValue): \(ex.reason ?? "")")
}
private func chrisSignalHandler(_ s: Int32) {
    CrashCatcher.report("Signal", "signal \(s)\n" + Thread.callStackSymbols.joined(separator: "\n"))
    signal(s, SIG_DFL)
}

/* 崩溃上报：App 一旦崩，把原因和调用栈发到服务器（data/client-errors.jsonl），
   这样在电脑上就能看到崩在哪一行，不用把手机连电脑抓日志。 */
enum CrashCatcher {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        NSSetUncaughtExceptionHandler(chrisExceptionHandler)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, chrisSignalHandler)
        }
        /* 上次崩了但没发出去（崩的瞬间网络不通 / 进程被系统直接杀掉）：
          这次一进来就补发一遍，这样电脑这边才看得到崩在哪。 */
        uploadPending()
        /* 启动打点：每次打开 App 记一条。被系统直接杀掉（比如卡死被看门狗干掉）不会留崩溃栈，
           但「这个时间点启动过、之后就没消息了」这条线索能说明问题。 */
        launchBeacon()
    }

    private static func launchBeacon() {
        let payload: [String: Any] = [
            "kind": "launch",
            "text": AppInfo.build,
            "app": String(AppInfo.build.prefix(28))
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: API.shared.base + "/api/clientlog") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    /// 补发上次没送出去的崩溃信息（存成 kind\ntext\n\nstack 这种格式）
    static func uploadPending() {
        let raw = UserDefaults.standard.string(forKey: "chris.lastCrash") ?? ""
        let at = UserDefaults.standard.string(forKey: "chris.lastCrashAt") ?? ""
        guard !raw.isEmpty, !at.isEmpty else { return }
        if (UserDefaults.standard.string(forKey: "chris.lastCrashSent") ?? "") == at { return }
        let parts = raw.components(separatedBy: "\n\n")
        let head = parts.first ?? raw
        let stack = parts.count > 1 ? parts[1] : ""
        let headLines = head.components(separatedBy: "\n")
        let kind = headLines.first ?? "Crash"
        let text = headLines.dropFirst().joined(separator: "\n")
        var payload: [String: Any] = [
            "kind": "补报/" + kind,
            "text": String(text.prefix(3000)),
            "stack": String(stack.prefix(6000)),
            "app": AppInfo.build.prefix(28).description,
            "at": at,
            "late": true
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let url = URL(string: API.shared.base + "/api/clientlog") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 6
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    UserDefaults.standard.set(at, forKey: "chris.lastCrashSent")
                }
            }.resume()
        }
    }

    /// 主动上报（不一定崩，也可以记异常）
    static func report(_ kind: String, _ text: String) {
        let stack = Thread.callStackSymbols.joined(separator: "\n")
        /* 先存在本机上：万一网络不通，下次打开 App 会把这页弹出来，截图发我一样能看 */
        UserDefaults.standard.set("\(kind)\n\(text)\n\n\(stack)".prefix(6000).description,
                                  forKey: "chris.lastCrash")
        UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: "chris.lastCrashAt")
        let payload: [String: Any] = [
            "kind": kind,
            "text": String(text.prefix(4000)),
            "stack": String(stack.prefix(6000)),
            "lang": Lang.code,
            "app": AppInfo.build.prefix(28).description,
            "at": ISO8601DateFormatter().string(from: Date())
        ]
        guard let url = URL(string: API.shared.base + "/api/clientlog"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        /* 崩的时候主线程已经不可靠了，用同步发送，确保能发出去 */
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 3)
    }
}
