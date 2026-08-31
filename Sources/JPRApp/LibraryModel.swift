import Foundation
import JPRCore
import JPRStore
import Observation

public typealias Reprocessor = @Sendable (URL, Int?) throws -> Transcript

@Observable
public final class LibraryModel {
    public private(set) var recordings: [StoredRecording] = []
    public private(set) var reprocessing: Set<String> = []
    public var status: WatcherStatus = .starting
    public private(set) var scanned = 0

    private let store: Store
    @ObservationIgnored private let reprocess: Reprocessor?
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(store: Store, reprocess: Reprocessor? = nil) {
        self.store = store
        self.reprocess = reprocess
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

    public func apply(_ event: PipelineEvent) {
        switch event {
        case .passStarted(let pending):
            status = .working(pending: pending)
        case .transcribed:
            status = .watching
        case .failed(let key, _):
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

    public func transcript(for key: String) throws -> Transcript? {
        try store.transcript(for: key)
    }

    public func applyCorrection(_ corrected: Transcript, to key: String) throws {
        try store.addTranscript(corrected, for: key, backend: "correccion")
    }

    public func reprocess(_ recording: StoredRecording, speakers: Int?) async throws {
        guard let reprocess else { throw LibraryModelError.reprocessUnavailable }
        guard !reprocessing.contains(recording.key) else { return }

        reprocessing.insert(recording.key)
        defer { reprocessing.remove(recording.key) }

        let url = recording.audioURL
        let transcript = try await Task.detached { try reprocess(url, speakers) }.value
        try store.addTranscript(transcript, for: recording.key, backend: "reprocesado")
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
