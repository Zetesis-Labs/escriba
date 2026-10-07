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
    public let memory: NoteMemory?
    public let recipe: Recipe?
    public let onEvent: EventHandler?

    public init(
        source: RecordingSource,
        ledger: LedgerPort,
        backend: TranscriptionBackend,
        sink: @escaping Sink,
        readiness: @escaping ReadinessProbe = { _ in .ready },
        enrich: Enricher? = nil,
        memory: NoteMemory? = nil,
        recipe: Recipe? = nil,
        onEvent: EventHandler? = nil
    ) {
        self.source = source
        self.ledger = ledger
        self.backend = backend
        self.sink = sink
        self.readiness = readiness
        self.enrich = enrich
        self.memory = memory
        self.recipe = recipe
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
        var downRoutes: Set<String> = []

        for (index, recording) in pending.enumerated() {
            let route = backend.route(recording.url)
            guard !downRoutes.contains(route) else {
                Log.info("\(recording.key) espera: su motor de transcripcion no responde")
                deferred += 1
                continue
            }
            do {
                if try await process(recording) { processed += 1 } else { deferred += 1 }
            } catch let error as TranscriptionError where error.isBackendUnavailable {
                Log.error("backend caido, se reintenta en el proximo ciclo: \(error)")
                onEvent?(.backendUnavailable(reason: "\(error)"))
                downRoutes.insert(route)
                deferred += 1
            } catch let unavailable as RecipeUnavailable {
                Log.error("receta no disponible, las notas esperan: \(unavailable.reason)")
                onEvent?(.recipeUnavailable(reason: unavailable.reason))
                deferred += pending.count - index
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

        let target: RecipeTarget?
        do {
            target = try recipe?.shelf.target(nil)
        } catch {
            throw RecipeUnavailable(reason: "\(error)")
        }

        Log.info("transcribiendo \(recording.key)")
        onEvent?(.transcribing(key: recording.key))
        let started = Date()

        let delivered: (transcript: Transcript, output: URL)
        do {
            delivered = try await deliver(recording, target: target)
        } catch let error as TranscriptionError where error.isBackendUnavailable {
            throw error
        } catch let error as TranscriptionError {
            try ledger.markFailed(recording.key, recording.url, "\(error)")
            Log.error("\(recording.key) fallo: \(error)")
            onEvent?(.failed(key: recording.key, reason: "\(error)"))
            return false
        }

        try ledger.markDone(recording.key, recording.url, delivered.output)
        onEvent?(.transcribed(key: recording.key, transcript: delivered.transcript, output: delivered.output))

        let elapsed = Date().timeIntervalSince(started)
        Log.info(
            "\(recording.key) listo en \(String(format: "%.1f", elapsed))s -> \(delivered.output.lastPathComponent)"
        )
        return true
    }

    private func deliver(
        _ recording: Recording, target: RecipeTarget?
    ) async throws -> (transcript: Transcript, output: URL) {
        let capabilities = Capabilities(backend: backend, enrich: enrich, memory: memory)
        if let recipe, let target {
            return try await deliver(recording, with: recipe, target, capabilities)
        }
        let take = try await capabilities.summarize(recording, try await capabilities.transcribe(recording))
        let output = try await sink(Note(recording: recording, transcript: take.transcript, digest: take.digest))
        return (take.transcript, output)
    }

    private func deliver(
        _ recording: Recording, with recipe: Recipe, _ target: RecipeTarget, _ capabilities: Capabilities
    ) async throws -> (transcript: Transcript, output: URL) {
        let session = RecipeSession(
            recording: recording, capabilities: capabilities, save: sink, publishers: recipe.publishers,
            catalog: recipe.catalog, target: target)
        do {
            try await recipe.runtime.run(target.package, session.bridge)
            guard let delivered = session.delivered else { throw RecipeError.notSaved }
            onEvent?(.traced(key: recording.key, trace: session.trace(error: nil)))
            return delivered
        } catch {
            onEvent?(.traced(key: recording.key, trace: session.trace(error: error)))
            throw error
        }
    }
}

private struct RecipeUnavailable: Error {
    let reason: String
}
