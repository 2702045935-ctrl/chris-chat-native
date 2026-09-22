import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox

/* 新消息通知：按「消息通知」里的设置真响真震
   · on 关掉：什么都不做
   · sound / vibrate：前台用系统音效 + 震动
   · showDetail 关掉：通知只显示「你收到一条新消息」，不带内容
   · 免打扰时段：这段里不响不震
   同时发一条本地通知，App 在后台/锁屏也能看到（不需要 APNs） */
enum LocalNotify {
    static var settings = NotifySettings()

    static func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func refresh() async {
        settings = await API.shared.notifySettings()
    }

    /// 现在是不是在免打扰时段里（22:00—07:00 这种跨天也算）
    static func mutedNow() -> Bool {
        let a = settings.muteStart, b = settings.muteEnd
        guard !a.isEmpty, !b.isEmpty else { return false }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        guard let s = f.date(from: a), let e = f.date(from: b) else { return false }
        let cal = Calendar.current
        let now = cal.dateComponents([.hour, .minute], from: Date())
        let cur = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let sv = cal.dateComponents([.hour, .minute], from: s)
        let ev = cal.dateComponents([.hour, .minute], from: e)
        let start = (sv.hour ?? 0) * 60 + (sv.minute ?? 0)
        let end = (ev.hour ?? 0) * 60 + (ev.minute ?? 0)
        if start == end { return false }
        return start < end ? (cur >= start && cur < end) : (cur >= start || cur < end)
    }

    /// 收到一条不属于当前会话的新消息
    static func incoming(title: String, body: String, chatId: String = "", badge: Int = 0) {
        guard settings.on else { return }
        guard !mutedNow() else { return }
        if settings.sound { AudioServicesPlaySystemSound(1007) }
        if settings.vibrate { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = settings.showDetail ? body : "你收到一条新消息"
        if settings.sound { c.sound = .default }
        /* 桌面图标上的数字（和微信一样：未读数） */
        c.badge = NSNumber(value: max(0, min(999, badge)))
        /* 带上 chatId：点通知直接进那个聊天（和服务器推的 APNs 通知一个规矩） */
        if !chatId.isEmpty { c.userInfo = ["chatId": chatId] }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
