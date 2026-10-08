import Foundation
import Testing

@testable import EscribaModel
@testable import EscribaCore
import EscribaEngine
@testable import EscribaStore

private let modelo = "pyannote-v3"

private func voz(_ hablante: String, _ huella: [Float]) -> SpeakerVoice {
    SpeakerVoice(speaker: hablante, embedding: huella, model: modelo)
}

private let conversacion = Transcript(
    segments: [
        TranscriptSegment(start: 0, end: 5, speaker: "Speaker 1", text: "hola"),
        TranscriptSegment(start: 5, end: 9, speaker: "Speaker 2", text: "qué tal"),
    ],
    voices: [voz("Speaker 1", [1, 0]), voz("Speaker 2", [0, 1])])

private struct Sandbox {
    let base: URL
    let store: Store
    let model: LibraryModel

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-personas-modelo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
        model = LibraryModel(store: store)
    }

    func save(_ key: String, _ transcript: Transcript = conversacion) throws {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        try store.save(Recording(url: url, startedAt: Date(), key: key), transcript, backend: "falso")
    }
}

@Suite("Personas desde la biblioteca")
struct PersonasModelTests {
    @Test("bautizar a un hablante lo renombra en la nota y guarda su huella con ese nombre")
    func bautizar() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("a")

        let bautizo = try await sandbox.model.baptize("Speaker 2", as: " Nuria ", in: "a")
        let corregida = bautizo.transcript

        #expect(bautizo.learnedVoices == 1)
        #expect(corregida.speakers == ["Speaker 1", "Nuria"])
        #expect(try await sandbox.store.transcript(for: "a") == corregida)
        #expect(try sandbox.store.knownVoices() == [KnownVoice(person: "Nuria", embedding: [0, 1], model: modelo)])
        #expect(try sandbox.store.people().first?.voices.map(\.source) == ["a"])
    }

    @Test("fusionar un hablante con una persona conocida le suma su huella; con quien no es persona, solo fusiona")
    func fusionar() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("a")
        try sandbox.save("b")
        _ = try await sandbox.model.baptize("Speaker 1", as: "Rubén", in: "a")

        let fusionada = try await sandbox.model.merge("Speaker 1", into: "Speaker 2", in: "b").transcript
        _ = try await sandbox.model.baptize("Speaker 2", as: "Rubén", in: "b")

        #expect(fusionada.speakers == ["Speaker 2"])
        #expect(try sandbox.store.people().map(\.name) == ["Rubén"])
        #expect(try sandbox.store.knownVoices().map(\.embedding) == [[1, 0], [1, 0], [0, 1]])
    }

    @Test("fusionar con alguien que ya es persona cuenta como bautizar")
    func fusionarConPersona() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("a")
        _ = try await sandbox.model.baptize("Speaker 1", as: "Rubén", in: "a")

        let fusion = try await sandbox.model.merge("Speaker 2", into: "Rubén", in: "a")

        #expect(fusion.learnedVoices == 1)
        #expect(fusion.transcript.speakers == ["Rubén"])
        #expect(try sandbox.store.knownVoices().map(\.embedding) == [[1, 0], [0, 1]])
    }

    @Test("deshacer un reconocimiento devuelve la etiqueta de antes y no toca a las personas")
    func deshacer() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("a", conversacion.recognizing([Recognition(speaker: "Speaker 2", person: "Nuria", distance: 0.2)]))
        try await sandbox.store.addVoices([voz("x", [0, 1])], to: "Nuria", source: "z")

        let deshecha = try await sandbox.model.forgetRecognition(of: "Nuria", in: "a")

        #expect(deshecha == conversacion)
        #expect(try await sandbox.store.transcript(for: "a") == conversacion)
        #expect(try sandbox.store.knownVoices().count == 1)
    }

    @Test("renombrar a quien se reconoció mal es bautizarlo con el nombre bueno")
    func corregirReconocido() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("a", conversacion.recognizing([Recognition(speaker: "Speaker 2", person: "Nuria", distance: 0.2)]))

        let corregida = try await sandbox.model.baptize("Nuria", as: "Ana", in: "a").transcript

        #expect(corregida.speakers == ["Speaker 1", "Ana"])
        #expect(corregida.recognitions.isEmpty)
        #expect(try sandbox.store.knownVoices().map(\.person) == ["Ana"])
    }

    @Test("bautizar en una grabación sin huellas renombra pero dice que no ha aprendido ninguna voz")
    func sinHuellas() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("a", Transcript(segments: conversacion.segments))

        let bautizo = try await sandbox.model.baptize("Speaker 1", as: "Rubén", in: "a")

        #expect(bautizo.learnedVoices == 0)
        #expect(bautizo.transcript.speakers == ["Rubén", "Speaker 2"])
        #expect(try sandbox.store.people().isEmpty)
    }

    @Test("un nombre vacío no bautiza a nadie")
    func nombreVacio() async throws {
        let sandbox = try Sandbox()
        try sandbox.save("a")

        await #expect(throws: LibraryModelError.emptyName) {
            try await sandbox.model.baptize("Speaker 1", as: "  ", in: "a")
        }
        #expect(try await sandbox.store.transcript(for: "a") == conversacion)
    }

    @Test("sin nota no hay nada que bautizar")
    func sinNota() async throws {
        let sandbox = try Sandbox()

        await #expect(throws: LibraryModelError.unknownRecording) {
            try await sandbox.model.baptize("Speaker 1", as: "Rubén", in: "nada")
        }
    }
}
