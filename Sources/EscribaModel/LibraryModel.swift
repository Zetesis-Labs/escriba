import Foundation
import EscribaCore
import EscribaKit
import EscribaStore
import Observation

public typealias Reprocessor = @Sendable (URL, Int?) async throws -> Transcript
public typealias TranscriptWriter = @Sendable (String, Transcript) throws -> Void

@Observable
public final class LibraryModel {
    public private(set) var recordings: [StoredRecording] = []
    public private(set) var reprocessing: Set<String> = []
    public var status: WatcherStatus = .starting
    public private(set) var scanned = 0

    private let store: Store
    @ObservationIgnored private let reprocess: Reprocessor?
    @ObservationIgnored private let writeText: TranscriptWriter?
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(
        store: Store, reprocess: Reprocessor? = nil, writeText: TranscriptWriter? = nil
    ) {
        self.store = store
        self.reprocess = reprocess
        self.writeText = writeText
    }

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
            status = .watching
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

    public func reprocess(_ recording: StoredRecording, speakers: Int?) async throws {
        guard let reprocess else { throw LibraryModelError.reprocessUnavailable }
        guard !reprocessing.contains(recording.key) else { return }

        reprocessing.insert(recording.key)
        defer { reprocessing.remove(recording.key) }

        let transcript = try await reprocess(recording.audioURL, speakers)
        try await store.addTranscript(transcript, for: recording.key, backend: "reprocesado")
        refreshText(transcript, for: recording.key)
    }
}

public enum LibraryModelError: Error, CustomStringConvertible {
    case reprocessUnavailable

    public var description: String {
        switch self {
        case .reprocessUnavailable: "esta app no tiene motor de reprocesado configurado"
        }
    }
}
