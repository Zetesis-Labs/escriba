import Foundation
import Observation
import EscribaCore
import EscribaStore

@Observable
public final class RecipeRunsModel {
    public private(set) var runs: [RecipeRunRecord] = []
    public private(set) var problem: String?
    public var filter: RecipeRunFilter {
        didSet { if filter != oldValue, observation != nil { start() } }
    }

    private let store: Store
    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(store: Store, filter: RecipeRunFilter) {
        self.store = store
        self.filter = filter
    }

    public func start() {
        observation?.cancel()
        let filter = filter
        observation = Task {
            do {
                for try await batch in store.observeRuns(filter) {
                    runs = batch
                    problem = nil
                }
            } catch is CancellationError {
            } catch {
                problem = "no se pudo leer el historial de ejecuciones: \(error)"
            }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }
}
