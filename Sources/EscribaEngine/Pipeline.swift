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
                switch try await process(recording) {
                case .done: processed += 1
                case .deferred: deferred += 1
                case .settled: break
                }
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
                recordFailure(of: recording, "\(error)")
                onEvent?(.failed(key: recording.key, reason: "\(error)"))
            }
        }

        return PassOutcome(processed: processed, deferred: deferred)
    }

    private func recordFailure(of recording: Recording, _ reason: String) {
        do {
            try ledger.markFailed(recording.key, recording.url, reason)
        } catch let ledgerError {
            Log.error("el ledger no pudo anotar el fallo de \(recording.key): \(ledgerError)")
        }
    }

    private enum Processed {
        case done
        case deferred
        case settled
    }

    private func process(_ recording: Recording) async throws -> Processed {
        let state = await readiness(recording)
        if state == .abandoned {
            let reason = "el fichero está vacío (0 bytes) desde hace más de una hora"
            Log.info("\(recording.key): \(reason)")
            recordFailure(of: recording, reason)
            onEvent?(.failed(key: recording.key, reason: reason))
            return .settled
        }
        guard state == .ready else {
            Log.info("\(recording.key) aun no listo (\(state.rawValue)), se deja para el proximo ciclo")
            return .deferred
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
            return .deferred
        }

        try ledger.markDone(recording.key, recording.url, delivered.output)
        onEvent?(.transcribed(key: recording.key, transcript: delivered.transcript, output: delivered.output))

        let elapsed = Date().timeIntervalSince(started)
        Log.info(
            "\(recording.key) listo en \(String(format: "%.1f", elapsed))s -> \(delivered.output.lastPathComponent)"
        )
        return .done
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
        let (result, trace) = await runRecipe(
            target, of: recipe, on: recording, capabilities: capabilities, save: sink)
        onEvent?(.traced(key: recording.key, trace: trace))
        return try result.get()
    }
}

public func runRecipe(
    _ target: RecipeTarget, of recipe: Recipe, on recording: Recording, audio: URL? = nil,
    backend: TranscriptionBackend, enrich: Enricher?, memory: NoteMemory?, save: @escaping Sink, dryRun: Bool = false
) async -> (result: Result<(transcript: Transcript, output: URL), any Error>, trace: RecipeTrace) {
    await runRecipe(
        target, of: recipe, on: recording, audio: audio,
        capabilities: Capabilities(backend: backend, enrich: enrich, memory: memory, readOnly: dryRun), save: save,
        dryRun: dryRun)
}

private func runRecipe(
    _ target: RecipeTarget, of recipe: Recipe, on recording: Recording, audio: URL? = nil,
    capabilities: Capabilities, save: @escaping Sink, dryRun: Bool = false
) async -> (result: Result<(transcript: Transcript, output: URL), any Error>, trace: RecipeTrace) {
    let session = RecipeSession(
        recording: recording, audio: audio, capabilities: capabilities, save: save, recipe: recipe, target: target,
        dryRun: dryRun)
    do {
        try await recipe.runtime.run(target.package, session.bridge)
        guard let delivered = session.delivered else { throw RecipeError.notSaved }
        return (.success(delivered), session.trace(error: nil))
    } catch {
        return (.failure(error), session.trace(error: error))
    }
}

private struct RecipeUnavailable: Error {
    let reason: String
}
