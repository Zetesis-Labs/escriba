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

    init(reprocess: Reprocessor? = nil, writeText: TranscriptWriter? = nil) throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
        model = LibraryModel(store: store, reprocess: reprocess, writeText: writeText)
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

nonisolated private final class ReprocessSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int?] = []

    var received: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func note(_ count: Int?) {
        lock.lock()
        defer { lock.unlock() }
        counts.append(count)
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

    @Test("reprocesar guarda el resultado como transcripcion vigente y pasa los hablantes pedidos")
    func reprocesa() async throws {
        let spy = ReprocessSpy()
        let sandbox = try Sandbox(reprocess: { _, count in
            spy.note(count)
            return Transcript(text: "reprocesada")
        })
        try sandbox.save("2026-08-31/13-00-00", text: "original")
        let recording = try #require(try sandbox.store.recordings().first)

        try await sandbox.model.reprocess(recording, speakers: 2)

        #expect(spy.received == [2])
        #expect(try await sandbox.model.transcript(for: recording.key)?.text == "reprocesada")
        #expect(sandbox.model.reprocessing.isEmpty)
    }

    @Test("un reprocesado que falla no toca la transcripcion vigente")
    func reprocesadoFallido() async throws {
        let sandbox = try Sandbox(reprocess: { _, _ in
            throw TranscriptionError.failed("audio corrupto")
        })
        try sandbox.save("2026-08-31/13-00-00", text: "original")
        let recording = try #require(try sandbox.store.recordings().first)

        await #expect(throws: TranscriptionError.self) {
            try await sandbox.model.reprocess(recording, speakers: nil)
        }
        #expect(try await sandbox.model.transcript(for: recording.key)?.text == "original")
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


private nonisolated final class Escrituras: Sendable {
    private let anotadas = Mutex<[(key: String, transcript: Transcript)]>([])

    func anota(_ key: String, _ transcript: Transcript) {
        anotadas.withLock { $0.append((key, transcript)) }
    }

    var todas: [(key: String, transcript: Transcript)] { anotadas.withLock { $0 } }
}

private struct FalloDeDisco: Error {}

private nonisolated let diarizada = Transcript(segments: [
    TranscriptSegment(start: 0, end: 1, speaker: "Ruben", text: "Hola."),
    TranscriptSegment(start: 1, end: 2, speaker: "Ana", text: "Buenas."),
])

@Suite("El .txt sigue a lo que dice la biblioteca")
struct SidecarRefreshTests {
    @Test("al reprocesar con hablantes, el .txt se reescribe con la version diarizada")
    func reprocesado() async throws {
        let escrituras = Escrituras()
        let sandbox = try Sandbox(
            reprocess: { _, _ in diarizada },
            writeText: { key, transcript in escrituras.anota(key, transcript) })
        try sandbox.save("2026-08-31/10-00-00", text: "sin hablantes")
        let fila = try #require(try sandbox.store.recordings().first)

        try await sandbox.model.reprocess(fila, speakers: 2)

        #expect(escrituras.todas.map(\.key) == ["2026-08-31/10-00-00"])
        #expect(escrituras.todas.first?.transcript == diarizada)
    }

    @Test("al renombrar o fusionar hablantes, el .txt tambien se reescribe")
    func correccion() async throws {
        let escrituras = Escrituras()
        let sandbox = try Sandbox(
            writeText: { key, transcript in escrituras.anota(key, transcript) })
        try sandbox.save("2026-08-31/10-00-00")

        let renombrada = diarizada.renaming("Speaker 1", to: "Ruben")
        try await sandbox.model.applyCorrection(renombrada, to: "2026-08-31/10-00-00")

        #expect(escrituras.todas.first?.transcript == renombrada)
    }

    @Test("si el .txt no se puede escribir, la transcripcion no se pierde")
    func discoQueFalla() async throws {
        let sandbox = try Sandbox(writeText: { _, _ in throw FalloDeDisco() })
        try sandbox.save("2026-08-31/10-00-00")

        try await sandbox.model.applyCorrection(diarizada, to: "2026-08-31/10-00-00")

        #expect(try await sandbox.store.transcript(for: "2026-08-31/10-00-00") == diarizada)
    }

    @Test("sin .txt configurado, reprocesar sigue funcionando")
    func sinSidecar() async throws {
        let sandbox = try Sandbox(reprocess: { _, _ in diarizada })
        try sandbox.save("2026-08-31/10-00-00")
        let fila = try #require(try sandbox.store.recordings().first)

        try await sandbox.model.reprocess(fila, speakers: nil)

        #expect(try await sandbox.store.transcript(for: "2026-08-31/10-00-00") == diarizada)
    }
}
