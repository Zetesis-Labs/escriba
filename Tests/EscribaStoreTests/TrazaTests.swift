import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-traza-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func register(_ key: String) async throws {
        try await store.register([
            Recording(url: base.appending(path: "\(key).m4a"), startedAt: Date(), key: key),
        ])
    }
}

private func traza(_ error: String? = nil, logs: [String] = []) -> RecipeTrace {
    RecipeTrace(
        recipe: "por-defecto", fingerprint: "abc123",
        steps: [
            RecipeStep(capability: "transcribir", detail: nil, seconds: 1.5, error: nil),
            RecipeStep(capability: "publicar", detail: "notion", seconds: 0.4, error: "sin red"),
        ],
        logs: logs.map { RecipeLogLine(level: .info, text: $0, origin: nil, seconds: 0) }, error: error)
}

@Suite("La biblioteca guarda como se proceso cada nota")
struct TrazaTests {
    @Test("guarda la traza de una pasada y la devuelve intacta")
    func idaYVuelta() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a")

        try await sandbox.store.saveTrace(traza(logs: ["hola"]), for: "a")

        #expect(try await sandbox.store.latestTrace(for: "a") == traza(logs: ["hola"]))
    }

    @Test("de varias pasadas devuelve la ultima")
    func laUltima() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a")

        try await sandbox.store.saveTrace(traza("primera fallo"), for: "a")
        try await sandbox.store.saveTrace(traza(), for: "a")

        #expect(try await sandbox.store.latestTrace(for: "a")?.error == nil)
    }

    @Test("una grabacion sin pasadas no tiene traza")
    func sinTraza() async throws {
        let sandbox = try Sandbox()
        try await sandbox.register("a")

        #expect(try await sandbox.store.latestTrace(for: "a") == nil)
    }

    @Test("la traza de una grabacion que no esta en la biblioteca es un error, no se pierde en silencio")
    func grabacionDesconocida() async throws {
        let sandbox = try Sandbox()

        await #expect(throws: StoreError.self) { try await sandbox.store.saveTrace(traza(), for: "nadie") }
    }

    @Test("borrar la grabacion borra sus trazas")
    func borrar() async throws {
        let sandbox = try Sandbox()
        let audio = sandbox.base.appending(path: "a.m4a")
        try Data("audio".utf8).write(to: audio)
        try sandbox.store.save(Recording(url: audio, startedAt: Date(), key: "a"), Transcript(text: "t"), backend: "wk")
        try await sandbox.store.saveTrace(traza(), for: "a")

        try sandbox.store.delete(key: "a")
        try await sandbox.register("a")

        #expect(try await sandbox.store.latestTrace(for: "a") == nil)
    }
}
