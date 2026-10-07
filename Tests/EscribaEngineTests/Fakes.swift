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

final class MemoryNotes: Sendable {
    private let kept = Mutex<[String: Remembered]>([:])
    private let nextVersion = Mutex<Int64>(1)
    private let keepingFails = Mutex(false)
    private let recallFails = Mutex(false)
    let steps: Trace<String>

    static let defaultInputs = TranscriptionInputs(backend: "falso", options: .automatic)

    init(steps: Trace<String> = Trace()) {
        self.steps = steps
    }

    private static func slot(_ key: String, _ inputs: TranscriptionInputs) -> String {
        "\(key)|\(inputs.backend)|\(inputs.options.label)"
    }

    @discardableResult
    func remember(
        _ key: String, _ transcript: Transcript, digest: Digest? = nil, inputs: TranscriptionInputs = defaultInputs
    ) -> Int64 {
        let version = nextVersion.withLock { value in
            defer { value += 1 }
            return value
        }
        kept.withLock {
            $0[Self.slot(key, inputs)] = Remembered(version: version, transcript: transcript, digest: digest)
        }
        return version
    }

    func kept(_ key: String, inputs: TranscriptionInputs = defaultInputs) -> Remembered? {
        kept.withLock { $0[Self.slot(key, inputs)] }
    }

    var count: Int { kept.withLock { $0.count } }
    func breakKeeping() { keepingFails.withLock { $0 = true } }
    func breakRecall() { recallFails.withLock { $0 = true } }

    var port: NoteMemory {
        NoteMemory(
            recall: { recording, inputs in
                if self.recallFails.withLock({ $0 }) { throw FakeError.memoryDown }
                return self.kept(recording.key, inputs: inputs)
            },
            keepTranscript: { recording, transcript, inputs in
                if self.keepingFails.withLock({ $0 }) { throw FakeError.memoryDown }
                let version = self.remember(recording.key, transcript, inputs: inputs)
                self.steps.append("guarda transcripcion")
                return version
            },
            keepDigest: { recording, version, digest in
                if self.keepingFails.withLock({ $0 }) { throw FakeError.memoryDown }
                self.kept.withLock { kept in
                    guard
                        let slot = kept.first(where: { $0.key.hasPrefix("\(recording.key)|") && $0.value.version == version })?.key,
                        let current = kept[slot]
                    else { return }
                    kept[slot] = Remembered(version: version, transcript: current.transcript, digest: digest)
                }
                self.steps.append("guarda resumen v\(version)")
            })
    }
}

enum FakeError: Error { case ledgerDown, scanBroken, sinkBroken, memoryDown }

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
    { note in
        trace.append(note.transcript.text)
        return URL(fileURLWithPath: "/salida/\(note.recording.key).txt")
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
    case .traced: "traced"
    }
}
