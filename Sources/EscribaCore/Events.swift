import Foundation

public enum PipelineEvent: Sendable {
    case passStarted(pending: Int)
    case scanned(recordings: [Recording])
    case transcribing(key: String)
    case transcribed(key: String, transcript: Transcript, output: URL)
    case failed(key: String, reason: String)
    case backendUnavailable(reason: String)
    case recipeUnavailable(reason: String)
    case idle(scanned: Int)
    case scanFailed(reason: String)
    case traced(key: String, trace: RecipeTrace)

    public var isProblem: Bool {
        switch self {
        case .failed, .backendUnavailable, .recipeUnavailable, .scanFailed: true
        default: false
        }
    }
}

public typealias EventHandler = @Sendable (PipelineEvent) -> Void
