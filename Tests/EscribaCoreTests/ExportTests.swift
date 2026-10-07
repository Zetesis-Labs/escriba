import Foundation
import Testing

@testable import EscribaCore

private let conversacion = Transcript(segments: [
    TranscriptSegment(
        start: 0, end: 1.5, speaker: "Ruben", text: "Hola.",
        words: [TranscriptWord(start: 0, end: 1.5, text: "Hola.")]),
    TranscriptSegment(start: 1.6, end: 3, speaker: "Ana", text: "Buenas."),
])

private func exportacion(_ transcript: Transcript, backend: String? = "whisperkit")
    -> TranscriptExport
{
    transcriptExport(
        key: "2026-08-31/10-00-00",
        startedAt: Date(timeIntervalSince1970: 1_788_170_400),
        source: URL(fileURLWithPath: "/audio/10-00-00.m4a"),
        backend: backend,
        transcript: transcript)
}

@Suite("Exportacion de una transcripcion")
struct ExportTests {
    @Test("lleva la grabacion entera: clave, origen, backend, duracion y hablantes")
    func contexto() {
        let export = exportacion(conversacion)

        #expect(export.key == "2026-08-31/10-00-00")
        #expect(export.source == "/audio/10-00-00.m4a")
        #expect(export.backend == "whisperkit")
        #expect(export.duration == 3)
        #expect(export.speakers == ["Ruben", "Ana"])
        #expect(export.segments == conversacion.segments)
    }

    @Test("una transcripcion sin segmentar conserva el texto plano y no inventa segmentos")
    func plana() {
        let export = exportacion(Transcript(text: "solo texto"))

        #expect(export.text == "solo texto")
        #expect(export.segments.isEmpty)
        #expect(export.speakers.isEmpty)
        #expect(export.duration == nil)
    }

    @Test("las palabras van agrupadas en su segmento, no en un bloque cada una")
    func palabrasAgrupadas() {
        func turno(palabras: Int) -> Transcript {
            Transcript(segments: [
                TranscriptSegment(
                    start: 0, end: 10, speaker: "Ruben", text: "da igual",
                    words: (0..<palabras).map {
                        TranscriptWord(start: Double($0), end: Double($0) + 1, text: "p\($0)")
                    })
            ])
        }

        #expect(
            exportacion(conversacion).json()
                .contains(#""words": [[0, 1.5, "Hola."]]"#))

        let cortas = exportacion(turno(palabras: 2)).json().split(separator: "\n").count
        let largas = exportacion(turno(palabras: 500)).json().split(separator: "\n").count
        #expect(cortas == largas)
    }

    @Test("cada segmento ocupa una sola linea")
    func segmentoPorLinea() {
        let lineas = exportacion(conversacion).json().split(separator: "\n")

        #expect(lineas.count(where: { $0.hasPrefix(#"    {"start""#) }) == 2)
    }

    @Test("el orden de los campos de cada palabra queda declarado en el propio JSON")
    func formatoDeclarado() {
        #expect(exportacion(conversacion).json()
            .contains(#""wordFormat": ["start", "end", "text"]"#))
    }

    @Test("sigue siendo JSON valido con comillas, saltos de linea y emoji dentro del texto")
    func valido() throws {
        let raro = Transcript(segments: [
            TranscriptSegment(
                start: 0, end: 1, speaker: #"Ana "la jefa""#,
                text: "dijo: \"vale\"\ny se fue 🎙",
                words: [TranscriptWord(start: 0, end: 1, text: #"vale""#)])
        ])

        let objeto = try JSONSerialization.jsonObject(with: Data(exportacion(raro).json().utf8))
        let segmentos = try #require((objeto as? [String: Any])?["segments"] as? [[String: Any]])

        #expect(segmentos.first?["speaker"] as? String == #"Ana "la jefa""#)
        #expect(segmentos.first?["text"] as? String == "dijo: \"vale\"\ny se fue 🎙")
    }

    @Test("la fecha va en ISO 8601 y el JSON es estable entre llamadas")
    func fecha() {
        let texto = exportacion(conversacion).json()

        #expect(texto.contains(#""startedAt": "2026-08-31T10:00:00Z""#))
        #expect(texto == exportacion(conversacion).json())
    }

    @Test("sin backend conocido el campo se omite en vez de mentir")
    func sinBackend() {
        #expect(!exportacion(conversacion, backend: nil).json().contains("\"backend\""))
    }
}

@Suite("Donde vive el .txt de una grabacion")
struct SidecarPathTests {
    private let raiz = URL(fileURLWithPath: "/Users/ruben/Documents/Transcripciones")

    @Test("la clave con carpeta se traduce a la misma ruta que escribe el sink")
    func ruta() {
        #expect(
            sidecarTextURL(outputRoot: raiz, key: "2026-08-31/10-00-00").path(percentEncoded: false)
                == "/Users/ruben/Documents/Transcripciones/2026-08-31/10-00-00.txt")
    }
}
