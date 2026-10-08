import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let modelo = "pyannote-v3"

private let conversacion = Transcript(
    segments: [
        TranscriptSegment(start: 0, end: 5, speaker: "Speaker 1", text: "hola"),
        TranscriptSegment(start: 5, end: 9, speaker: "Speaker 2", text: "qué tal"),
    ],
    voices: [
        SpeakerVoice(speaker: "Speaker 1", embedding: [0, 1], model: modelo),
        SpeakerVoice(speaker: "Speaker 2", embedding: [1, 0.01], model: modelo),
    ])

private let ruben = KnownVoice(person: "Rubén", embedding: [1, 0], model: modelo)

@Suite("Reconocer a las personas al transcribir")
struct ReconocerTests {
    @Test("lo recién transcrito sale con el nombre de quien casa, marcado como reconocido, y así se guarda")
    func reconoce() async throws {
        let memoria = MemoryNotes()
        memoria.know([ruben])
        let capacidades = Capabilities(backend: backend { _ in conversacion }, enrich: nil, memory: memoria.port)

        let toma = try await capacidades.transcribe(recording("a"))

        #expect(toma.transcript.speakers == ["Speaker 1", "Rubén"])
        #expect(toma.transcript.recognitions.map(\.person) == ["Rubén"])
        #expect(memoria.kept("a")?.transcript == toma.transcript)
    }

    @Test("una voz lejos de todas las conocidas se queda como estaba")
    func lejos() async throws {
        let memoria = MemoryNotes()
        memoria.know([KnownVoice(person: "Nuria", embedding: [-1, -1], model: modelo)])
        let capacidades = Capabilities(backend: backend { _ in conversacion }, enrich: nil, memory: memoria.port)

        #expect(try await capacidades.transcribe(recording("a")).transcript == conversacion)
    }

    @Test("lo que ya estaba en la biblioteca no se vuelve a reconocer")
    func recuperado() async throws {
        let memoria = MemoryNotes()
        memoria.remember("a", conversacion)
        memoria.know([ruben])
        let capacidades = Capabilities(backend: backend { _ in conversacion }, enrich: nil, memory: memoria.port)

        #expect(try await capacidades.transcribe(recording("a")).transcript == conversacion)
    }

    @Test("si las personas no se pueden leer, falla en vez de guardar la nota sin nombres")
    func sinPersonas() async {
        let memoria = MemoryNotes()
        memoria.breakKnown()
        let capacidades = Capabilities(backend: backend { _ in conversacion }, enrich: nil, memory: memoria.port)

        await #expect(throws: FakeError.memoryDown) { try await capacidades.transcribe(recording("a")) }
        #expect(memoria.count == 0)
    }

    @Test("una transcripción sin huellas no pregunta por las personas")
    func sinHuellas() async throws {
        let memoria = MemoryNotes()
        memoria.breakKnown()
        let capacidades = Capabilities(
            backend: backend { _ in Transcript(text: "hola") }, enrich: nil, memory: memoria.port)

        #expect(try await capacidades.transcribe(recording("a")).transcript == Transcript(text: "hola"))
    }
}
