import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaKit
@testable import EscribaStore

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

@Suite("Store: correcciones sobre lo ya guardado")
struct StoreCorrectionTests {
    @Test("una correccion se guarda como transcripcion nueva y pasa a ser la vigente")
    func correccion() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/12-00-00")
        try sandbox.store.save(recording, conversacion, backend: "falso")

        let corregida = conversacion.renaming("Speaker 1", to: "Ruben")
        try sandbox.store.addTranscript(corregida, for: recording.key, backend: "correccion")

        #expect(try sandbox.store.transcript(for: recording.key) == corregida)
        #expect(try sandbox.store.transcriptCount(for: recording.key) == 2)
    }

    @Test("corregir una clave que no existe falla con un error claro, no en silencio")
    func claveInexistente() throws {
        let sandbox = try Sandbox()

        #expect(throws: StoreError.self) {
            try sandbox.store.addTranscript(
                Transcript(text: "x"), for: "no/existe", backend: "correccion")
        }
    }
}

@Suite("Store: estados de trabajo")
struct StoreStatusTests {
    @Test("lo escaneado se registra como pendiente, sin copia de audio y reproducible desde el origen")
    func registro() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")

        try sandbox.store.register([recording])
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(fila.status == .pending)
        #expect(fila.audioURL == recording.url)
        #expect(try sandbox.store.transcript(for: recording.key) == nil)
    }

    @Test("registrar es idempotente y no pisa lo que ya esta en la biblioteca")
    func registroNoPisa() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.save(recording, Transcript(text: "hecho"), backend: "falso")

        try sandbox.store.register([recording])
        try sandbox.store.register([recording])
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(try sandbox.store.recordings().count == 1)
        #expect(fila.status == .done)
        #expect(try sandbox.store.transcript(for: recording.key)?.text == "hecho")
    }

    @Test("el ciclo pendiente -> procesando -> hecho deja la fila limpia y con su audio")
    func cicloCompleto() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")

        try sandbox.store.register([recording])
        try sandbox.store.markProcessing(recording.key)
        #expect(try sandbox.store.recordings().first?.status == .processing)

        try sandbox.store.save(recording, Transcript(text: "lista"), backend: "falso")
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(fila.status == .done)
        #expect(fila.lastError == nil)
        #expect(fila.audioURL.path().hasPrefix(sandbox.store.root.path()))
    }

    @Test("marcar en proceso no toca lo que ya esta hecho")
    func procesandoNoTocaHecho() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.save(recording, Transcript(text: "hecha"), backend: "falso")

        try sandbox.store.markProcessing(recording.key)

        #expect(try sandbox.store.recordings().first?.status == .done)
    }

    @Test("un fallo guarda el motivo y un exito posterior lo limpia")
    func falloYRecuperacion() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.register([recording])

        try sandbox.store.markFailed(recording.key, error: "se rompio")
        let fallida = try #require(try sandbox.store.recordings().first)
        #expect(fallida.status == .failed)
        #expect(fallida.lastError == "se rompio")

        try sandbox.store.save(recording, Transcript(text: "al final si"), backend: "falso")
        let recuperada = try #require(try sandbox.store.recordings().first)
        #expect(recuperada.status == .done)
        #expect(recuperada.lastError == nil)
    }

    @Test("los procesando huerfanos vuelven a pendiente; lo hecho no se toca")
    func resetInterrumpidos() throws {
        let sandbox = try Sandbox()
        let colgada = try sandbox.recording("2026-08-31/09-00-00")
        let hecha = try sandbox.recording("2026-08-31/10-00-00")
        try sandbox.store.register([colgada])
        try sandbox.store.markProcessing(colgada.key)
        try sandbox.store.save(hecha, Transcript(text: "x"), backend: "falso")

        try sandbox.store.resetInterrupted()

        let porClave = Dictionary(
            uniqueKeysWithValues: try sandbox.store.recordings().map { ($0.key, $0.status) })
        #expect(porClave[colgada.key] == .pending)
        #expect(porClave[hecha.key] == .done)
    }

    @Test("una transcripcion manual sobre una pendiente la marca como hecha")
    func manualSobrePendiente() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.register([recording])

        try sandbox.store.addTranscript(
            Transcript(text: "a mano"), for: recording.key, backend: "reprocesado")

        #expect(try sandbox.store.recordings().first?.status == .done)
        #expect(try sandbox.store.transcript(for: recording.key)?.text == "a mano")
    }
}

@Suite("Store: resumen para la UI")
struct StoreSummaryTests {
    @Test("una diarizada resume backend, tiempos y numero de hablantes")
    func diarizada() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")

        try sandbox.store.save(recording, conversacion, backend: "falso")
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(
            fila.transcript
                == TranscriptSummary(backend: "falso", isSegmented: true, speakerCount: 2))
        #expect(fila.audio == .libraryCopy)
    }

    @Test("una de solo texto resume sin tiempos ni hablantes")
    func plana() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")

        try sandbox.store.save(recording, Transcript(text: "plano"), backend: "importado")
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(
            fila.transcript
                == TranscriptSummary(backend: "importado", isSegmented: false, speakerCount: 0))
    }

    @Test("una pendiente no tiene resumen y su audio vive en el origen")
    func pendiente() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")

        try sandbox.store.register([recording])
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(fila.transcript == nil)
        #expect(fila.audio == .sourceOnly)
    }

    @Test("sin copia y sin origen, el audio consta como perdido")
    func perdido() throws {
        let sandbox = try Sandbox()
        let recording = Recording(
            url: URL(fileURLWithPath: "/ya/no/existe.m4a"),
            startedAt: Date(timeIntervalSince1970: 1_000),
            key: "2026-08-31/09-00-00")

        try sandbox.store.insertDoneWithoutAudio(
            recording, Transcript(text: "huerfana"), backend: "importado")

        #expect(try sandbox.store.recordings().first?.audio == .missing)
    }
}

@Suite("Store: quitar audio y borrar filas")
struct StoreCleanupTests {
    @Test("quitar el audio borra la copia y conserva la transcripcion")
    func quitarAudio() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.save(recording, conversacion, backend: "falso")
        let copia = try #require(try sandbox.store.recordings().first).audioURL

        try sandbox.store.removeAudio(key: recording.key)
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(!FileManager.default.fileExists(atPath: copia.path(percentEncoded: false)))
        #expect(fila.audio == .sourceOnly)
        #expect(fila.status == .done)
        #expect(try sandbox.store.transcript(for: recording.key) == conversacion)
    }

    @Test("quitar el audio cuando el origen ya no existe deja solo la transcripcion")
    func quitarAudioSinOrigen() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.save(recording, conversacion, backend: "falso")
        try FileManager.default.removeItem(at: recording.url)

        try sandbox.store.removeAudio(key: recording.key)
        let fila = try #require(try sandbox.store.recordings().first)

        #expect(fila.audio == .missing)
        #expect(try sandbox.store.transcript(for: recording.key) == conversacion)
    }

    @Test("borrar esconde la fila, borra audio y transcripciones, y el re-escaneo no la resucita")
    func borrado() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.save(recording, conversacion, backend: "falso")
        let copia = try #require(try sandbox.store.recordings().first).audioURL

        try sandbox.store.discard(key: recording.key)

        #expect(try sandbox.store.recordings().isEmpty)
        #expect(try sandbox.store.count() == 0)
        #expect(try sandbox.store.transcript(for: recording.key) == nil)
        #expect(!FileManager.default.fileExists(atPath: copia.path(percentEncoded: false)))
        #expect(try sandbox.store.orphanRows() == 0)

        try sandbox.store.register([recording])
        #expect(try sandbox.store.recordings().isEmpty)
    }

    @Test("una transcripcion tardia del pipeline no resucita una fila borrada")
    func borradoNoResucita() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-08-31/09-00-00")
        try sandbox.store.register([recording])
        try sandbox.store.discard(key: recording.key)

        try sandbox.store.save(recording, conversacion, backend: "falso")
        try sandbox.store.markProcessing(recording.key)
        try sandbox.store.markFailed(recording.key, error: "tarde")

        #expect(try sandbox.store.recordings().isEmpty)
        #expect(try sandbox.store.status(for: recording.key) == .discarded)
    }

    @Test("el backfill del ledger tampoco resucita una fila borrada")
    func backfillNoResucita() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-05-15/18-17-28")
        try sandbox.store.register([recording])
        try sandbox.store.discard(key: recording.key)
        let txt = sandbox.base.appending(path: "salida/18-17-28.txt")
        try FileManager.default.createDirectory(
            at: txt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "texto viejo".write(to: txt, atomically: true, encoding: .utf8)

        let adopted = sandbox.store.adoptLedgerHistory([
            LedgerRecord(
                key: recording.key,
                sourcePath: recording.url.path(percentEncoded: false),
                outputPath: txt.path(percentEncoded: false))
        ])

        #expect(adopted == 0)
        #expect(try sandbox.store.recordings().isEmpty)
    }
}

@Suite("Store: importar la historia del ledger")
struct StoreBackfillTests {
    @Test("importa lo hecho con su texto, copia el audio y saca la fecha de la clave")
    func importa() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-05-15/18-17-28", contents: "audio viejo")
        let txt = sandbox.base.appending(path: "salida/18-17-28.txt")
        try FileManager.default.createDirectory(
            at: txt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "el texto antiguo\n".write(to: txt, atomically: true, encoding: .utf8)

        let adopted = sandbox.store.adoptLedgerHistory([
            LedgerRecord(
                key: recording.key,
                sourcePath: recording.url.path(percentEncoded: false),
                outputPath: txt.path(percentEncoded: false))
        ])

        #expect(adopted == 1)
        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.status == .done)
        #expect(fila.audioURL.path().hasPrefix(sandbox.store.root.path()))
        #expect(fila.startedAt == RecordingParser.startDate(fromKey: recording.key))
        #expect(try sandbox.store.transcript(for: recording.key)?.text == "el texto antiguo")
    }

    @Test("sin fichero de salida no hay nada que importar")
    func sinSalida() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-05-15/18-17-28")

        let adopted = sandbox.store.adoptLedgerHistory([
            LedgerRecord(
                key: recording.key,
                sourcePath: recording.url.path(percentEncoded: false),
                outputPath: nil),
            LedgerRecord(
                key: "otro/2026-05-16/09-00-00",
                sourcePath: recording.url.path(percentEncoded: false),
                outputPath: "/no/existe.txt"),
        ])

        #expect(adopted == 0)
        #expect(try sandbox.store.recordings().isEmpty)
    }

    @Test("si el audio de origen ya no existe, importa el texto igualmente")
    func sinAudio() throws {
        let sandbox = try Sandbox()
        let txt = sandbox.base.appending(path: "salida/18-17-28.txt")
        try FileManager.default.createDirectory(
            at: txt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "texto huerfano".write(to: txt, atomically: true, encoding: .utf8)

        let adopted = sandbox.store.adoptLedgerHistory([
            LedgerRecord(
                key: "2026-05-15/18-17-28",
                sourcePath: "/ya/no/existe.m4a",
                outputPath: txt.path(percentEncoded: false))
        ])

        #expect(adopted == 1)
        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.status == .done)
        #expect(fila.audioURL == URL(fileURLWithPath: "/ya/no/existe.m4a"))
        #expect(try sandbox.store.transcript(for: "2026-05-15/18-17-28")?.text == "texto huerfano")
    }

    @Test("una fila ya registrada como pendiente se adopta igualmente")
    func adoptaPendientes() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-05-15/18-17-28", contents: "audio viejo")
        try sandbox.store.register([recording])
        let txt = sandbox.base.appending(path: "salida/18-17-28.txt")
        try FileManager.default.createDirectory(
            at: txt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "rescatado".write(to: txt, atomically: true, encoding: .utf8)

        let adopted = sandbox.store.adoptLedgerHistory([
            LedgerRecord(
                key: recording.key,
                sourcePath: recording.url.path(percentEncoded: false),
                outputPath: txt.path(percentEncoded: false))
        ])

        #expect(adopted == 1)
        let fila = try #require(try sandbox.store.recordings().first)
        #expect(fila.status == .done)
        #expect(fila.audioURL.path().hasPrefix(sandbox.store.root.path()))
        #expect(try sandbox.store.transcript(for: recording.key)?.text == "rescatado")
    }

    @Test("lo que ya esta en la biblioteca no se toca")
    func noPisa() throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("2026-05-15/18-17-28")
        try sandbox.store.save(recording, Transcript(text: "vigente"), backend: "falso")
        let txt = sandbox.base.appending(path: "salida/18-17-28.txt")
        try FileManager.default.createDirectory(
            at: txt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "texto viejo".write(to: txt, atomically: true, encoding: .utf8)

        let adopted = sandbox.store.adoptLedgerHistory([
            LedgerRecord(
                key: recording.key,
                sourcePath: recording.url.path(percentEncoded: false),
                outputPath: txt.path(percentEncoded: false))
        ])

        #expect(adopted == 0)
        #expect(try sandbox.store.recordings().count == 1)
        #expect(try sandbox.store.transcript(for: recording.key)?.text == "vigente")
    }
}
