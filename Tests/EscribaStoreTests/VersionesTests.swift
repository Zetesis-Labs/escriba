import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-versiones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func recording(_ key: String) throws -> Recording {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return Recording(url: url, startedAt: Date(timeIntervalSince1970: 1_000_000), key: key)
    }
}

private let es = TranscriptionOptions(language: "es")
private let dos = TranscriptionOptions(language: "es", diarize: true, speakerCount: 2)

@Suite("Versiones de una transcripcion")
struct VersionesTests {
    @Test("cada reprocesado es una version nueva, numerada desde la original y con sus criterios")
    func numeracion() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        try sandbox.store.save(recording, Transcript(text: "v1"), backend: "wk", options: es)
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk", options: dos)

        let versiones = try await sandbox.store.versions(for: "a")

        #expect(versiones.map(\.number) == [1, 2])
        #expect(versiones.map(\.options) == [es, dos])
        #expect(versiones.map(\.isCurrent) == [false, true])
    }

    @Test("la vigente es la ultima hasta que el usuario elige otra")
    func elegir() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        try sandbox.store.save(recording, Transcript(text: "v1"), backend: "wk", options: es)
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk", options: dos)
        let primera = try #require(try await sandbox.store.versions(for: "a").first)

        try await sandbox.store.choose(version: primera.id, for: "a")

        #expect(try await sandbox.store.transcript(for: "a")?.text == "v1")
        #expect(try await sandbox.store.versions(for: "a").map(\.isCurrent) == [true, false])
        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.transcript?.version == 1)
        #expect(fila.transcript?.versionCount == 2)
    }

    @Test("una transcripcion nueva vuelve a ser la vigente aunque hubiera una elegida a mano")
    func nuevaGana() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        try sandbox.store.save(recording, Transcript(text: "v1"), backend: "wk", options: es)
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk", options: dos)
        let primera = try #require(try await sandbox.store.versions(for: "a").first)
        try await sandbox.store.choose(version: primera.id, for: "a")

        try await sandbox.store.addTranscript(Transcript(text: "v3"), for: "a", backend: "correccion")

        #expect(try await sandbox.store.transcript(for: "a")?.text == "v3")
        #expect(try await sandbox.store.versions(for: "a").map(\.isCurrent) == [false, false, true])
    }

    @Test("se puede leer cualquier version sin cambiar la vigente")
    func leerOtra() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        try sandbox.store.save(recording, Transcript(text: "v1"), backend: "wk", options: es)
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk", options: dos)
        let primera = try #require(try await sandbox.store.versions(for: "a").first)

        #expect(try await sandbox.store.transcript(for: "a", version: primera.id)?.text == "v1")
        #expect(try await sandbox.store.transcript(for: "a")?.text == "v2")
    }

    @Test("elegir una version que no es de esa grabacion falla en vez de cruzar datos")
    func versionAjena() async throws {
        let sandbox = try Sandbox()
        try sandbox.store.save(try sandbox.recording("a"), Transcript(text: "a1"), backend: "wk")
        try sandbox.store.save(try sandbox.recording("b"), Transcript(text: "b1"), backend: "wk")
        let deB = try #require(try await sandbox.store.versions(for: "b").first)

        await #expect(throws: StoreError.self) {
            try await sandbox.store.choose(version: deB.id, for: "a")
        }
    }

    @Test("reprocesar con todo en automatico guarda criterios, no los deja como desconocidos")
    func automaticos() async throws {
        let sandbox = try Sandbox()
        try sandbox.store.save(try sandbox.recording("a"), Transcript(text: "v1"), backend: "wk", options: .automatic)

        let versiones = try await sandbox.store.versions(for: "a")

        #expect(versiones[0].options == .automatic)
        #expect(versiones[0].label == "v1 · idioma automático · sin hablantes")
    }

    @Test("una biblioteca que corrio la v5 sin la marca de criterios la recibe al abrirse de nuevo")
    func migracionIntermedia() async throws {
        let sandbox = try Sandbox()
        try sandbox.store.save(try sandbox.recording("a"), Transcript(text: "v1"), backend: "wk", options: es)
        try await sandbox.store.writer.write { db in
            try db.execute(sql: "ALTER TABLE transcript DROP COLUMN optionsKnown")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5b-criterios-conocidos'")
        }

        let reabierto = try Store(root: sandbox.base.appending(path: "library"))

        let versiones = try await reabierto.versions(for: "a")
        #expect(versiones.count == 1)
        #expect(try await reabierto.transcript(for: "a")?.text == "v1")
    }

    @Test("una version guardada sin criterios (de antes) se lista con criterios desconocidos")
    func sinCriterios() async throws {
        let sandbox = try Sandbox()
        try sandbox.store.save(try sandbox.recording("a"), Transcript(text: "v1"), backend: "wk")

        let versiones = try await sandbox.store.versions(for: "a")

        #expect(versiones.count == 1)
        #expect(versiones[0].options == nil)
        #expect(versiones[0].backend == "wk")
    }
}
