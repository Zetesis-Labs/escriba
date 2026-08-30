import Foundation
import Testing

@testable import JPRCore
@testable import JPRKit
@testable import JPRStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func recording(
        _ key: String, contents: String = "audio", startedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) throws -> Recording {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return Recording(url: url, startedAt: startedAt, key: key)
    }
}

private let conversacion = Transcript(segments: [
    TranscriptSegment(
        start: 0, end: 1.5, speaker: "Speaker 1", text: "Hola, que tal.",
        words: [
            TranscriptWord(start: 0, end: 0.4, text: "Hola,"),
            TranscriptWord(start: 0.5, end: 1.5, text: "que tal."),
        ]),
    TranscriptSegment(
        start: 1.6, end: 3, speaker: "Speaker 2", text: "Bien.",
        words: [TranscriptWord(start: 1.6, end: 3, text: "Bien.")]),
])

@Suite("Store: biblioteca de grabaciones y transcripciones")
struct StoreTests {
    @Test("guarda una transcripcion y la devuelve intacta, con hablantes y palabras")
    func idaYVuelta() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00")

        try sandbox.store.save(recording, conversacion, backend: "falso")

        #expect(try sandbox.store.transcript(for: "2026-08-29/10-00-00") == conversacion)
    }

    @Test("una transcripcion sin segmentar vuelve sin segmentar")
    func sinSegmentar() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00")

        try sandbox.store.save(recording, Transcript(text: "solo texto"), backend: "falso")
        let leida = try sandbox.store.transcript(for: "2026-08-29/10-00-00")

        #expect(leida == Transcript(text: "solo texto"))
        #expect(leida?.isSegmented == false)
    }

    @Test("una clave que no existe devuelve nil, no un error")
    func claveInexistente() throws {
        let sandbox = try Sandbox()

        #expect(try sandbox.store.transcript(for: "no/existe") == nil)
    }

    @Test("copia el audio dentro de la biblioteca y guarda la ruta")
    func copiaElAudio() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00", contents: "contenido del audio")

        try sandbox.store.save(recording, conversacion, backend: "falso")
        let guardada = try #require(try sandbox.store.recordings().first)

        #expect(guardada.audioURL.path().hasPrefix(sandbox.store.root.path()))
        #expect(guardada.audioURL.pathExtension == "m4a")
        #expect(try String(contentsOf: guardada.audioURL, encoding: .utf8) == "contenido del audio")
        #expect(guardada.sourceURL == recording.url)
        #expect(guardada.startedAt == recording.startedAt)
    }

    @Test("guardar la misma clave dos veces no duplica la grabacion y la ultima transcripcion gana")
    func reprocesado() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00")

        try sandbox.store.save(recording, Transcript(text: "primera"), backend: "falso")
        try sandbox.store.save(recording, Transcript(text: "segunda"), backend: "falso")

        #expect(try sandbox.store.recordings().count == 1)
        #expect(try sandbox.store.transcript(for: "2026-08-29/10-00-00")?.text == "segunda")
    }

    @Test("reprocesar desde la propia copia no la destruye")
    func reprocesarDesdeLaCopia() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00", contents: "original")
        try sandbox.store.save(recording, Transcript(text: "primera"), backend: "falso")
        let copia = try #require(try sandbox.store.recordings().first).audioURL
        try FileManager.default.removeItem(at: recording.url)

        let desdeLaCopia = Recording(url: copia, startedAt: recording.startedAt, key: recording.key)
        try sandbox.store.save(desdeLaCopia, Transcript(text: "segunda"), backend: "falso")

        #expect(try String(contentsOf: copia, encoding: .utf8) == "original")
        #expect(try sandbox.store.transcript(for: recording.key)?.text == "segunda")
    }

    @Test("lista de mas reciente a mas antigua por fecha de grabacion")
    func orden() throws {
        let sandbox = try Sandbox()
        let vieja = try sandbox.recording("2026-08-28/09-00-00", startedAt: Date(timeIntervalSince1970: 100))
        let nueva = try sandbox.recording("2026-08-29/09-00-00", startedAt: Date(timeIntervalSince1970: 200))

        try sandbox.store.save(vieja, Transcript(text: "a"), backend: "falso")
        try sandbox.store.save(nueva, Transcript(text: "b"), backend: "falso")

        #expect(try sandbox.store.recordings().map(\.key) == [nueva.key, vieja.key])
        #expect(try sandbox.store.count() == 2)
    }

    @Test("borrar una grabacion arrastra su audio, sus transcripciones y sus segmentos")
    func borrado() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00")
        try sandbox.store.save(recording, conversacion, backend: "falso")
        let copia = try #require(try sandbox.store.recordings().first).audioURL

        try sandbox.store.delete(key: recording.key)

        #expect(try sandbox.store.recordings().isEmpty)
        #expect(try sandbox.store.transcript(for: recording.key) == nil)
        #expect(!FileManager.default.fileExists(atPath: copia.path()))
        #expect(try sandbox.store.orphanRows() == 0)
    }

    @Test("la observacion entrega el estado inicial y se entera de cada grabacion nueva")
    func observacion() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00")
        var cambios = sandbox.store.observeRecordings().makeAsyncIterator()

        let inicial = try await cambios.next()
        try sandbox.store.save(recording, conversacion, backend: "falso")
        let tras = try await cambios.next()

        #expect(inicial?.isEmpty == true)
        #expect(tras?.map(\.key) == [recording.key])
    }

    @Test("el sink del store devuelve la ruta del audio copiado")
    func sink() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-29/10-00-00")

        let salida = try sandbox.store.sink(backend: "falso")(recording, conversacion)
        let copia = try sandbox.store.recordings().first?.audioURL

        #expect(salida == copia)
        #expect(try sandbox.store.transcript(for: recording.key) == conversacion)
    }
}
