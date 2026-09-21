import Foundation
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import EscribaStore
import Observation

public typealias Reprocessor = @Sendable (URL, TranscriptionOptions) async throws -> Transcript
public typealias TranscriptWriter = @Sendable (String, Transcript) throws -> Void

@Observable
public final class LibraryModel {
    public private(set) var recordings: [StoredRecording] = []
    public private(set) var reprocessing: Set<String> = []
    public private(set) var publishing: Set<String> = []
    public var status: WatcherStatus = .starting
    public private(set) var scanned = 0

    private let store: Store
    @ObservationIgnored private let reprocess: Reprocessor?
    @ObservationIgnored private let writeText: TranscriptWriter?
    @ObservationIgnored private let publishers: [String: Sink]
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(
        store: Store,
        reprocess: Reprocessor? = nil,
        writeText: TranscriptWriter? = nil,
        publishers: [String: Sink] = [:]
    ) {
        self.store = store
        self.reprocess = reprocess
        self.writeText = writeText
        self.publishers = publishers
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
        case .transcribed:
            if case .problem = status {} else { status = .watching }
        case .failed(let key, let reason):
            await mirror("anotar el fallo de \(key)") {
                try await store.markFailed(key, error: reason)
            }
            status = .problem(key)
        case .backendUnavailable:
            status = .problem("el motor de transcripcion no responde")
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
        try await store.addTranscript(corrected, for: key, backend: "correccion")
        refreshText(corrected, for: key)
        await republish(corrected, for: key)
    }

    public func publish(_ recording: StoredRecording, to connector: String) async throws {
        guard publishers[connector] != nil else { throw LibraryModelError.connectorUnavailable }
        guard let transcript = try await store.transcript(for: recording.key) else {
            throw LibraryModelError.nothingToPublish
        }
        try await send(transcript, for: recording.key, to: connector)
    }

    private func republish(_ transcript: Transcript, for key: String) async {
        let publications: [Publication]
        do {
            publications = try store.recording(for: key)?.publications ?? []
        } catch {
            report("no se pudo saber donde estaba publicada \(key)", error)
            return
        }
        for publication in publications where publication.isPublished {
            do {
                try await send(transcript, for: key, to: publication.connector)
            } catch {
                report("no se pudo republicar \(key) en \(publication.connector)", error)
            }
        }
    }

    private func send(_ transcript: Transcript, for key: String, to connector: String) async throws {
        guard let publish = publishers[connector] else { throw LibraryModelError.connectorUnavailable }
        guard let stored = try store.recording(for: key) else { throw LibraryModelError.unknownRecording }
        let ticket = "\(connector)/\(key)"
        guard !publishing.contains(ticket) else { return }

        publishing.insert(ticket)
        defer { publishing.remove(ticket) }

        _ = try await publish(
            Recording(url: stored.sourceURL, startedAt: stored.startedAt, key: key), transcript)
    }

    private func report(_ what: String, _ error: Error) {
        Log.error("\(what): \(error)")
        status = .problem("\(what): \(error)")
    }

    public func isPublishing(_ key: String, to connector: String) -> Bool {
        publishing.contains("\(connector)/\(key)")
    }

    private func refreshText(_ transcript: Transcript, for key: String) {
        guard let writeText else { return }
        do {
            try writeText(key, transcript)
        } catch {
            Log.error("la transcripcion de \(key) se guardo, pero su .txt no: \(error)")
        }
    }

    public func discard(_ key: String) async throws {
        try await store.discard(key: key)
    }

    public func removeAudio(_ key: String) async throws {
        try await store.removeAudio(key: key)
    }

    public func reprocess(_ recording: StoredRecording, options: TranscriptionOptions) async throws {
        guard let reprocess else { throw LibraryModelError.reprocessUnavailable }
        guard !reprocessing.contains(recording.key) else { return }

        reprocessing.insert(recording.key)
        defer { reprocessing.remove(recording.key) }

        let transcript = try await reprocess(recording.audioURL, options)
        try await store.addTranscript(
            transcript, for: recording.key, backend: "reprocesado", options: options)
        refreshText(transcript, for: recording.key)
        await republish(transcript, for: recording.key)
    }

    public func versions(for key: String) async throws -> [TranscriptVersion] {
        try await store.versions(for: key)
    }

    public func choose(version: Int64, for key: String) async throws {
        try await store.choose(version: version, for: key)
        guard let transcript = try await store.transcript(for: key) else { return }
        refreshText(transcript, for: key)
        await republish(transcript, for: key)
    }
}

public enum LibraryModelError: Error, CustomStringConvertible {
    case reprocessUnavailable
    case connectorUnavailable
    case nothingToPublish
    case unknownRecording

    public var description: String {
        switch self {
        case .reprocessUnavailable: "esta app no tiene motor de reprocesado configurado"
        case .connectorUnavailable: "ese conector no esta activo en Ajustes"
        case .nothingToPublish: "esta grabacion aun no tiene transcripcion"
        case .unknownRecording: "esta grabacion ya no esta en la biblioteca"
        }
    }
}
