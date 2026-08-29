import Foundation
import JPRCore

struct TranscriptSummary: Sendable {
    let key: String
    let preview: String
    let output: URL
}

enum WatcherStatus: Sendable {
    case starting
    case watching
    case working(pending: Int)
    case problem(String)

    var symbolName: String {
        switch self {
        case .starting: "waveform"
        case .watching: "waveform"
        case .working: "waveform.badge.mic"
        case .problem: "waveform.badge.exclamationmark"
        }
    }

    var label: String {
        switch self {
        case .starting: "Arrancando"
        case .watching: "Vigilando"
        case .working(let pending): "Transcribiendo (\(pending) en cola)"
        case .problem(let detail): "Problema: \(detail)"
        }
    }
}

final class AppState: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: WatcherStatus = .starting
    private var _recent: [TranscriptSummary] = []
    private var _scanned = 0

    static let recentLimit = 8

    var status: WatcherStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }

    var recent: [TranscriptSummary] {
        lock.withLock { _recent }
    }

    var scanned: Int {
        get { lock.withLock { _scanned } }
        set { lock.withLock { _scanned = newValue } }
    }

    func remember(_ summary: TranscriptSummary) {
        lock.withLock {
            _recent.insert(summary, at: 0)
            if _recent.count > Self.recentLimit { _recent.removeLast() }
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
