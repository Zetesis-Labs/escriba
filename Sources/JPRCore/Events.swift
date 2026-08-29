import Foundation

public enum PipelineEvent: Sendable {
    case passStarted(pending: Int)
    case transcribed(key: String, transcript: Transcript, output: URL)
    case failed(key: String, reason: String)
    case backendUnavailable(reason: String)
    case idle(scanned: Int)
    case scanFailed(reason: String)

    public var isProblem: Bool {
        switch self {
        case .failed, .backendUnavailable, .scanFailed: true
        default: false
        }
    }
}

public typealias EventHandler = @Sendable (PipelineEvent) -> Void
