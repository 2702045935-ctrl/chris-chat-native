import Foundation
import SwiftUI

/// 服务器推送过来的一件事（收到新消息、转账、朋友圈、余额变动…）
struct PushEvent: Equatable {
    var type = ""
    var chatId = ""
    var fromId = ""
    var balance: Double? = nil
    var announce = ""
    var user: User? = nil
    /// 朋友圈有没有新的（服务器在 ready 里给；有就给「发现」挂红点）
    var momentUnread: Int? = nil
    var tick = 0
}

/// 和服务器保持一条长连接（WebSocket）：别人一发消息，这边立刻就能收到，
/// 不用轮询。断了会自动重连。
@MainActor
final class Realtime: ObservableObject {
    static let shared = Realtime()

    @Published private(set) var event = PushEvent()
    @Published private(set) var connected = false

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var tick = 0
    /// 推送洪水的节流：消息一秒钟来几千条时，不能每条都去通知界面（会把手机刷死）。
    /// 这里最多每 0.25 秒往界面发一次，攒着的那条在稍后合并发出去。
    private var pending: PushEvent?
    private var publishTask: Task<Void, Never>?

    func start() {
        stop()
        guard !API.shared.token.isEmpty,
              let url = URL(string: "ws://\(API.shared.server)/?token=\(API.shared.token)") else { return }
        let task = API.shared.session.webSocketTask(with: url)
        socket = task
        task.resume()
        loop = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    var text = ""
                    switch message {
                    case .string(let t): text = t
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: break
                    }
                    if !text.isEmpty { self.handle(text) }
                } catch {
                    // 断了：3 秒后重连
                    self.connected = false
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { break }
                    self.start()
                    return
                }
            }
        }
        connected = true
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var ev = PushEvent()
        ev.type = (obj["type"] as? String) ?? ""
        ev.chatId = (obj["chatId"] as? String) ?? ""
        if let m = obj["message"] as? [String: Any] { ev.fromId = (m["senderId"] as? String) ?? "" }
        if let b = obj["balance"] as? Double { ev.balance = b }
        else if let b = obj["balance"] as? Int { ev.balance = Double(b) }
        // 资料变动（换封面 / 换头像 / 改昵称 / 改状态）：服务器推的是 profile
        if let u = obj["user"] as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: u),
           let decoded = try? JSONDecoder().decode(User.self, from: d) {
            ev.user = decoded
        }
        ev.announce = (obj["text"] as? String) ?? ""
        if let n = obj["momentUnread"] as? Int { ev.momentUnread = n }
        /* 推送洪水节流：每条都通知界面的话，几千条一来手机就卡死/崩。
           有任务在跑就先攒着，最多每 0.25 秒发一次（最后那条一定会发出去）。 */
        if publishTask == nil {
            tick += 1
            ev.tick = tick
            event = ev
            publishTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self = self, !Task.isCancelled else { return }
                self.publishTask = nil
                if let p = self.pending {
                    self.pending = nil
                    self.tick += 1
                    var merged = p
                    merged.tick = self.tick
                    self.event = merged
                }
            }
        } else {
            pending = ev
        }
    }
}
