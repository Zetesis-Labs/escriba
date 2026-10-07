import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaModel
@testable import EscribaStore

private func traza(_ recipe: String, recipes: [String]? = nil, outcome: RecipeRunOutcome = .ok) -> RecipeTrace {
    RecipeTrace(
        recipe: recipe, name: recipe, fingerprint: "abc", steps: [], logs: [], error: outcome == .ok ? nil : "mal",
        outcome: outcome, recipes: recipes)
}

private func espera(_ condicion: () -> Bool) async throws {
    let limite = Date().addingTimeInterval(5)
    while !condicion() {
        guard Date() < limite else {
            Issue.record("no llego a cumplirse")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Suite("Las ejecuciones se ven en vivo, con su filtro")
struct EjecucionesModelTests {
    private func biblioteca() async throws -> (Store, LibraryModel) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-runs-\(UUID().uuidString)")
        let store = try Store(root: base.appending(path: "library"))
        try await store.register([
            Recording(url: base.appending(path: "a.m4a"), startedAt: Date(), key: "a"),
            Recording(url: base.appending(path: "b.m4a"), startedAt: Date(), key: "b"),
        ])
        return (store, LibraryModel(store: store))
    }

    @Test("una ejecucion nueva aparece sola, y cambiar el filtro vuelve a consultar")
    func enVivo() async throws {
        let (store, biblioteca) = try await biblioteca()
        let ejecuciones = biblioteca.runs(RecipeRunFilter(recipe: "F1"))
        ejecuciones.start()

        try await store.saveRun(traza("reparto", recipes: ["reparto", "F1"]), for: "a", trigger: .pipeline)
        try await store.saveRun(traza("otra", outcome: .failed), for: "b", trigger: .pipeline)
        try await espera { ejecuciones.runs.map(\.recordingKey) == ["a"] }

        ejecuciones.filter = RecipeRunFilter(outcome: .failed)
        try await espera { ejecuciones.runs.map(\.recordingKey) == ["b"] }

        ejecuciones.stop()
    }
}
