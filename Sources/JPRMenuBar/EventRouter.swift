import Foundation
import JPRCore

extension Notification.Name {
    static let jprStateChanged = Notification.Name("dev.ruben.jpr-transcribe.stateChanged")
}

nonisolated enum EventRouter {
    static func handler(for state: AppState) -> EventHandler {
        { event in
            apply(event, to: state)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .jprStateChanged, object: nil)
            }
        }
    }

    private static func apply(_ event: PipelineEvent, to state: AppState) {
        switch event {
        case .passStarted(let pending):
            state.status = .working(pending: pending)

        case .transcribed(let key, let transcript, let output):
            let preview = preview(of: transcript.text)
            state.remember(TranscriptSummary(key: key, preview: preview, output: output))
            state.status = .watching
            Notifier.transcribed(key: key, preview: preview)

        case .failed(let key, let reason):
            state.status = .problem(key)
            Notifier.problem(title: "Fallo al transcribir \(key)", detail: reason)

        case .backendUnavailable(let reason):
            state.status = .problem("el motor de transcripcion no responde")
            Notifier.problem(title: "El motor de transcripcion no responde", detail: reason)

        case .scanFailed(let reason):
            state.status = .problem("no puedo leer la carpeta")
            Notifier.problem(title: "No puedo leer las grabaciones", detail: reason)

        case .idle(let scanned):
            state.scanned = scanned
            if case .problem = state.status {} else { state.status = .watching }
        }
    }

    static func preview(of text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }
}
