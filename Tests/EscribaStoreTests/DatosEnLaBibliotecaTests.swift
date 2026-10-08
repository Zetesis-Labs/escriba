import Foundation
import GRDB
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-datos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func recording(_ key: String) throws -> Recording {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return Recording(url: url, startedAt: Date(timeIntervalSince1970: 1_000_000), key: key)
    }
}

private let entradas = TranscriptionInputs(backend: "wk", options: TranscriptionOptions(language: "es"))

@Suite("Los datos propios y las respuestas viven en la versión")
struct DatosEnLaBibliotecaTests {
    @Test("los datos se guardan en su versión, en orden, y la memoria los devuelve con ella")
    func porVersion() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")
        let memoria = sandbox.store.memory()
        let v1 = try await memoria.keepTranscript(grabacion, Transcript(text: "uno"), entradas)
        let datos = try parseData(#"{"urgente":true,"cliente":"Acme","tareas":["a","b"]}"#)

        let esquema = try parseData(#"{"type":"object","properties":{"urgente":{"type":"boolean","title":"¿Urgente?"}}}"#)
        try await memoria.keepData(grabacion, v1, datos, esquema)

        #expect(try await memoria.recall(grabacion, entradas)?.data == datos)
        #expect(try sandbox.store.recordings().first?.transcript?.data == datos)
        #expect(try sandbox.store.recordings().first?.transcript?.dataSchema == esquema)

        try await sandbox.store.addTranscript(Transcript(text: "dos"), for: "a", backend: "otro")
        #expect(try sandbox.store.recordings().first?.transcript?.data == nil)
        try await sandbox.store.choose(version: v1, for: "a")
        #expect(try sandbox.store.recordings().first?.transcript?.data == datos)

        try await memoria.keepData(grabacion, v1, nil, esquema)
        #expect(try sandbox.store.recordings().first?.transcript?.data == nil)
        #expect(try sandbox.store.recordings().first?.transcript?.dataSchema == nil)
    }

    @Test("una respuesta se recuerda por versión y huella, y se va con su versión")
    func respuestas() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")
        let memoria = sandbox.store.memory()
        let v1 = try await memoria.keepTranscript(grabacion, Transcript(text: "uno"), entradas)

        try await memoria.keepAnswer(grabacion, v1, "h1", #"{"a":1}"#)
        try await memoria.keepAnswer(grabacion, v1, "h1", #"{"a":2}"#)

        #expect(try await memoria.recallAnswer(grabacion, v1, "h1") == #"{"a":2}"#)
        #expect(try await memoria.recallAnswer(grabacion, v1, "h2") == nil)
        #expect(try await memoria.recallAnswer(grabacion, v1 + 1, "h1") == nil)

        try sandbox.store.delete(key: "a")
        #expect(try await memoria.recallAnswer(grabacion, v1, "h1") == nil)
    }

    @Test("guardar datos en una versión que no es de esa grabación es un error")
    func versionAjena() async throws {
        let sandbox = try Sandbox()
        let memoria = sandbox.store.memory()
        let a = try sandbox.recording("a")
        let b = try sandbox.recording("b")
        let va = try await memoria.keepTranscript(a, Transcript(text: "a"), entradas)
        _ = try await memoria.keepTranscript(b, Transcript(text: "b"), entradas)

        await #expect(throws: StoreError.self) {
            try await memoria.keepData(b, va, .object([]), nil)
        }
    }

    @Test("la versión que guarda una receta pasa a ser la de la nota y el menú dice qué receta la hizo")
    func versionGuardada() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")
        let memoria = sandbox.store.memory()
        let v1 = try await memoria.keepTranscript(grabacion, Transcript(text: "uno"), entradas)
        _ = try await memoria.keepTranscript(
            grabacion, Transcript(text: "dos"),
            TranscriptionInputs(backend: "wk", options: TranscriptionOptions(language: "es", diarize: true)))

        try await memoria.keepSaved(grabacion, v1, "Análisis completo")

        let versiones = try await sandbox.store.versions(for: "a")
        #expect(versiones.first(where: \.isCurrent)?.id == v1)
        #expect(versiones[0].recipe == "Análisis completo")
        #expect(versiones[0].label == "v1 · Análisis completo · ES · sin hablantes")
        #expect(versiones[1].recipe == nil)
        #expect(try sandbox.store.recordings().first?.transcript?.version == 1)

        await #expect(throws: StoreError.self) {
            try await memoria.keepSaved(grabacion, v1 + 99, "x")
        }
    }

    @Test("la migración añade los datos sin tocar las versiones que ya había")
    func migracion() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-datos-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: base.appending(path: "library.sqlite").path(percentEncoded: false))
        try makeMigrator().migrate(queue, upTo: "v8-ejecuciones")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO recording (key, sourcePath, audioPath, startedAt, importedAt, status)
                VALUES ('a', '/a.m4a', 'audio/a.m4a', 0, 0, 'done');
                INSERT INTO transcript (recordingId, backend, createdAt, text, diarize, optionsKnown)
                VALUES (1, 'wk', 0, 'hola', 0, 0);
                """)
        }

        try makeMigrator().migrate(queue)

        try queue.read { db in
            #expect(try String.fetchOne(db, sql: "SELECT text FROM transcript") == "hola")
            let fila = try Row.fetchOne(db, sql: "SELECT data, dataSchema, recipe FROM transcript")
            #expect(fila?["data"] as String? == nil)
            #expect(fila?["dataSchema"] as String? == nil)
            #expect(fila?["recipe"] as String? == nil)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM answer") == 0)
        }
    }
}
