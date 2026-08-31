import Foundation
import UserNotifications

import JPRCore

nonisolated enum Notifier {
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func notify(_ event: PipelineEvent) {
        switch event {
        case .transcribed(let key, let transcript, _):
            transcribed(key: key, preview: preview(of: transcript.text))
        case .failed(let key, let reason):
            problem(title: "Fallo al transcribir \(key)", detail: reason)
        case .backendUnavailable(let reason):
            problem(title: "El motor de transcripcion no responde", detail: reason)
        case .scanFailed(let reason):
            problem(title: "No puedo leer las grabaciones", detail: reason)
        case .passStarted, .idle:
            break
        }
    }

    private static func preview(of text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }

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
