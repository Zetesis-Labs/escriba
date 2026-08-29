import Foundation
import Testing
import WhisperKit

@testable import JPRCore
@testable import JPRWhisperKit

@Suite("Mapeo de WhisperKit a Transcript")
struct MappingTests {
    @Test("los segundos en Float se conservan como TimeInterval")
    func tiempos() {
        let transcript = WhisperKitBackend.transcript(
            segments: [
                TranscriptionSegment(start: 0.52, end: 6.5, text: " Primera frase."),
                TranscriptionSegment(start: 8.46, end: 16.58, text: " Segunda frase."),
            ],
            fallbackText: "")

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].start == 0.5199999809265137)
        #expect(transcript.duration != nil)
        #expect(transcript.text == "Primera frase.\nSegunda frase.")
    }

    @Test("recoge los tiempos por palabra")
    func palabras() {
        let transcript = WhisperKitBackend.transcript(
            segments: [
                TranscriptionSegment(
                    start: 0, end: 1, text: " Hola",
                    words: [
                        WordTiming(word: " Hola", tokens: [], start: 0.1, end: 0.4, probability: 1)
                    ])
            ],
            fallbackText: "")

        #expect(transcript.segments[0].words.count == 1)
        #expect(transcript.segments[0].words[0].text == " Hola")
    }

    @Test("los tokens especiales del modelo no acaban en la transcripcion")
    func tokensEspeciales() {
        let transcript = WhisperKitBackend.transcript(
            segments: [
                TranscriptionSegment(
                    start: 0, end: 6.66,
                    text: "<|startoftranscript|><|es|><|transcribe|><|0.00|> Quiero proponer.<|6.66|>")
            ],
            fallbackText: "")

        #expect(transcript.text == "Quiero proponer.")
    }

    @Test("un segmento que solo son tokens no genera una linea vacia")
    func segmentoVacio() {
        let transcript = WhisperKitBackend.transcript(
            segments: [
                TranscriptionSegment(start: 0, end: 1, text: "<|endoftext|>"),
                TranscriptionSegment(start: 1, end: 2, text: " Hola."),
            ],
            fallbackText: "")

        #expect(transcript.text == "Hola.")
    }

    @Test("sin segmentos cae al texto plano en vez de quedarse vacio")
    func sinSegmentos() {
        let transcript = WhisperKitBackend.transcript(segments: [], fallbackText: "  texto suelto ")

        #expect(transcript.text == "texto suelto")
        #expect(!transcript.isSegmented)
    }
}
