import AppKit
import UserNotifications

@MainActor
final class RecordingNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var onExtend: (() -> Void)?

    func prepare(onExtend: @escaping () -> Void) {
        self.onExtend = onExtend
        center.delegate = self
        let action = UNNotificationAction(identifier: "extend", title: "15分延長", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "recording-limit", actions: [action], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func warning(minutes: Int, hasSound: Bool) {
        let body = "あと\(minutes)分で録音を停止します。" + (hasSound ? "音声入力が続いています。必要なら15分延長してください。" : "必要なら15分延長できます。")
        post(id: "recording-warning", title: "録音の自動停止予告", body: body, category: "recording-limit")
        NSApp.requestUserAttention(.informationalRequest)
        NSSound.beep()
    }

    func stopped(hasSound: Bool) {
        post(id: "recording-stopped", title: "録音を自動停止しました", body: hasSound ? "音声入力が続いている状態で上限に達しました。必要なら新しい録音を開始してください。" : "設定した時間に達しました。話者付きの全文を作成しています。", category: "")
        NSApp.requestUserAttention(.informationalRequest)
    }

    func clearWarnings() {
        center.removePendingNotificationRequests(withIdentifiers: ["recording-warning"])
        center.removeDeliveredNotifications(withIdentifiers: ["recording-warning"])
    }

    private func post(id: String, title: String, body: String, category: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "extend" else { return }
        await MainActor.run { self.onExtend?() }
    }
}
