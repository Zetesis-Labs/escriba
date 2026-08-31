public enum WatcherStatus: Sendable, Equatable {
    case starting
    case watching
    case working(pending: Int)
    case problem(String)

    public var symbolName: String {
        switch self {
        case .starting: "waveform"
        case .watching: "waveform"
        case .working: "waveform.badge.mic"
        case .problem: "waveform.badge.exclamationmark"
        }
    }

    public var label: String {
        switch self {
        case .starting: "Arrancando"
        case .watching: "Vigilando"
        case .working(let pending): "Transcribiendo (\(pending) en cola)"
        case .problem(let detail): "Problema: \(detail)"
        }
    }
}
