import Foundation
import Testing

@testable import JPRCore

private let transcript = Transcript(segments: [
    TranscriptSegment(
        start: 0.0, end: 2.0, speaker: "Speaker 1", text: "Hola, mundo",
        words: [
            TranscriptWord(start: 0.0, end: 0.5, text: "Hola,"),
            TranscriptWord(start: 0.9, end: 1.4, text: "mundo"),
        ]),
    TranscriptSegment(
        start: 2.5, end: 4.0, speaker: "Speaker 2", text: "Bien.",
        words: [TranscriptWord(start: 2.6, end: 3.0, text: "Bien.")]),
])

@Suite("Que palabra suena en cada instante")
struct PlaybackPositionTests {
    @Test("en mitad de una palabra, esa palabra")
    func enMitadDeUnaPalabra() {
        #expect(transcript.position(at: 0.2) == PlaybackPosition(segment: 0, word: 0))
        #expect(transcript.position(at: 3.5) == PlaybackPosition(segment: 1, word: 0))
    }

    @Test("en un silencio entre palabras, se queda la anterior")
    func silencioEntrePalabras() {
        #expect(transcript.position(at: 0.7) == PlaybackPosition(segment: 0, word: 0))
        #expect(transcript.position(at: 1.6) == PlaybackPosition(segment: 0, word: 1))
    }

    @Test("segmento empezado pero antes de su primera palabra: segmento sin palabra")
    func segmentoSinPalabraTodavia() {
        #expect(transcript.position(at: 2.55) == PlaybackPosition(segment: 1, word: nil))
    }

    @Test("antes del primer segmento no hay posicion")
    func antesDelPrincipio() {
        #expect(transcript.position(at: -1) == nil)
    }

    @Test("pasado el final, la ultima palabra")
    func pasadoElFinal() {
        #expect(transcript.position(at: 10) == PlaybackPosition(segment: 1, word: 0))
    }

    @Test("un segmento sin palabras se senala entero")
    func segmentoSinPalabras() {
        let sinPalabras = Transcript(segments: [
            TranscriptSegment(start: 0, end: 3, speaker: "Speaker 1", text: "Hola"),
            TranscriptSegment(start: 3, end: 6, speaker: "Speaker 2", text: "Adios"),
        ])
        #expect(sinPalabras.position(at: 4.2) == PlaybackPosition(segment: 1, word: nil))
    }

    @Test("una transcripcion sin segmentos no tiene posiciones")
    func sinSegmentos() {
        #expect(Transcript(text: "plano").position(at: 1) == nil)
    }
}
