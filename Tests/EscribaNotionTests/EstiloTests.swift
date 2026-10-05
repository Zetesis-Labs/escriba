import Foundation
import Testing
import EscribaCore

@testable import EscribaNotion

@Suite("Estilos de cuerpo")
struct EstiloTests {
    private let diarizada = Transcript(segments: [
        TranscriptSegment(start: 0, end: 2, speaker: "Ruben", text: "Buenos dias."),
        TranscriptSegment(start: 2, end: 4, speaker: "Ruben", text: "Te llamo por el envio."),
        TranscriptSegment(start: 75, end: 80, speaker: "Aritz", text: "Dime."),
    ])

    @Test("solo el texto ignora los hablantes")
    func soloTexto() {
        let bloques = notionBlocks(for: diarizada, style: .plain)

        #expect(bloques.map(\.plainText) == ["Buenos dias. Te llamo por el envio.", "Dime."])
        #expect(bloques.allSatisfy { $0.runs.allSatisfy { !$0.bold } })
    }

    @Test("por hablante pone el nombre en negrita")
    func porHablante() {
        let bloques = notionBlocks(for: diarizada, style: .speakers)

        #expect(bloques.map(\.plainText) == [
            "Ruben: Buenos dias. Te llamo por el envio.", "Aritz: Dime.",
        ])
    }

    @Test("con marca de tiempo el turno arranca en el minuto de su primer segmento")
    func conMarca() {
        let bloques = notionBlocks(for: diarizada, style: .timestamps)

        #expect(bloques.map(\.plainText) == [
            "[00:00] Ruben: Buenos dias. Te llamo por el envio.", "[01:15] Aritz: Dime.",
        ])
    }

    @Test("sin segmentos la marca de tiempo no inventa nada")
    func sinSegmentos() {
        let bloques = notionBlocks(for: Transcript(text: "Comprar pan"), style: .timestamps)

        #expect(bloques.map(\.plainText) == ["Comprar pan"])
    }

    @Test("la marca crece a horas cuando hace falta")
    func horas() {
        #expect(bracketStamp(0) == "[00:00]")
        #expect(bracketStamp(75) == "[01:15]")
        #expect(bracketStamp(3600) == "[1:00:00]")
        #expect(bracketStamp(3725.9) == "[1:02:05]")
    }
}
