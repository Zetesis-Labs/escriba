import Foundation
import Testing
import EscribaCore

@testable import EscribaNotion

@Suite("Payload de Notion")
struct PayloadTests {
    private let momento = Date(timeIntervalSince1970: 1_758_000_000)

    private func grabacion(key: String = "2026-09-16 09-20-00") -> Recording {
        Recording(
            url: URL(fileURLWithPath: "/Notas/\(key).m4a"), startedAt: momento, key: key)
    }

    @Test("el titulo es el arranque del texto, cortado por palabra")
    func tituloDelTexto() {
        let transcript = Transcript(
            text: "Hola Aritz, te llamo por lo del contrato de la semana que viene y "
                + "por el asunto de las licencias que quedo pendiente ayer por la tarde")
        let pagina = notionPage(for: grabacion(), transcript: transcript)

        #expect(pagina.title.count <= notionTitleLimit + 1)
        #expect(pagina.title.hasPrefix("Hola Aritz, te llamo por lo del contrato"))
        #expect(pagina.title.hasSuffix("…"))
        #expect(!pagina.title.contains("  "))
    }

    @Test("sin texto el titulo cae a la clave de la grabacion")
    func tituloSinTexto() {
        let pagina = notionPage(for: grabacion(key: "2026-09-16 09-20-00"), transcript: Transcript(text: ""))

        #expect(pagina.title == "2026-09-16 09-20-00")
    }

    @Test("un texto corto no se corta ni lleva puntos suspensivos")
    func tituloCorto() {
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: "Comprar pan"))

        #expect(pagina.title == "Comprar pan")
    }

    @Test("cada turno diarizado es un parrafo con el hablante en negrita")
    func parrafosPorTurno() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 2, speaker: "Ruben", text: "Buenos dias."),
            TranscriptSegment(start: 2, end: 4, speaker: "Ruben", text: "Te llamo por el envio."),
            TranscriptSegment(start: 4, end: 6, speaker: "Aritz", text: "Dime."),
        ])
        let pagina = notionPage(for: grabacion(), transcript: transcript)

        #expect(pagina.blocks.count == 2)
        #expect(pagina.blocks[0].runs == [
            NotionRun(text: "Ruben: ", bold: true),
            NotionRun(text: "Buenos dias. Te llamo por el envio.", bold: false),
        ])
        #expect(pagina.blocks[1].runs == [
            NotionRun(text: "Aritz: ", bold: true),
            NotionRun(text: "Dime.", bold: false),
        ])
    }

    @Test("sin hablantes cada linea del texto es un parrafo")
    func parrafosSinHablantes() {
        let pagina = notionPage(
            for: grabacion(), transcript: Transcript(text: "Primera linea\n\nSegunda linea"))

        #expect(pagina.blocks.map(\.plainText) == ["Primera linea", "Segunda linea"])
        #expect(pagina.blocks.allSatisfy { $0.runs.allSatisfy { !$0.bold } })
    }

    @Test("un turno mas largo que el limite se parte en varios parrafos sin cortar palabras")
    func troceadoPorLimite() {
        let palabra = String(repeating: "a", count: 99)
        let largo = Array(repeating: palabra, count: 60).joined(separator: " ")
        let pagina = notionPage(for: grabacion(), transcript: Transcript(text: largo))

        #expect(pagina.blocks.count > 1)
        #expect(pagina.blocks.allSatisfy { $0.plainText.count <= notionTextLimit })
        #expect(pagina.blocks.flatMap { $0.plainText.split(separator: " ") }.allSatisfy { $0.count == 99 })
        #expect(pagina.blocks.map(\.plainText).joined(separator: " ") == largo)
    }

    @Test("el prefijo del hablante nunca se queda solo en un parrafo")
    func prefijoConTexto() {
        let largo = Array(repeating: String(repeating: "b", count: 99), count: 60)
            .joined(separator: " ")
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 1, speaker: "Ruben", text: largo)
        ])
        let pagina = notionPage(for: grabacion(), transcript: transcript)

        #expect(pagina.blocks.count > 1)
        #expect(pagina.blocks[0].runs.first == NotionRun(text: "Ruben: ", bold: true))
        #expect(pagina.blocks[0].runs.count == 2)
        #expect(pagina.blocks.dropFirst().allSatisfy { $0.runs.allSatisfy { !$0.bold } })
        #expect(pagina.blocks.allSatisfy { $0.plainText.count <= notionTextLimit })
    }

    @Test("los bloques van en tandas de cien como manda la API")
    func tandasDeCien() {
        let bloques = (0..<250).map { NotionBlock(runs: [NotionRun(text: "turno \($0)", bold: false)]) }

        #expect(notionBatches(bloques).map(\.count) == [100, 100, 50])
        #expect(notionBatches([]).isEmpty)
    }

    @Test("la pagina lleva clave, fecha, duracion, hablantes y origen")
    func propiedades() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 12, speaker: "Ruben", text: "Hola."),
            TranscriptSegment(start: 12, end: 30.5, speaker: "Aritz", text: "Adios."),
        ])
        let pagina = notionPage(for: grabacion(key: "clave-1"), transcript: transcript)

        #expect(pagina.key == "clave-1")
        #expect(pagina.startedAt == momento)
        #expect(pagina.speakers == ["Ruben", "Aritz"])
        #expect(pagina.duration == 30.5)
        #expect(pagina.source == "/Notas/clave-1.m4a")
    }
}
