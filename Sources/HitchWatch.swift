import Foundation

/* ============================================================
   卡顿打点：主线程一卡，定时器就会迟到 —— 用「实际间隔 - 预期间隔」量出卡了多久。
   攒够几条（或单次超过 0.5 秒）就上报服务器，日志里能看到「哪一屏、几次、最长多久」。
   这样定位性能问题是看数据，不是猜。
   ============================================================ */

final class HitchWatch {
    static let shared = HitchWatch()

    private var page = ""
    private var timer: Timer?
    private var interval: TimeInterval = 0.5
    private var last = Date()
    private var count = 0
    private var worst: TimeInterval = 0
    private var reportedAt = Date.distantPast

    private init() { }

    func start(_ p: String) {
        page = p
        guard timer == nil else { return }
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(last) - interval
        last = now
        if gap > 0.15 {                      // 主线程被占了 150ms 以上才算一次卡
            count += 1
            worst = max(worst, gap)
        }
        /* 攒够 3 次、或者单次超过 0.5 秒，就报一次（上报本身也限流，最多 30 秒一次） */
        let shouldReport = (count >= 3 || worst > 0.5) && now.timeIntervalSince(reportedAt) > 30
        guard shouldReport else { return }
        let msg = "卡顿 \(page)：\(count) 次，最长 \(Int(worst * 1000))ms"
        count = 0
        worst = 0
        reportedAt = now
        Task { await API.shared.callDiag(msg) }      // 复用现成的诊断上报通道
    }
}
