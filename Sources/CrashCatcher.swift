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
    }

    /// 主动上报（不一定崩，也可以记异常）
    static func report(_ kind: String, _ text: String) {
        let stack = Thread.callStackSymbols.joined(separator: "\n")
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
