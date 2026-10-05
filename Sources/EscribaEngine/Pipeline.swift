import Foundation
import EscribaCore

public typealias ReadinessProbe = @Sendable (Recording) async -> FileState

public struct Pipeline: Sendable {
    public let source: RecordingSource
    public let ledger: LedgerPort
    public let backend: TranscriptionBackend
    public let sink: Sink
    public let readiness: ReadinessProbe
    public let enrich: Enricher?
    public let onEvent: EventHandler?

    public init(
        source: RecordingSource,
        ledger: LedgerPort,
        backend: TranscriptionBackend,
        sink: @escaping Sink,
        readiness: @escaping ReadinessProbe = { _ in .ready },
        enrich: Enricher? = nil,
        onEvent: EventHandler? = nil
    ) {
        self.source = source
        self.ledger = ledger
        self.backend = backend
        self.sink = sink
        self.readiness = readiness
        self.enrich = enrich
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
        onEvent?(.scanned(recordings: all))
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
                recordFailure(of: recording, error)
                onEvent?(.failed(key: recording.key, reason: "\(error)"))
            }
        }

        return PassOutcome(processed: processed, deferred: deferred)
    }

    private func recordFailure(of recording: Recording, _ error: Error) {
        do {
            try ledger.markFailed(recording.key, recording.url, "\(error)")
        } catch let ledgerError {
            Log.error("el ledger no pudo anotar el fallo de \(recording.key): \(ledgerError)")
        }
    }

    private func process(_ recording: Recording) async throws -> Bool {
        let state = await readiness(recording)
        guard state == .ready else {
            Log.info("\(recording.key) aun no listo (\(state.rawValue)), se deja para el proximo ciclo")
            return false
        }

        Log.info("transcribiendo \(recording.key)")
        onEvent?(.transcribing(key: recording.key))
        let started = Date()

        let transcript: Transcript
        do {
            transcript = try await backend.transcribe(recording.url)
        } catch where error.isBackendUnavailable {
            throw error
        } catch {
            try ledger.markFailed(recording.key, recording.url, "\(error)")
            Log.error("\(recording.key) fallo: \(error)")
            onEvent?(.failed(key: recording.key, reason: "\(error)"))
            return false
        }

        let note = Note(
            recording: recording, transcript: transcript, digest: await enrich?(recording, transcript))
        let output = try await sink(note)
        try ledger.markDone(recording.key, recording.url, output)
        onEvent?(.transcribed(key: recording.key, transcript: transcript, output: output))

        let elapsed = Date().timeIntervalSince(started)
        Log.info(
            "\(recording.key) listo en \(String(format: "%.1f", elapsed))s -> \(output.lastPathComponent)"
        )
        return true
    }
}
