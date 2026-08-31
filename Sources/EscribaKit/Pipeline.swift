import Foundation
import EscribaCore

public struct Pipeline: Sendable {
    public let source: RecordingSource
    public let ledger: Ledger
    public let backend: TranscriptionBackend
    public let sink: Sink
    public let settleSeconds: TimeInterval
    public let materializeTimeout: TimeInterval
    public let onEvent: EventHandler?

    public init(
        source: RecordingSource,
        ledger: Ledger,
        backend: TranscriptionBackend,
        sink: @escaping Sink,
        settleSeconds: TimeInterval = 15,
        materializeTimeout: TimeInterval = 300,
        onEvent: EventHandler? = nil
    ) {
        self.source = source
        self.ledger = ledger
        self.backend = backend
        self.sink = sink
        self.settleSeconds = settleSeconds
        self.materializeTimeout = materializeTimeout
        self.onEvent = onEvent
    }

    @discardableResult
    public func runOnce() async throws -> PassOutcome {
        let all: [Recording]
        do {
            all = try source.scan()
        } catch {
            onEvent?(.scanFailed(reason: "\(error)"))
            throw error
        }
        let pending = selectPending(all, done: try ledger.settledKeys())
        guard !pending.isEmpty else {
            Log.debug("sin pendientes (\(all.count) grabaciones en disco)")
            onEvent?(.idle(scanned: all.count))
            return PassOutcome(processed: 0, deferred: 0)
        }

        Log.info("pendientes: \(pending.count)")
        onEvent?(.passStarted(pending: pending.count))
        var processed = 0
        var deferred = 0

        for recording in pending {
            do {
                if try await process(recording) { processed += 1 } else { deferred += 1 }
            } catch let error as TranscriptionError where error.isBackendUnavailable {
                Log.error("backend caido, se reintenta en el proximo ciclo: \(error)")
                onEvent?(.backendUnavailable(reason: "\(error)"))
                deferred += 1
                break
            } catch {
                Log.error("fallo procesando \(recording.key): \(error)")
                try? ledger.markFailed(
                    key: recording.key, source: recording.url, error: "\(error)")
                onEvent?(.failed(key: recording.key, reason: "\(error)"))
            }
        }

        return PassOutcome(processed: processed, deferred: deferred)
    }

    private func process(_ recording: Recording) async throws -> Bool {
        let state = await offloaded { awaitReadiness(recording) }
        guard state == .ready else {
            Log.info("\(recording.key) aun no listo (\(state.rawValue)), se deja para el proximo ciclo")
            return false
        }

        Log.info("transcribiendo \(recording.key)")
        let started = Date()

        let transcript: Transcript
        do {
            transcript = try await backend.transcribe(recording.url)
        } catch where error.isBackendUnavailable {
            throw error
        } catch {
            try ledger.markFailed(key: recording.key, source: recording.url, error: "\(error)")
            Log.error("\(recording.key) fallo: \(error)")
            onEvent?(.failed(key: recording.key, reason: "\(error)"))
            return false
        }

        let output = try sink(recording, transcript)
        try ledger.markDone(key: recording.key, source: recording.url, output: output)
        onEvent?(.transcribed(key: recording.key, transcript: transcript, output: output))

        let elapsed = Date().timeIntervalSince(started)
        Log.info(
            "\(recording.key) listo en \(String(format: "%.1f", elapsed))s -> \(output.lastPathComponent)"
        )
        return true
    }

    private nonisolated func awaitReadiness(_ recording: Recording) -> FileState {
        guard var probe = FileSystem.probe(recording.url) else { return .empty }

        var state = classify(probe: probe, previous: nil, settleSeconds: settleSeconds)
        guard state == .dataless else { return state }

        Log.info("\(recording.key) esta en la nube, forzando descarga")
        FileSystem.requestMaterialization(recording.url, timeout: materializeTimeout)

        guard let refreshed = FileSystem.probe(recording.url) else { return .empty }
        probe = refreshed
        state = classify(probe: probe, previous: nil, settleSeconds: settleSeconds)
        return state
    }
}
