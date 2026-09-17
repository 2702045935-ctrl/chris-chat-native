import Foundation
import UIKit

/* ============================================================ 数据模型 */

struct User: Decodable, Identifiable, Hashable {
    var id: String
    var username: String?
    var nickname: String?
    var avatar: String?
    var bio: String?
    var gender: String?
    var region: String?
    var phone: String?
    var status: String?
    var chatBackground: String?
    var momentCover: String?
    var bot: Bool?
    var online: Bool?
    var balance: Double?

    var name: String {
        if let n = nickname, !n.isEmpty { return n }
        if let u = username, !u.isEmpty { return u }
        return "未知用户"
    }
    var avatarPath: String { avatar ?? "" }
}

struct LastMessage: Decodable, Hashable {
    var id: String?
    var senderId: String?
    var senderName: String?
    var kind: String?
    var preview: String?
    var createdAt: String?
}

struct Chat: Decodable, Identifiable, Hashable {
    var id: String
    var type: String?
    var title: String?
    var avatar: String?
    var unread: Int?
    var pinned: Bool?
    var botRank: Int?
    var memberCount: Int?
    var lastMessage: LastMessage?
    var updatedAt: String?

    var name: String { (title?.isEmpty == false) ? title! : "会话" }
    var unreadCount: Int { unread ?? 0 }
}

struct Message: Decodable, Identifiable, Hashable {
    var id: String
    var chatId: String?
    var seq: Int?
    var senderId: String?
    var kind: String?
    var content: String?
    var createdAt: String?
    var recalled: Bool?
    var senderName: String?
    var senderAvatar: String?

    var kindName: String { kind ?? "text" }
    var body: String { content ?? "" }
    var isRecalled: Bool { recalled ?? false }
}

struct MomentLike: Decodable, Hashable {
    var userId: String?
    var nickname: String?
    var at: String?
}

struct MomentComment: Decodable, Hashable {
    var id: String?
    var userId: String?
    var nickname: String?
    var replyToName: String?
    var content: String?
    var at: String?
}

struct Moment: Decodable, Identifiable, Hashable {
    var id: String
    var authorId: String?
    var author: User?
    var content: String?
    var images: [String]?
    var createdAt: String?
    var likes: [MomentLike]?
    var likedByMe: Bool?
    var comments: [MomentComment]?
    var mine: Bool?
}

private struct ChatsPayload: Decodable { var chats: [Chat] }
private struct ChatPayload: Decodable { var chat: Chat? }
private struct MessagesPayload: Decodable {
    var chat: Chat?
    var messages: [Message]
    var hasMore: Bool?
}
private struct MessagePayload: Decodable { var message: Message? }
private struct ContactsPayload: Decodable {
    var friends: [User]
    var incoming: [User]?
    var outgoing: [User]?
}
private struct MePayload: Decodable { var user: User? }
private struct LoginPayload: Decodable { var user: User? }
private struct SessionPayload: Decodable { var authenticated: Bool?; var user: User? }
private struct PhoneCodePayload: Decodable { var sent: Bool?; var devCode: String?; var nickname: String? }
private struct MomentsPayload: Decodable {
    var moments: [Moment]
    var hasMore: Bool?
    var unread: Int?
}
private struct BrandingPayload: Decodable { var branding: BrandInfo? }

struct BrandInfo: Decodable, Hashable {
    var appName: String?
    var logo: String?
}

struct PlusItem: Decodable, Identifiable, Hashable {
    var id: String?
    var label: String?
    var icon: String?
    var action: String?
    var enabled: Bool?
}

struct Gift: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var icon: String?
    var price: Double?
    var category: String?
}

private struct PlusPayload: Decodable { var items: [PlusItem]? }
private struct GiftsPayload: Decodable { var gifts: [Gift]? }
private struct UploadPayload: Decodable {
    var url: String?
    var name: String?
    var bytes: Int?
    var image: Bool?
}

/* ============================================================ 网络 */

enum APIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

/// 局域网服务器用的是自签名证书，这里直接放行
final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class API {
    static let shared = API()

    let session: URLSession
    private let trustDelegate = TrustAllDelegate()

    private(set) var token: String = ""
    private(set) var server: String = "192.168.2.7:5180"

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg, delegate: trustDelegate, delegateQueue: nil)

        if let saved = UserDefaults.standard.string(forKey: "chris.server"), !saved.isEmpty {
            server = saved
        }
        if let saved = UserDefaults.standard.string(forKey: "chris.token") {
            token = saved
        }
    }

    var base: String { "http://\(server)" }

    func setServer(_ value: String) {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        v = v.replacingOccurrences(of: "https://", with: "")
        v = v.replacingOccurrences(of: "http://", with: "")
        if v.hasSuffix("/") { v.removeLast() }
        if !v.contains(":") { v += ":5180" }
        guard !v.isEmpty else { return }
        server = v
        UserDefaults.standard.set(v, forKey: "chris.server")
    }

    func setToken(_ value: String) {
        token = value
        UserDefaults.standard.set(value, forKey: "chris.token")
    }

    func clearToken() {
        token = ""
        UserDefaults.standard.removeObject(forKey: "chris.token")
    }

    /// /uploads/xxx.png、http://…、data:… 都能转成可加载的地址
    func assetURL(_ path: String) -> URL? {
        if path.isEmpty { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        if path.hasPrefix("data:") { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + p)
    }

    /* ---------------------------------------------------------- 底层请求 */

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: base + path) else {
            throw APIError.message("服务器地址不正确")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
        } catch {
            throw APIError.message("连不上服务器（\(server)），检查手机是不是和电脑同一个 Wi-Fi")
        }
        let data = result.0
        let response = result.1

        if let http = response as? HTTPURLResponse, token.isEmpty,
           let raw = http.value(forHTTPHeaderField: "Set-Cookie"),
           let range = raw.range(of: "chris_chat_session=") {
            let rest = raw[range.upperBound...]
            let value = rest.split(separator: ";").first.map(String.init) ?? ""
            if !value.isEmpty { setToken(value) }
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw APIError.message("服务器返回了看不懂的内容")
        }
        guard let dict = obj as? [String: Any] else {
            throw APIError.message("服务器返回了看不懂的内容")
        }
        if (dict["ok"] as? Bool) != true {
            let msg = (dict["error"] as? String) ?? "请求失败"
            throw APIError.message(msg)
        }
        return dict["data"] ?? [String: Any]()
    }

    private func decode<T: Decodable>(_ any: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any, options: [])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.message("数据解析失败")
        }
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let any = try await request("GET", path)
        return try decode(any, as: T.self)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type) async throws -> T {
        let any = try await request("POST", path, body: body)
        return try decode(any, as: T.self)
    }

    /* ---------------------------------------------------------- 业务接口 */

    func branding() async -> BrandInfo? {
        guard let payload: BrandingPayload = try? await get("/api/branding", as: BrandingPayload.self) else { return nil }
        return payload.branding
    }

    func login(username: String, password: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/login",
                                                   ["username": username, "password": password],
                                                   as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("登录失败") }
        return user
    }

    /// 本地没接短信通道，服务器会直接把验证码给回来
    func phoneCode(phone: String) async throws -> String? {
        let payload: PhoneCodePayload = try await post("/api/login/phone-code",
                                                       ["phone": phone],
                                                       as: PhoneCodePayload.self)
        return payload.devCode
    }

    func loginPhone(phone: String, code: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/login/phone",
                                                   ["phone": phone, "code": code],
                                                   as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("登录失败") }
        return user
    }

    func session() async throws -> (ok: Bool, user: User?) {
        let payload: SessionPayload = try await get("/api/session", as: SessionPayload.self)
        return (payload.authenticated ?? false, payload.user)
    }

    func logout() async {
        _ = try? await request("POST", "/api/logout", body: [:])
        clearToken()
    }

    func me() async throws -> User? {
        let payload: MePayload = try await get("/api/me", as: MePayload.self)
        return payload.user
    }

    func chats() async throws -> [Chat] {
        let payload: ChatsPayload = try await get("/api/chats", as: ChatsPayload.self)
        return payload.chats
    }

    func messages(chatId: String, limit: Int = 40, before: Int? = nil) async throws -> (chat: Chat?, messages: [Message], hasMore: Bool) {
        var path = "/api/chats/\(chatId)/messages?limit=\(limit)"
        if let before = before { path += "&before=\(before)" }
        let payload: MessagesPayload = try await get(path, as: MessagesPayload.self)
        return (payload.chat, payload.messages, payload.hasMore ?? false)
    }

    func send(chatId: String, text: String) async throws -> Message? {
        let payload: MessagePayload = try await post("/api/chats/\(chatId)/messages",
                                                     ["kind": "text", "content": text],
                                                     as: MessagePayload.self)
        return payload.message
    }

    func markRead(chatId: String) async {
        _ = try? await request("POST", "/api/chats/\(chatId)/read", body: [:])
    }

    func markUnread(chatId: String) async {
        _ = try? await request("POST", "/api/chats/\(chatId)/unread", body: [:])
    }

    func deleteChat(chatId: String) async {
        // 清空聊天记录 + 从列表里移除（微信的「删除」）
        _ = try? await request("DELETE", "/api/chats/\(chatId)?clear=1")
    }

    func hideChat(chatId: String) async {
        // 不显示该聊天：只从自己的列表里移除，对方不受影响
        _ = try? await request("DELETE", "/api/chats/\(chatId)")
    }

    func openDirect(userId: String) async throws -> Chat? {
        let payload: ChatPayload = try await post("/api/chats/direct", ["userId": userId], as: ChatPayload.self)
        return payload.chat
    }

    func contacts() async throws -> [User] {
        let payload: ContactsPayload = try await get("/api/contacts", as: ContactsPayload.self)
        return payload.friends
    }

    func moments(limit: Int = 20, userId: String? = nil) async throws -> [Moment] {
        var path = "/api/moments?limit=\(limit)"
        if let userId = userId, !userId.isEmpty { path += "&userId=\(userId)" }
        let payload: MomentsPayload = try await get(path, as: MomentsPayload.self)
        return payload.moments
    }

    /* ---------------------------------------------------------- 更多接口 */

    func plusPanel() async throws -> [PlusItem] {
        let payload: PlusPayload = try await get("/api/plus-panel", as: PlusPayload.self)
        return (payload.items ?? []).filter { $0.enabled != false }
    }

    func gifts() async throws -> [Gift] {
        let payload: GiftsPayload = try await get("/api/gifts", as: GiftsPayload.self)
        return payload.gifts ?? []
    }

    /// 图片压完再传：返回服务器上的 /uploads/xxx.jpg
    func upload(image: UIImage) async throws -> String {
        guard let data = image.resizedJPEG(maxSide: 1600, quality: 0.82) else {
            throw APIError.message("图片处理失败")
        }
        let b64 = data.base64EncodedString()
        let payload: UploadPayload = try await post("/api/upload",
                                                    ["dataUrl": "data:image/jpeg;base64," + b64,
                                                     "filename": "photo.jpg"],
                                                    as: UploadPayload.self)
        guard let url = payload.url else { throw APIError.message("上传失败") }
        return url
    }

    func send(chatId: String, kind: String, content: String) async throws -> Message? {
        let payload: MessagePayload = try await post("/api/chats/\(chatId)/messages",
                                                     ["kind": kind, "content": content],
                                                     as: MessagePayload.self)
        return payload.message
    }

    func recall(chatId: String, messageId: String) async {
        _ = try? await request("POST", "/api/messages/\(messageId)/recall", body: ["chatId": chatId])
    }

    func likeMoment(id: String) async {
        _ = try? await request("POST", "/api/moments/\(id)/like", body: [:])
    }

    func commentMoment(id: String, text: String) async {
        _ = try? await request("POST", "/api/moments/\(id)/comments", body: ["content": text])
    }

    func deleteMoment(id: String) async {
        _ = try? await request("DELETE", "/api/moments/\(id)")
    }

    func postMoment(content: String, images: [String]) async throws {
        _ = try await request("POST", "/api/moments", body: ["content": content, "images": images])
    }

    func updateMe(_ fields: [String: Any]) async {
        _ = try? await request("PATCH", "/api/me", body: fields)
    }

    func addFriend(username: String) async throws {
        _ = try await request("POST", "/api/friends/request", body: ["username": username])
    }

    func rawUpload(_ body: [String: Any]) async throws -> (url: String, name: String, bytes: Int) {
        let payload: UploadPayload = try await post("/api/upload", body, as: UploadPayload.self)
        guard let url = payload.url else { throw APIError.message("上传失败") }
        return (url, payload.name ?? "", payload.bytes ?? 0)
    }

    func transfer(chatId: String, amount: Double, note: String,
                  method: String, password: String) async throws {
        _ = try await request("POST", "/api/pay/transfer", body: [
            "chatId": chatId,
            "amount": amount,
            "note": note,
            "method": method,
            "password": password
        ])
    }
}

extension UIImage {
    /// 上传前压一下：长边最多 maxSide，JPEG 质量 quality
    func resizedJPEG(maxSide: CGFloat, quality: CGFloat) -> Data? {
        let long = max(size.width, size.height)
        var target = size
        if long > maxSide {
            let k = maxSide / long
            target = CGSize(width: size.width * k, height: size.height * k)
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let out = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return out.jpegData(compressionQuality: quality)
    }
}
