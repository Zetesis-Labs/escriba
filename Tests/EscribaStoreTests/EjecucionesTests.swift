import Foundation
import GRDB
import Testing

@testable import EscribaCore
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-ejecuciones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func register(_ keys: String...) async throws {
        try await store.register(keys.map {
            Recording(url: base.appending(path: "\($0).m4a"), startedAt: Date(), key: $0)
        })
    }
}

private let ahora = Date(timeIntervalSince1970: 1_800_000_000)

private func ejecucion(
    _ recipe: String = "reparto", recipes: [String]? = nil, outcome: RecipeRunOutcome = .ok, log: String = "hola",
    hace segundos: TimeInterval = 0
) -> RecipeTrace {
    RecipeTrace(
        recipe: recipe, name: recipe.capitalized, fingerprint: "abc", steps: [],
        logs: [RecipeLogLine(level: .info, text: log, origin: nil, seconds: 0)],
        error: outcome == .ok ? nil : "algo", outcome: outcome, recipes: recipes,
        startedAt: ahora.addingTimeInterval(-segundos), seconds: 1)
}

@Suite("Historial de ejecuciones de recetas")
struct EjecucionesTests {
    @Test("cada ejecucion queda guardada con su origen, y la nota ensena la ultima")
    func guardadas() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a")

        try await sandbox.store.saveRun(ejecucion(log: "primera", hace: 60), for: "a", trigger: .pipeline, now: ahora)
        try await sandbox.store.saveRun(ejecucion(log: "segunda"), for: "a", trigger: .reprocess, now: ahora)

        let todas = try sandbox.store.runs(RecipeRunFilter())
        #expect(todas.map(\.trace.logs.first?.text) == ["segunda", "primera"])
        #expect(todas.map(\.trigger) == [.reprocess, .pipeline])
        #expect(todas.map(\.recordingKey) == ["a", "a"])
        #expect(try await sandbox.store.latestTrace(for: "a")?.logs.first?.text == "segunda")
    }

    @Test("la traza de la nota es la de su ultima ejecucion de verdad, no la de una prueba")
    func pruebaNoCuenta() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a")

        try await sandbox.store.saveRun(ejecucion(log: "de verdad", hace: 60), for: "a", trigger: .pipeline, now: ahora)
        try await sandbox.store.saveRun(ejecucion(log: "prueba"), for: "a", trigger: .test, now: ahora)

        #expect(try await sandbox.store.latestTrace(for: "a")?.logs.first?.text == "de verdad")
        #expect(try sandbox.store.runs(RecipeRunFilter()).map(\.trigger) == [.test, .pipeline])
    }

    @Test("de las que esperan solo queda la ultima de cada nota y receta, para que un motor caido no llene el historial")
    func esperando() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a", "b")

        for segundos in [30.0, 20, 10] {
            try await sandbox.store.saveRun(
                ejecucion(outcome: .waiting, hace: segundos), for: "a", trigger: .pipeline, now: ahora)
        }
        try await sandbox.store.saveRun(ejecucion(outcome: .waiting), for: "b", trigger: .pipeline, now: ahora)
        try await sandbox.store.saveRun(ejecucion(outcome: .ok), for: "a", trigger: .pipeline, now: ahora)

        let deA = try sandbox.store.runs(RecipeRunFilter()).filter { $0.recordingKey == "a" }
        #expect(deA.map(\.trace.outcome) == [.ok, .waiting])
        #expect(deA.last?.startedAt == ahora.addingTimeInterval(-10))
        #expect(try sandbox.store.runs(RecipeRunFilter()).filter { $0.recordingKey == "b" }.count == 1)
    }

    @Test("se conservan 30 dias")
    func retencion() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a")

        try await sandbox.store.saveRun(ejecucion(log: "vieja", hace: 31 * 86_400), for: "a", trigger: .pipeline, now: ahora)
        try await sandbox.store.saveRun(ejecucion(log: "nueva"), for: "a", trigger: .pipeline, now: ahora)

        #expect(try sandbox.store.runs(RecipeRunFilter()).map(\.trace.logs.first?.text) == ["nueva"])
    }

    @Test("filtrar por receta incluye las ejecuciones en que la llamo otra")
    func porReceta() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a", "b")

        try await sandbox.store.saveRun(ejecucion("reparto", recipes: ["reparto", "F1"]), for: "a", trigger: .pipeline, now: ahora)
        try await sandbox.store.saveRun(ejecucion("F1", hace: 5), for: "b", trigger: .pipeline, now: ahora)

        #expect(try sandbox.store.runs(RecipeRunFilter(recipe: "F1")).map(\.recordingKey) == ["a", "b"])
        #expect(try sandbox.store.runs(RecipeRunFilter(recipe: "reparto")).map(\.recordingKey) == ["a"])
        #expect(try sandbox.store.runs(RecipeRunFilter(recipe: "nada")).isEmpty)
    }

    @Test("filtrar por resultado y por texto, en la nota o en el log")
    func porResultadoYTexto() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("reunion lunes", "idea")

        try await sandbox.store.saveRun(ejecucion(outcome: .failed, log: "sin conector"), for: "reunion lunes", trigger: .pipeline, now: ahora)
        try await sandbox.store.saveRun(ejecucion(log: "todo bien", hace: 5), for: "idea", trigger: .pipeline, now: ahora)

        #expect(try sandbox.store.runs(RecipeRunFilter(outcome: .failed)).map(\.recordingKey) == ["reunion lunes"])
        #expect(try sandbox.store.runs(RecipeRunFilter(text: "LUNES")).map(\.recordingKey) == ["reunion lunes"])
        #expect(try sandbox.store.runs(RecipeRunFilter(text: "todo bien")).map(\.recordingKey) == ["idea"])
        #expect(try sandbox.store.runs(RecipeRunFilter(limit: 1)).count == 1)
    }

    @Test("borrar la grabacion borra sus ejecuciones")
    func borrar() async throws {
        let sandbox = try Sandbox()
        let audio = sandbox.base.appending(path: "a.m4a")
        try Data("audio".utf8).write(to: audio)
        try sandbox.store.save(Recording(url: audio, startedAt: Date(), key: "a"), Transcript(text: "t"), backend: "wk")
        try await sandbox.store.saveRun(ejecucion(), for: "a", trigger: .pipeline, now: ahora)

        try sandbox.store.delete(key: "a")

        #expect(try sandbox.store.runs(RecipeRunFilter()).isEmpty)
    }

    @Test("la migracion pasa la traza que ya tenia cada nota al historial")
    func migracion() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-v8-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: base.appending(path: "library.sqlite").path(percentEncoded: false))
        try makeMigrator().migrate(queue, upTo: "v7-traza")
        let vieja = #"{"recipe":"por-defecto","fingerprint":"abc","steps":[],"logs":["hola"],"error":"se rompio"}"#
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO recording (key, sourcePath, audioPath, startedAt, importedAt, status) VALUES ('a', '/a.m4a', '', ?, ?, 'failed')",
                arguments: [ahora, ahora])
            try db.execute(
                sql: "INSERT INTO recipeTrace (recordingId, savedAt, payload) VALUES (1, ?, ?)", arguments: [ahora, vieja])
        }

        try makeMigrator().migrate(queue)
        let store = try Store(root: base)

        let runs = try store.runs(RecipeRunFilter())
        #expect(runs.map(\.recordingKey) == ["a"])
        #expect(runs.first?.trace.outcome == .failed)
        #expect(runs.first?.trace.logs.map(\.text) == ["hola"])
        #expect(runs.first?.startedAt == ahora)
        #expect(try store.runs(RecipeRunFilter(recipe: "por-defecto")).count == 1)
        #expect(try queue.read { db in try db.tableExists("recipeTrace") } == false)
    }
}
