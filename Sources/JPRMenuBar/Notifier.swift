import Foundation
import UserNotifications

nonisolated enum Notifier {
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func transcribed(key: String, preview: String) {
        post(
            title: "Nota transcrita",
            body: preview.isEmpty ? key : preview,
            sound: false
        )
    }

    static func problem(title: String, detail: String) {
        post(title: title, body: detail, sound: true)
    }

    private static func post(title: String, body: String, sound: Bool) {
        guard isAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        if sound { content.sound = .default }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
