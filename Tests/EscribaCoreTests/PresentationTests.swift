import Foundation
import Testing

@testable import EscribaCore

private func segment(_ speaker: String?, at start: TimeInterval) -> TranscriptSegment {
    TranscriptSegment(start: start, end: start + 1, speaker: speaker, text: "…")
}

@Suite("Marca de reloj")
struct ClockStampTests {
    @Test("segundos a m:ss con ceros a la izquierda")
    func formato() {
        #expect(clockStamp(0) == "0:00")
        #expect(clockStamp(5) == "0:05")
        #expect(clockStamp(65) == "1:05")
        #expect(clockStamp(3599) == "59:59")
        #expect(clockStamp(3600) == "60:00")
    }

    @Test("trunca los decimales y no pinta negativos")
    func bordes() {
        #expect(clockStamp(59.9) == "0:59")
        #expect(clockStamp(-3) == "0:00")
    }
}

@Suite("Hablante anterior en la transcripcion")
struct SpeakerBeforeTests {
    let transcript = Transcript(segments: [
        segment("Ana", at: 0), segment("Ana", at: 1), segment("Luis", at: 2), segment(nil, at: 3),
    ])

    @Test("el primer segmento no tiene anterior")
    func primero() {
        #expect(transcript.speaker(before: 0) == nil)
        #expect(transcript.startsNewSpeaker(at: 0))
    }

    @Test("solo cambia de hablante cuando el anterior es distinto")
    func cambios() {
        #expect(transcript.startsNewSpeaker(at: 1) == false)
        #expect(transcript.startsNewSpeaker(at: 2))
        #expect(transcript.speaker(before: 2) == "Ana")
        #expect(transcript.startsNewSpeaker(at: 3))
    }

    @Test("un indice fuera de rango no revienta")
    func fueraDeRango() {
        #expect(transcript.speaker(before: 99) == nil)
        #expect(transcript.startsNewSpeaker(at: 99) == false)
    }
}
