import UserNotifications
import UIKit

/// 本地通知。免费开发账号没有 APNs，所以只能在 App 还活着（前台，或刚切到后台的约 30 秒内）时提醒。
enum Notifier {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "dsbot.notify") as? Bool ?? true }

    static func requestIfNeeded() async {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    static func post(id: String, title: String, body: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func setBadge(_ count: Int) {
        guard enabled else { return }
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    static func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}
