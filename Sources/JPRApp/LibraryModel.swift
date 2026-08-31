import Foundation
import JPRCore
import JPRStore
import Observation

@Observable
public final class LibraryModel {
    public private(set) var recordings: [StoredRecording] = []
    public var status: WatcherStatus = .starting
    public private(set) var scanned = 0

    private let store: Store
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(store: Store) {
        self.store = store
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
}
