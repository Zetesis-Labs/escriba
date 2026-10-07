import Foundation
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import EscribaStore
import Observation

nonisolated public struct RecipeChoice: Sendable, Equatable {
    public var recipe: String?
    public var parameters: DefaultRecipeSettings?

    public init(recipe: String? = nil, parameters: DefaultRecipeSettings? = nil) {
        self.recipe = recipe
        self.parameters = parameters
    }
}

nonisolated public struct RecipeRunReport: Sendable, Equatable {
    public let trace: RecipeTrace?
    public let failure: String?

    public init(trace: RecipeTrace?, failure: String?) {
        self.trace = trace
        self.failure = failure
    }
}

public typealias RecipeReprocessor = @Sendable (StoredRecording, RecipeChoice) async -> RecipeRunReport
public typealias Unpublisher = @Sendable (String) async throws -> Void
public typealias Digester = @Sendable (StoredRecording, Transcript) async throws -> Digest

@Observable
public final class LibraryModel {
    public private(set) var recordings: [StoredRecording] = []
    public private(set) var reprocessing: Set<String> = []
    public private(set) var summarizing: Set<String> = []
    public private(set) var publishing: Set<String> = []
    private var traceRevisions: [String: Int] = [:]
    public var status: WatcherStatus = .starting
    public private(set) var scanned = 0

    private let store: Store
    @ObservationIgnored private let reprocess: RecipeReprocessor?
    @ObservationIgnored private let digester: Digester?
    @ObservationIgnored private let publishers: [String: Sink]
    @ObservationIgnored private let unpublishers: [String: Unpublisher]
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(
        store: Store,
        reprocess: RecipeReprocessor? = nil,
        digester: Digester? = nil,
        publishers: [String: Sink] = [:],
        unpublishers: [String: Unpublisher] = [:]
    ) {
        self.store = store
        self.reprocess = reprocess
        self.digester = digester
        self.publishers = publishers
        self.unpublishers = unpublishers
    }

    public func unpublish(_ key: String, from connector: String) async throws {
        guard let unpublish = unpublishers[connector] else { throw LibraryModelError.connectorUnavailable }
        guard let pageId = try store.recording(for: key)?.publication(in: connector)?.pageId else {
            throw LibraryModelError.nothingToUnpublish
        }
        try await unpublish(pageId)
        try store.removePublication(key: key, connector: connector)
    }

    public var publishingConnectors: [String] { Array(publishers.keys) }

    public func canPublish(to connector: String) -> Bool { publishers[connector] != nil }

    deinit {
        observation?.cancel()
    }

    public func startObserving() {
        observation?.cancel()
        observation = Task {
            do {
                for try await batch in store.observeRecordings() {
                    recordings = batch
                }
            } catch {
                status = .problem("la biblioteca dejo de observarse: \(error)")
            }
        }
    }

    public func apply(_ event: PipelineEvent) async {
        switch event {
        case .scanned(let recordings):
            await mirror("registrar lo escaneado") { try await store.register(recordings) }
        case .passStarted(let pending):
            status = .working(pending: pending)
        case .transcribing(let key):
            await mirror("marcar \(key) en proceso") { try await store.markProcessing(key) }
        case .transcribed(let key, _, _):
            await mirror("marcar \(key) como hecha") { try await store.markDone(key) }
            if case .problem = status {} else { status = .watching }
        case .traced(let key, let trace):
            await mirror("guardar la traza de \(key)") { try await store.saveRun(trace, for: key, trigger: .pipeline) }
            traceRevisions[key, default: 0] += 1
        case .failed(let key, let reason):
            await mirror("anotar el fallo de \(key)") {
                try await store.markFailed(key, error: reason)
            }
            status = .problem(key)
        case .backendUnavailable:
            status = .problem("el motor de transcripcion no responde")
        case .recipeUnavailable:
            status = .problem("la receta por defecto no está disponible")
        case .scanFailed:
            status = .problem("no puedo leer la carpeta")
        case .idle(let scanned):
            self.scanned = scanned
            if case .problem = status {} else { status = .watching }
        }
    }

    private func mirror(_ what: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            Log.error("la biblioteca no pudo \(what): \(error)")
        }
    }

    public func transcript(for key: String) async throws -> Transcript? {
        try await store.transcript(for: key)
    }

    public func applyCorrection(_ corrected: Transcript, to key: String) async throws {
        let digest = try await store.digest(for: key)
        try await store.addTranscript(corrected, for: key, backend: "correccion", digest: digest)
        await republish(corrected, digest: digest, for: key)
    }

    public var canSummarize: Bool { digester != nil }

    public func isSummarizing(_ key: String) -> Bool { summarizing.contains(key) }

    @discardableResult
    public func summarize(_ recording: StoredRecording) async throws -> Digest {
        guard let digester else { throw LibraryModelError.summaryUnavailable }
        guard !summarizing.contains(recording.key) else { throw LibraryModelError.alreadySummarizing }

        summarizing.insert(recording.key)
        defer { summarizing.remove(recording.key) }

        return try await generate(with: digester, for: recording.key)
    }

    private func generate(with digester: Digester, for key: String) async throws -> Digest {
        guard let recording = try store.recording(for: key),
            let transcript = try await store.transcript(for: key),
            let version = try await store.currentVersion(for: key)
        else { throw LibraryModelError.nothingToSummarize }

        let digest = try await digester(recording, transcript)
        try await store.setDigest(digest, for: key, version: version)
        await republish(transcript, digest: digest, for: key, version: version)
        return digest
    }

    public func forgetSummary(_ key: String) async throws {
        try await store.setDigest(nil, for: key)
        guard let transcript = try await store.transcript(for: key) else { return }
        await republish(transcript, digest: nil, for: key)
    }

    public func digest(for key: String) async throws -> Digest? {
        try await store.digest(for: key)
    }

    public func publish(_ recording: StoredRecording, to connector: String) async throws {
        guard publishers[connector] != nil else { throw LibraryModelError.connectorUnavailable }
        guard let transcript = try await store.transcript(for: recording.key) else {
            throw LibraryModelError.nothingToPublish
        }
        try await send(
            transcript, digest: try await store.digest(for: recording.key), for: recording.key,
            to: connector)
    }

    private func republish(
        _ transcript: Transcript, digest: Digest?, for key: String, version: Int64? = nil
    ) async {
        guard await isCurrent(version, for: key) else { return }
        let publications: [Publication]
        do {
            publications = try store.recording(for: key)?.publications ?? []
        } catch {
            report("no se pudo saber donde estaba publicada \(key)", error)
            return
        }
        for publication in publications where publication.isPublished {
            do {
                try await send(transcript, digest: digest, for: key, to: publication.connector)
            } catch {
                report("no se pudo republicar \(key) en \(publication.connector)", error)
            }
        }
    }

    private func isCurrent(_ version: Int64?, for key: String) async -> Bool {
        guard let version else { return true }
        guard let current = try? await store.currentVersion(for: key) else { return false }
        return current == version
    }

    private func send(
        _ transcript: Transcript, digest: Digest?, for key: String, to connector: String
    ) async throws {
        guard let publish = publishers[connector] else { throw LibraryModelError.connectorUnavailable }
        guard let stored = try store.recording(for: key) else { throw LibraryModelError.unknownRecording }
        let ticket = "\(connector)/\(key)"
        guard !publishing.contains(ticket) else { return }

        publishing.insert(ticket)
        defer { publishing.remove(ticket) }

        _ = try await publish(
            Note(
                recording: Recording(url: stored.sourceURL, startedAt: stored.startedAt, key: key),
                transcript: transcript,
                digest: digest))
    }

    private func report(_ what: String, _ error: Error) {
        Log.error("\(what): \(error)")
        status = .problem("\(what): \(error)")
    }

    public func isPublishing(_ key: String, to connector: String) -> Bool {
        publishing.contains("\(connector)/\(key)")
    }

    public func discard(_ key: String) async throws {
        try await store.discard(key: key)
    }

    public func removeAudio(_ key: String) async throws {
        try await store.removeAudio(key: key)
    }

    public func reprocess(_ recording: StoredRecording, with choice: RecipeChoice = RecipeChoice()) async throws {
        guard let reprocess else { throw LibraryModelError.reprocessUnavailable }
        guard !reprocessing.contains(recording.key) else { return }

        reprocessing.insert(recording.key)
        defer { reprocessing.remove(recording.key) }

        let report = await reprocess(recording, choice)
        if let trace = report.trace {
            await mirror("guardar la traza de \(recording.key)") {
                try await store.saveRun(trace, for: recording.key, trigger: .reprocess)
            }
            traceRevisions[recording.key, default: 0] += 1
        }
        if let failure = report.failure { throw LibraryModelError.recipeFailed(failure) }
        await mirror("marcar \(recording.key) como hecha") { try await store.markDone(recording.key) }
    }

    public func runs(_ filter: RecipeRunFilter = RecipeRunFilter()) -> RecipeRunsModel {
        RecipeRunsModel(store: store, filter: filter)
    }

    public func traceRevision(for key: String) -> Int {
        traceRevisions[key, default: 0]
    }

    public func latestTrace(for key: String) async throws -> RecipeTrace? {
        try await store.latestTrace(for: key)
    }

    public func versions(for key: String) async throws -> [TranscriptVersion] {
        try await store.versions(for: key)
    }

    public func choose(version: Int64, for key: String) async throws {
        try await store.choose(version: version, for: key)
        guard let transcript = try await store.transcript(for: key) else { return }
        await republish(transcript, digest: try await store.digest(for: key), for: key)
    }
}

public enum LibraryModelError: Error, Equatable, CustomStringConvertible {
    case reprocessUnavailable
    case recipeFailed(String)
    case summaryUnavailable
    case nothingToSummarize
    case alreadySummarizing
    case connectorUnavailable
    case nothingToPublish
    case unknownRecording
    case nothingToUnpublish

    public var description: String {
        switch self {
        case .reprocessUnavailable: "esta app no tiene motor de reprocesado configurado"
        case .recipeFailed(let reason): reason
        case .summaryUnavailable: "los resumenes automaticos estan apagados en LLMs"
        case .nothingToSummarize: "esta grabacion aun no tiene transcripcion que resumir"
        case .alreadySummarizing: "ya se esta resumiendo esta grabacion"
        case .connectorUnavailable: "ese conector no esta activo en Ajustes"
        case .nothingToPublish: "esta grabacion aun no tiene transcripcion"
        case .unknownRecording: "esta grabacion ya no esta en la biblioteca"
        case .nothingToUnpublish: "esta grabacion no esta publicada en ese conector"
        }
    }
}
