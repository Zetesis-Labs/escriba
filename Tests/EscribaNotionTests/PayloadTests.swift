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

    private func pagina(_ recording: Recording, _ transcript: Transcript) -> (title: String, blocks: [NotionBlock]) {
        let nota = Note(recording: recording, transcript: transcript)
        return (NoteValues(nota, timeZone: .gmt).title, notionBlocks(for: transcript, style: .speakers))
    }

    @Test("el titulo es el arranque del texto, cortado por palabra")
    func tituloDelTexto() {
        let transcript = Transcript(
            text: "Hola Aritz, te llamo por lo del contrato de la semana que viene y "
                + "por el asunto de las licencias que quedo pendiente ayer por la tarde")
        let pagina = pagina(grabacion(), transcript)

        #expect(pagina.title.count <= notionTitleLimit + 1)
        #expect(pagina.title.hasPrefix("Hola Aritz, te llamo por lo del contrato"))
        #expect(pagina.title.hasSuffix("…"))
        #expect(!pagina.title.contains("  "))
    }

    @Test("sin texto el titulo cae a la clave de la grabacion")
    func tituloSinTexto() {
        let pagina = pagina(grabacion(key: "2026-09-16 09-20-00"), Transcript(text: ""))

        #expect(pagina.title == "2026-09-16 09-20-00")
    }

    @Test("un texto corto no se corta ni lleva puntos suspensivos")
    func tituloCorto() {
        let pagina = pagina(grabacion(), Transcript(text: "Comprar pan"))

        #expect(pagina.title == "Comprar pan")
    }

    @Test("cada turno diarizado es un parrafo con el hablante en negrita")
    func parrafosPorTurno() {
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 2, speaker: "Ruben", text: "Buenos dias."),
            TranscriptSegment(start: 2, end: 4, speaker: "Ruben", text: "Te llamo por el envio."),
            TranscriptSegment(start: 4, end: 6, speaker: "Aritz", text: "Dime."),
        ])
        let pagina = pagina(grabacion(), transcript)

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
        let pagina = pagina(grabacion(), Transcript(text: "Primera linea\n\nSegunda linea"))

        #expect(pagina.blocks.map(\.plainText) == ["Primera linea", "Segunda linea"])
        #expect(pagina.blocks.allSatisfy { $0.runs.allSatisfy { !$0.bold } })
    }

    @Test("un turno mas largo que el limite se parte en varios parrafos sin cortar palabras")
    func troceadoPorLimite() {
        let palabra = String(repeating: "a", count: 99)
        let largo = Array(repeating: palabra, count: 60).joined(separator: " ")
        let pagina = pagina(grabacion(), Transcript(text: largo))

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
        let pagina = pagina(grabacion(), transcript)

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

    @Test("la pagina lleva la clave de la grabacion para reencontrarla")
    func clave() {
        let nota = Note(recording: grabacion(key: "clave-1"), transcript: Transcript(text: "Hola"))

        #expect(notionPage(for: nota, as: exportDe(), timeZone: .gmt).key == "clave-1")
    }
}
