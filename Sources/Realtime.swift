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
        tick += 1
        ev.tick = tick
        event = ev
    }
}
