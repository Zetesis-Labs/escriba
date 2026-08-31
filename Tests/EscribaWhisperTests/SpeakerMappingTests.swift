import Foundation
import SpeakerKit
import Testing
import WhisperKit

@testable import EscribaCore
@testable import EscribaWhisper

@Suite("Mapeo de hablantes")
struct SpeakerMappingTests {
    private func words(_ text: String, from start: Float, to end: Float) -> [SpeakerWordTiming] {
        [
            SpeakerWordTiming(
                wordTiming: WordTiming(
                    word: text, tokens: [], start: start, end: end, probability: 1),
                speaker: .speakerId(0))
        ]
    }

    @Test("cada hablante se etiqueta empezando en uno, no en cero")
    func etiquetas() {
        #expect(WhisperKitBackend.label(.speakerId(0)) == "Speaker 1")
        #expect(WhisperKitBackend.label(.speakerId(1)) == "Speaker 2")
    }

    @Test("un tramo con varias voces solapadas las nombra todas")
    func solapamiento() {
        #expect(WhisperKitBackend.label(.multiple([0, 2])) == "Speaker 1 + Speaker 3")
    }

    @Test("un tramo sin hablante identificado se queda sin etiqueta, no inventa una")
    func sinHablante() {
        #expect(WhisperKitBackend.label(.noMatch) == nil)
    }

    @Test("el texto sale de las palabras con hablante")
    func textoDesdePalabras() {
        let segment = SpeakerSegment(
            speaker: .speakerId(0), startTime: 0, endTime: 2, frameRate: 1,
            speakerWords: words(" Hola que tal", from: 0, to: 2))

        let transcript = WhisperKitBackend.transcript(speakerSegments: [segment])

        #expect(transcript.text == "Hola que tal")
        #expect(transcript.segments[0].speaker == "Speaker 1")
    }

    @Test("si no hay palabras con hablante cae a la transcripcion en vez de quedarse mudo")
    func caeATranscripcion() {
        let segment = SpeakerSegment(
            speaker: .speakerId(1), startTime: 0, endTime: 2, frameRate: 1,
            transcription: TranscriptionSegment(start: 0, end: 2, text: " Texto de respaldo"),
            speakerWords: [])

        let transcript = WhisperKitBackend.transcript(speakerSegments: [segment])

        #expect(transcript.text == "Texto de respaldo")
        #expect(transcript.segments[0].speaker == "Speaker 2")
    }

    @Test("las palabras conservan sus tiempos: el karaoke sigue vivo tras diarizar")
    func palabrasConTiempos() {
        let segment = SpeakerSegment(
            speaker: .speakerId(0), startTime: 0, endTime: 2, frameRate: 1,
            speakerWords: [
                SpeakerWordTiming(
                    wordTiming: WordTiming(
                        word: " Hola", tokens: [], start: 0.25, end: 0.5, probability: 1),
                    speaker: .speakerId(0)),
                SpeakerWordTiming(
                    wordTiming: WordTiming(
                        word: " que", tokens: [], start: 0.75, end: 1.5, probability: 1),
                    speaker: .speakerId(0)),
            ])

        let transcript = WhisperKitBackend.transcript(speakerSegments: [segment])

        #expect(transcript.segments[0].words == [
            TranscriptWord(start: 0.25, end: 0.5, text: "Hola"),
            TranscriptWord(start: 0.75, end: 1.5, text: "que"),
        ])
    }

    @Test("un tramo sin nada de texto se descarta")
    func tramoMudo() {
        let segment = SpeakerSegment(
            speaker: .speakerId(0), startTime: 0, endTime: 1, frameRate: 1, speakerWords: [])

        #expect(WhisperKitBackend.transcript(speakerSegments: [segment]).segments.isEmpty)
    }
}
