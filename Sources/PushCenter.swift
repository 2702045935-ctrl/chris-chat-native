import SwiftUI
import UIKit
import UserNotifications

/* ============================================================
   推送通知（苹果 APNs）
   1. 登录以后要通知权限（和微信一样，不是一打开就要）
   2. 拿苹果给的 device token，交给服务器（POST /api/push/register）
   3. 手机在后台 / 被杀掉时，服务器用 APNs 把消息弹出来
      （手机连着实时通道时不推，交给长连接，避免弹两遍）
   4. 点通知 → 直接进那个人的聊天
   ============================================================ */
final class PushCenter: NSObject, ObservableObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = PushCenter()

    /// 苹果给这台设备的 token（十六进制字符串）
    @Published private(set) var token = ""
    /// 用户有没有同意通知
    @Published private(set) var authorized = false
    /// 拿 token 失败时的原因（「我 → 设置 → 关于」里能看到）
    @Published private(set) var lastError = "登记时间"
    @Published private(set) var registeredAt = ""

    override init() { super.init() }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// 登录后调用：要权限 + 向苹果注册
    func start() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
                      || s.authorizationStatus == .ephemeral)
            DispatchQueue.main.async { self.authorized = ok }
            /* 把「这台手机到底允不允许通知 / 允不允许标记」报给服务器：
               桌面图标没有数字时，后台一看就知道是权限问题还是没配密钥 */
            self.report(s)
            if s.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    DispatchQueue.main.async { self.authorized = granted }
                    if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
                    UNUserNotificationCenter.current().getNotificationSettings { s2 in self.report(s2) }
                }
            } else if ok {
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }

    private func report(_ s: UNNotificationSettings) {
        var status = "unknown"
        switch s.authorizationStatus {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .provisional: status = "provisional"
        case .ephemeral: status = "ephemeral"
        case .notDetermined: status = "not-determined"
        @unknown default: status = "unknown"
        }
        let badgeOn = (s.badgeSetting != .disabled)
        let alertOn = (s.alertSetting != .disabled)
        let soundOn = (s.soundSetting != .disabled)
        Task {
            await API.shared.reportPushSettings(status: status, badge: badgeOn,
                                                alert: alertOn, sound: soundOn,
                                                token: token, sandbox: PushCenter.isSandbox)
        }
    }

    /// 把 token 报给服务器；没登录就先记着，登录后再报
    func uploadIfPossible() {
        guard !token.isEmpty else { return }
        Task {
            await API.shared.registerPushToken(token, sandbox: PushCenter.isSandbox)
            await MainActor.run {
                let f = DateFormatter()
                f.dateFormat = "MM-dd HH:mm"
                self.registeredAt = f.string(from: Date())
            }
        }
    }

    /// 苹果的测试环境（Xcode 直接装到手机上）用 sandbox；
    /// TestFlight / App Store 下载的包要用正式环境 —— 用错会被苹果回 BadDeviceToken
    static var isSandbox: Bool {
        #if DEBUG
        return true
        #else
        let receipt = Bundle.main.appStoreReceiptURL?.lastPathComponent ?? ""
        return receipt.contains("sandboxReceipt")
        #endif
    }

    /* ---------------- 苹果回调 ---------------- */

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        DispatchQueue.main.async {
            self.token = hex
            self.lastError = ""
        }
        uploadIfPossible()
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }

    /* ---------------- 前台也弹、点一下进聊天 ---------------- */

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        /* 来电通知上的按钮：不用先进 App 再点一遍（微信在外面也能直接接） */
        if response.actionIdentifier == "call.answer" {
            CallCenter.shared.accept()
            completionHandler()
            return
        }
        if response.actionIdentifier == "call.reject" {
            CallCenter.shared.reject()
            completionHandler()
            return
        }
        /* 点通知本体：如果是来电，把通话界面调出来（App 一进前台就能看到来电页） */
        if (info["kind"] as? String) == "call" { CallCenter.shared.restore() }
        if let chatId = info["chatId"] as? String, !chatId.isEmpty {
            NotificationCenter.default.post(name: .chrisOpenChat, object: nil, userInfo: ["chatId": chatId])
        }
        completionHandler()
    }
}

extension Notification.Name {
    /// 点了推送通知：带着 chatId，会话页收到以后直接进那个聊天
    static let chrisOpenChat = Notification.Name("chris.openChat")
}
