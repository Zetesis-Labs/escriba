import Foundation
import Synchronization
import Testing

@testable import EscribaModel
@testable import EscribaCore
import EscribaEngine
import EscribaSystemKit
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store
    let model: LibraryModel

    init(reprocess: RecipeRunner? = nil) throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
        model = LibraryModel(store: store, reprocess: reprocess)
    }

    func save(_ key: String, text: String = "hola") throws {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        let recording = Recording(url: url, startedAt: Date(), key: key)
        try store.save(recording, Transcript(text: text), backend: "falso")
    }
}

private func waitUntil(
    _ comment: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("timeout esperando: \(comment)")
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }
}

private let salida = URL(fileURLWithPath: "/tmp/x.txt")

@Suite("Modelo de la biblioteca")
struct LibraryModelTests {
    @Test("observa el store: lo guardado aparece en la lista sin recargar nada")
    func observa() async throws {
        let sandbox = try Sandbox()
        sandbox.model.startObserving()
        try await waitUntil("estado inicial") { sandbox.model.recordings.isEmpty == false || true }

        try sandbox.save("2026-08-31/10-00-00")

        try await waitUntil("la grabacion llega") {
            sandbox.model.recordings.map(\.key) == ["2026-08-31/10-00-00"]
        }
    }

    @Test("los eventos del pipeline mueven el estado del vigilante")
    func estados() async throws {
        let sandbox = try Sandbox()
        #expect(sandbox.model.status == .starting)

        await sandbox.model.apply(.passStarted(pending: 2))
        #expect(sandbox.model.status == .working(pending: 2))

        await sandbox.model.apply(.transcribed(key: "k", transcript: Transcript(text: "t"), output: salida))
        #expect(sandbox.model.status == .watching)

        await sandbox.model.apply(.idle(scanned: 7))
        #expect(sandbox.model.status == .watching)
        #expect(sandbox.model.scanned == 7)
    }

    @Test("un problema se queda a la vista: un ciclo tranquilo no lo tapa")
    func problemaPersistente() async throws {
        let sandbox = try Sandbox()

        await sandbox.model.apply(.failed(key: "k", reason: "audio corrupto"))
        guard case .problem = sandbox.model.status else {
            Issue.record("esperaba .problem, hay \(sandbox.model.status)")
            return
        }

        await sandbox.model.apply(.transcribed(key: "otra", transcript: Transcript(text: "t"), output: salida))
        guard case .problem = sandbox.model.status else {
            Issue.record("una transcripcion ajena no debe borrar el problema, hay \(sandbox.model.status)")
            return
        }

        await sandbox.model.apply(.idle(scanned: 3))
        guard case .problem = sandbox.model.status else {
            Issue.record("el idle tapo el problema")
            return
        }

        await sandbox.model.apply(.passStarted(pending: 1))
        await sandbox.model.apply(.transcribed(key: "k", transcript: Transcript(text: "t"), output: salida))
        #expect(sandbox.model.status == .watching)
    }

    @Test("el detalle de una grabacion sale del store")
    func detalle() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("2026-08-31/10-00-00", text: "el contenido")

        #expect(try await sandbox.model.transcript(for: "2026-08-31/10-00-00")?.text == "el contenido")
        #expect(try await sandbox.model.transcript(for: "no/existe") == nil)
    }
}

@Suite("Correcciones y reprocesado desde el modelo")
struct LibraryCorrectionTests {
    @Test("una correccion de hablantes persiste y pasa a ser la vigente")
    func correccion() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("2026-08-31/13-00-00", text: "hola")
        let original = try #require(try await sandbox.model.transcript(for: "2026-08-31/13-00-00"))

        let corregida = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, speaker: "Ruben", text: original.text)
        ])
        try await sandbox.model.applyCorrection(corregida, to: "2026-08-31/13-00-00")

        #expect(try await sandbox.model.transcript(for: "2026-08-31/13-00-00") == corregida)
    }

    @Test("reprocesar ejecuta la receta elegida, con sus parametros retocados, y guarda su traza")
    func reprocesa() async throws {
        let elegidas = Mutex<[RecipeChoice]>([])
        let traza = RecipeTrace(recipe: "F2", name: "Reuniones", fingerprint: "abc", steps: [], logs: [], error: nil)
        let sandbox = try Sandbox(reprocess: { _, eleccion, prueba in
            #expect(!prueba)
            elegidas.withLock { $0.append(eleccion) }
            return RecipeRunReport(trace: traza, failure: nil)
        })
        try sandbox.save("2026-08-31/13-00-00", text: "original")
        let recording = try #require(try sandbox.store.recordings().first)
        let eleccion = RecipeChoice(recipe: "F2", parameters: .standard)

        try await sandbox.model.reprocess(recording, with: eleccion)

        #expect(elegidas.withLock { $0 } == [eleccion])
        #expect(try await sandbox.model.latestTrace(for: recording.key) == traza)
        #expect(sandbox.model.traceRevision(for: recording.key) == 1)
        #expect(sandbox.model.reprocessing.isEmpty)
    }

    @Test("probar ejecuta la receta sin efectos, queda como prueba y no cambia la traza de la nota")
    func probar() async throws {
        let traza = RecipeTrace(recipe: "F2", name: "Reuniones", fingerprint: "abc", steps: [], logs: [], error: nil)
        let sandbox = try Sandbox(reprocess: { _, eleccion, prueba in
            #expect(prueba)
            #expect(eleccion == RecipeChoice(recipe: "F2"))
            return RecipeRunReport(trace: traza, failure: nil)
        })
        try sandbox.save("2026-08-31/13-00-00", text: "original")
        let recording = try #require(try sandbox.store.recordings().first)

        let resultado = await sandbox.model.test(recording, recipe: "F2")

        #expect(resultado == RecipeRunReport(trace: traza, failure: nil))
        #expect(try sandbox.store.runs(RecipeRunFilter()).map(\.trigger) == [.test])
        #expect(try await sandbox.model.latestTrace(for: recording.key) == nil)
        #expect(sandbox.model.testing.isEmpty)
    }

    @Test("un reprocesado que falla guarda la traza, no toca la transcripcion vigente y lo dice")
    func reprocesadoFallido() async throws {
        let traza = RecipeTrace(recipe: "F1", fingerprint: "abc", steps: [], logs: [], error: "audio corrupto")
        let sandbox = try Sandbox(reprocess: { _, _, _ in RecipeRunReport(trace: traza, failure: "audio corrupto") })
        try sandbox.save("2026-08-31/13-00-00", text: "original")
        let recording = try #require(try sandbox.store.recordings().first)

        await #expect(throws: LibraryModelError.recipeFailed("audio corrupto")) {
            try await sandbox.model.reprocess(recording)
        }
        #expect(try await sandbox.model.transcript(for: recording.key)?.text == "original")
        #expect(try await sandbox.model.latestTrace(for: recording.key) == traza)
        #expect(sandbox.model.reprocessing.isEmpty)
    }
}

@Suite("El modelo refleja los estados del pipeline en la biblioteca")
struct LibraryStatusTests {
    private func makeRecording(_ sandbox: Sandbox, _ key: String) throws -> Recording {
        let url = sandbox.base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return Recording(url: url, startedAt: Date(timeIntervalSince1970: 1_000), key: key)
    }

    @Test("lo escaneado aparece como pendiente en la biblioteca")
    func escaneado() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")

        await sandbox.model.apply(.scanned(recordings: [recording]))

        #expect(try sandbox.store.recordings().first?.status == .pending)
    }

    @Test("al empezar a transcribir pasa a procesando")
    func procesando() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        await sandbox.model.apply(.scanned(recordings: [recording]))

        await sandbox.model.apply(.transcribing(key: recording.key))

        #expect(try sandbox.store.recordings().first?.status == .processing)
    }

    @Test("un fallo del pipeline queda anotado con su motivo")
    func fallo() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        await sandbox.model.apply(.scanned(recordings: [recording]))

        await sandbox.model.apply(.failed(key: recording.key, reason: "se rompio"))

        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.status == .failed)
        #expect(fila.lastError == "se rompio")
        #expect(sandbox.model.status == .problem(recording.key))
    }

    @Test("cuando el sink guarda, un transcribing rezagado no la devuelve a procesando")
    func hechoNoRetrocede() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        await sandbox.model.apply(.scanned(recordings: [recording]))
        try sandbox.store.save(recording, Transcript(text: "lista"), backend: "falso")

        await sandbox.model.apply(.transcribing(key: recording.key))

        #expect(try sandbox.store.recordings().first?.status == .done)
    }

    @Test("la traza de una receta llega a la biblioteca y el detalle la ve")
    func traza() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        await sandbox.model.apply(.scanned(recordings: [recording]))
        let traza = RecipeTrace(
            recipe: "por-defecto", fingerprint: "abc123",
            steps: [RecipeStep(capability: "transcribir", detail: nil, seconds: 1, error: nil)],
            logs: [], error: nil)

        await sandbox.model.apply(.traced(key: recording.key, trace: traza))

        #expect(try await sandbox.model.latestTrace(for: recording.key) == traza)
    }

    @Test("cada traza que llega avisa al detalle de su grabacion, aunque la nota ya estuviera hecha")
    func trazaAvisa() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        try sandbox.store.save(recording, Transcript(text: "t"), backend: "falso")
        let traza = RecipeTrace(recipe: "por-defecto", fingerprint: "abc123", steps: [], logs: [], error: nil)
        let antes = sandbox.model.traceRevision(for: recording.key)

        await sandbox.model.apply(.traced(key: recording.key, trace: traza))
        await sandbox.model.apply(.traced(key: recording.key, trace: traza))

        #expect(sandbox.model.traceRevision(for: recording.key) == antes + 2)
        #expect(sandbox.model.traceRevision(for: "otra") == 0)
    }

    @Test("una nota reintentada con lo que ya estaba guardado vuelve a quedar hecha")
    func reintentoRecordado() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        await sandbox.model.apply(.scanned(recordings: [recording]))
        try sandbox.store.save(recording, Transcript(text: "lista"), backend: "falso")
        await sandbox.model.apply(.failed(key: recording.key, reason: "no se pudo escribir el .txt"))
        await sandbox.model.apply(.transcribing(key: recording.key))

        await sandbox.model.apply(.transcribed(key: recording.key, transcript: Transcript(text: "lista"), output: salida))

        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.status == .done)
        #expect(fila.lastError == nil)
    }

    @Test("una nota terminada no resucita si se borro mientras se procesaba")
    func terminadaTrasBorrar() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        try sandbox.store.save(recording, Transcript(text: "t"), backend: "falso")
        try await sandbox.model.discard(recording.key)

        await sandbox.model.apply(.transcribed(key: recording.key, transcript: Transcript(text: "t"), output: salida))

        #expect(try sandbox.store.recording(for: recording.key)?.status == .discarded)
    }

    @Test("descartar avisa al pipeline con la clave y el origen, para que no la vuelva a procesar")
    func descartarAvisa() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        try sandbox.store.save(recording, Transcript(text: "t"), backend: "falso")
        let avisadas = Mutex<[String]>([])
        let modelo = LibraryModel(store: sandbox.store, discarded: { key, origen in
            avisadas.withLock { $0.append("\(key)|\(origen.lastPathComponent)") }
        })

        try await modelo.discard(recording.key)

        #expect(avisadas.withLock { $0 } == ["2026-08-31/09-00-00|09-00-00.m4a"])
        #expect(try sandbox.store.discardedRecordings().map(\.key) == ["2026-08-31/09-00-00"])
    }

    @Test("borrar desde el modelo esconde la fila y el siguiente escaneo no la devuelve")
    func borrar() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        try sandbox.store.save(recording, Transcript(text: "t"), backend: "falso")

        try await sandbox.model.discard(recording.key)
        #expect(try sandbox.store.recordings().isEmpty)

        await sandbox.model.apply(.scanned(recordings: [recording]))
        #expect(try sandbox.store.recordings().isEmpty)
    }

    @Test("quitar el audio desde el modelo conserva la transcripcion")
    func quitarAudio() async throws {
        let sandbox = try Sandbox()
        let recording = try makeRecording(sandbox, "2026-08-31/09-00-00")
        try sandbox.store.save(recording, Transcript(text: "t"), backend: "falso")

        try await sandbox.model.removeAudio(recording.key)

        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.audio == .sourceOnly)
        #expect(try await sandbox.model.transcript(for: recording.key)?.text == "t")
    }
}



