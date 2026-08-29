import Foundation
import Testing

@testable import JPRCore

@Suite("Modelo de transcripcion")
struct TranscriptTests {
    private func segment(
        _ start: TimeInterval, _ end: TimeInterval, _ text: String, speaker: String? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speaker: speaker, text: text, words: [])
    }

    @Test("el texto plano se deriva de los segmentos, en orden y separados por linea")
    func textoDerivado() {
        let transcript = Transcript(segments: [
            segment(0.5, 6.5, "primera frase"),
            segment(8.4, 16.5, "segunda frase"),
        ])

        #expect(transcript.text == "primera frase\nsegunda frase")
        #expect(transcript.isSegmented)
    }

    @Test("una transcripcion sin segmentar conserva su texto y no inventa segmentos")
    func sinSegmentar() {
        let transcript = Transcript(text: "solo texto")

        #expect(transcript.text == "solo texto")
        #expect(transcript.segments.isEmpty)
        #expect(!transcript.isSegmented)
        #expect(transcript.duration == nil)
    }

    @Test("la duracion es el final del ultimo segmento")
    func duracion() {
        let transcript = Transcript(segments: [
            segment(0.5, 6.5, "a"),
            segment(8.4, 16.58, "b"),
        ])

        #expect(transcript.duration == 16.58)
    }

    @Test("los hablantes salen sin repetir y en orden de aparicion")
    func hablantes() {
        let transcript = Transcript(segments: [
            segment(0, 1, "a", speaker: "Speaker 1"),
            segment(1, 2, "b", speaker: "Speaker 2"),
            segment(2, 3, "c", speaker: "Speaker 1"),
        ])

        #expect(transcript.speakers == ["Speaker 1", "Speaker 2"])
    }

    @Test("sin diarizacion no se reporta ningun hablante")
    func sinHablantes() {
        let transcript = Transcript(segments: [segment(0, 1, "a")])

        #expect(transcript.speakers.isEmpty)
    }

    @Test("una transcripcion vacia no rompe nada")
    func vacia() {
        let transcript = Transcript(segments: [])

        #expect(transcript.text.isEmpty)
        #expect(transcript.duration == nil)
        #expect(!transcript.isSegmented)
    }
}

@Suite("Texto con hablantes")
struct RenderedTranscriptTests {
    private func segment(_ text: String, _ speaker: String?) -> TranscriptSegment {
        TranscriptSegment(start: 0, end: 1, speaker: speaker, text: text)
    }

    @Test("sin diarizacion se escribe el texto tal cual")
    func sinHablantes() {
        let transcript = Transcript(segments: [segment("una", nil), segment("dos", nil)])

        #expect(transcript.rendered == "una\ndos")
    }

    @Test("los tramos seguidos del mismo hablante se juntan en una intervencion")
    func agrupaConsecutivos() {
        let transcript = Transcript(segments: [
            segment("Hola,", "Speaker 1"),
            segment("que tal.", "Speaker 1"),
        ])

        #expect(transcript.rendered == "Speaker 1: Hola, que tal.")
    }

    @Test("cada cambio de hablante abre una intervencion nueva")
    func alternancia() {
        let transcript = Transcript(segments: [
            segment("Hola.", "Speaker 1"),
            segment("Buenas.", "Speaker 2"),
            segment("Vamos alla.", "Speaker 1"),
        ])

        #expect(transcript.rendered == """
            Speaker 1: Hola.
            Speaker 2: Buenas.
            Speaker 1: Vamos alla.
            """)
    }

    @Test("un tramo sin hablante identificado va sin etiqueta")
    func tramoSinEtiqueta() {
        let transcript = Transcript(segments: [
            segment("Ruido.", nil),
            segment("Hola.", "Speaker 1"),
        ])

        #expect(transcript.rendered == "Ruido.\nSpeaker 1: Hola.")
    }
}

@Suite("Correccion de hablantes")
struct SpeakerCorrectionTests {
    private func segment(_ text: String, _ speaker: String?, at start: TimeInterval)
        -> TranscriptSegment
    {
        TranscriptSegment(
            start: start, end: start + 1, speaker: speaker, text: text,
            words: [TranscriptWord(start: start, end: start + 1, text: text)])
    }

    private var llamada: Transcript {
        Transcript(segments: [
            segment("Hola, digame.", "Speaker 1", at: 0),
            segment("Queria informacion.", "Speaker 2", at: 1),
            segment("Le paso con el area.", "Speaker 3", at: 2),
        ])
    }

    @Test("fusionar dos hablantes reetiqueta sus tramos")
    func fusiona() {
        let corregida = llamada.merging(["Speaker 3"], into: "Speaker 1")

        #expect(corregida.speakers == ["Speaker 1", "Speaker 2"])
        #expect(corregida.segments[2].speaker == "Speaker 1")
    }

    @Test("al fusionar, los turnos que quedan seguidos se agrupan en uno")
    func reagrupaTurnos() {
        let corregida = Transcript(segments: [
            segment("Hola.", "Speaker 1", at: 0),
            segment("Un momento.", "Speaker 3", at: 1),
        ]).merging(["Speaker 3"], into: "Speaker 1")

        #expect(corregida.rendered == "Speaker 1: Hola. Un momento.")
    }

    @Test("fusionar conserva tiempos y palabras")
    func conservaDatos() {
        let corregida = llamada.merging(["Speaker 3"], into: "Speaker 1")

        #expect(corregida.segments[2].start == 2)
        #expect(corregida.segments[2].end == 3)
        #expect(corregida.segments[2].words.count == 1)
    }

    @Test("renombrar un hablante le pone nombre real")
    func renombra() {
        let corregida = llamada.renaming("Speaker 2", to: "Ruben")

        #expect(corregida.speakers == ["Speaker 1", "Ruben", "Speaker 3"])
    }

    @Test("fusionar un hablante que no existe no toca nada")
    func hablanteInexistente() {
        #expect(llamada.merging(["Speaker 9"], into: "Speaker 1") == llamada)
    }

    @Test("sobre una transcripcion sin diarizar no hay nada que corregir")
    func sinDiarizar() {
        let plana = Transcript(text: "solo texto")

        #expect(plana.merging(["Speaker 1"], into: "Speaker 2") == plana)
    }
}
