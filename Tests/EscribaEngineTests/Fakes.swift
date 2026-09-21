import Foundation
import Synchronization

@testable import EscribaCore
@testable import EscribaEngine

final class Trace<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    var values: [Value] { storage.withLock { $0 } }
    var count: Int { values.count }
    func append(_ value: Value) { storage.withLock { $0.append(value) } }
}

final class MemoryLedger: Sendable {
    private let done = Mutex<Set<String>>([])
    private let failed = Mutex<[String: String]>([:])
    private let failing = Mutex(false)
    private let markingFails = Mutex(false)

    var doneKeys: Set<String> { done.withLock { $0 } }
    var failures: [String: String] { failed.withLock { $0 } }

    func breakIt() { failing.withLock { $0 = true } }
    func breakMarking() { markingFails.withLock { $0 = true } }

    var port: LedgerPort {
        LedgerPort(
            settledKeys: {
                try self.check()
                return self.done.withLock { $0 }
            },
            markDone: { key, _, _ in
                try self.check()
                self.done.withLock { _ = $0.insert(key) }
            },
            markFailed: { key, _, error in
                try self.check()
                if self.markingFails.withLock({ $0 }) { throw FakeError.ledgerDown }
                self.failed.withLock { $0[key] = error }
            })
    }

    private func check() throws {
        if failing.withLock({ $0 }) { throw FakeError.ledgerDown }
    }
}

enum FakeError: Error { case ledgerDown, scanBroken, sinkBroken }

func recording(_ key: String, minute: Int = 0) -> Recording {
    Recording(
        url: URL(fileURLWithPath: "/grabaciones/\(key).m4a"),
        startedAt: Date(timeIntervalSince1970: TimeInterval(minute * 60)),
        key: key)
}

func source(_ recordings: [Recording]) -> RecordingSource {
    RecordingSource(name: "falsa", locations: [URL(fileURLWithPath: "/grabaciones")]) { recordings }
}

func brokenSource() -> RecordingSource {
    RecordingSource(name: "rota", locations: []) { throw FakeError.scanBroken }
}

func backend(
    _ transcribe: @escaping @Sendable (URL) throws(TranscriptionError) -> Transcript
) -> TranscriptionBackend {
    TranscriptionBackend(name: "falso", transcribe: transcribe)
}

func sink(into trace: Trace<String>) -> Sink {
    { recording, transcript in
        trace.append(transcript.text)
        return URL(fileURLWithPath: "/salida/\(recording.key).txt")
    }
}

func label(_ event: PipelineEvent) -> String {
    switch event {
    case .scanned: "scanned"
    case .passStarted: "passStarted"
    case .transcribing: "transcribing"
    case .transcribed: "transcribed"
    case .failed: "failed"
    case .backendUnavailable: "backendUnavailable"
    case .idle: "idle"
    case .scanFailed: "scanFailed"
    }
}
