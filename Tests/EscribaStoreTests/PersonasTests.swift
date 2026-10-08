import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-personas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func recording(_ key: String) throws -> Recording {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return Recording(url: url, startedAt: Date(timeIntervalSince1970: 1_000_000), key: key)
    }
}

private let modelo = "pyannote-v3"

private func voz(_ hablante: String, _ huella: [Float]) -> SpeakerVoice {
    SpeakerVoice(speaker: hablante, embedding: huella, model: modelo)
}

private let conversacion = Transcript(
    segments: [
        TranscriptSegment(start: 0, end: 5, speaker: "Speaker 1", text: "hola"),
        TranscriptSegment(start: 5, end: 9, speaker: "Speaker 2", text: "qué tal"),
    ],
    voices: [voz("Speaker 1", [0.25, -1.5, 3]), voz("Speaker 2", [1, 0, 0])])

@Suite("Huellas y personas en la biblioteca")
struct PersonasTests {
    @Test("las huellas y lo reconocido de una versión se guardan y se leen con ella")
    func porVersion() async throws {
        let sandbox = try Sandbox()
        let reconocida = conversacion.recognizing([Recognition(speaker: "Speaker 2", person: "Nuria", distance: 0.25)])

        try sandbox.store.save(try sandbox.recording("a"), conversacion, backend: "wk")
        try await sandbox.store.addTranscript(reconocida, for: "a", backend: "correccion")

        #expect(try await sandbox.store.transcript(for: "a") == reconocida)
        let primera = try #require(try await sandbox.store.versions(for: "a").first)
        #expect(try await sandbox.store.transcript(for: "a", version: primera.id) == conversacion)
    }

    @Test("bautizar a alguien guarda sus huellas con el nombre; cada bautizo suma huellas, no las sustituye")
    func bautizar() async throws {
        let sandbox = try Sandbox()

        try await sandbox.store.addVoices([voz("Speaker 1", [1, 0])], to: "Rubén", source: "a")
        try await sandbox.store.addVoices([voz("Rubén", [0.9, 0.1]), voz("Rubén", [0.8, 0.2])], to: "Rubén", source: "b")
        try await sandbox.store.addVoices([voz("Speaker 2", [0, 1])], to: "Nuria", source: "a")

        let personas = try sandbox.store.people()
        #expect(personas.map(\.name) == ["Nuria", "Rubén"])
        #expect(personas.map { $0.voices.map(\.source) } == [["a"], ["a", "b", "b"]])
        #expect(try sandbox.store.knownVoices().filter { $0.person == "Rubén" }.map(\.embedding) == [[1, 0], [0.9, 0.1], [0.8, 0.2]])
        #expect(try sandbox.store.knownVoices().allSatisfy { $0.model == modelo })
    }

    @Test("se puede quitar una huella, renombrar a alguien, fusionar dos personas y borrar una")
    func corregir() async throws {
        let sandbox = try Sandbox()
        try await sandbox.store.addVoices([voz("Speaker 1", [1, 0]), voz("Speaker 1", [0.9, 0.1])], to: "Ruben", source: "a")
        try await sandbox.store.addVoices([voz("Speaker 2", [0, 1])], to: "Rubén G.", source: "b")
        try await sandbox.store.addVoices([voz("Speaker 3", [1, 1])], to: "Ana", source: "c")

        let sobra = try #require(try sandbox.store.people().first { $0.name == "Ruben" }?.voices.last)
        try await sandbox.store.removeVoice(sobra.id)
        try await sandbox.store.renamePerson("Ruben", to: "Rubén")
        try await sandbox.store.renamePerson("Rubén G.", to: "Rubén")
        try await sandbox.store.removePerson("Ana")

        let personas = try sandbox.store.people()
        #expect(personas.map(\.name) == ["Rubén"])
        #expect(personas.first?.voices.map(\.source) == ["a", "b"])
    }

    @Test("una persona sin huellas no se queda en la lista")
    func sinHuellas() async throws {
        let sandbox = try Sandbox()
        try await sandbox.store.addVoices([voz("Speaker 1", [1, 0])], to: "Rubén", source: "a")

        let unica = try #require(try sandbox.store.people().first?.voices.first)
        try await sandbox.store.removeVoice(unica.id)

        #expect(try sandbox.store.people().isEmpty)
    }
}

private let dosHablantes = TranscriptionOptions(language: "es", diarize: true, speakerCount: 2)
private let entradas = TranscriptionInputs(backend: "wk", options: dosHablantes)

private func cuenta(_ store: Store, _ tabla: String) throws -> Int {
    try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(tabla)") ?? 0 }
}

@Suite("Integridad de las huellas en la biblioteca")
struct HuellasIntegridadTests {
    @Test("una versión con hablantes pero sin huellas, de antes de Personas, no se recupera: se vuelve a diarizar")
    func sinHuellasNoSeRecupera() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        let antigua = Transcript(segments: conversacion.segments)
        try sandbox.store.save(recording, antigua, backend: "wk", options: dosHablantes)

        #expect(try await sandbox.store.memory().recall(recording, entradas) == nil)

        try await sandbox.store.addTranscript(conversacion, for: "a", backend: "wk", options: dosHablantes)
        #expect(try await sandbox.store.memory().recall(recording, entradas)?.transcript == conversacion)
    }

    @Test("una versión sin hablantes se sigue recuperando aunque no tenga huellas")
    func sinHablantesSiSeRecupera() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        let plana = Transcript(segments: [TranscriptSegment(start: 0, end: 1, text: "hola")])
        let unaVoz = TranscriptionOptions(language: "es")
        try sandbox.store.save(recording, plana, backend: "wk", options: unaVoz)

        #expect(try await sandbox.store.memory().recall(recording, TranscriptionInputs(backend: "wk", options: unaVoz))?.transcript == plana)
    }

    @Test("corregir y enseñar huellas va junto: la versión corregida y las huellas de la persona se guardan a la vez")
    func correccionConHuellas() async throws {
        let sandbox = try Sandbox()
        try sandbox.store.save(try sandbox.recording("a"), conversacion, backend: "wk")
        let corregida = conversacion.renaming("Speaker 1", to: "Rubén")

        try await sandbox.store.addCorrection(
            corregida, for: "a", digest: nil, teaching: [voz("Speaker 1", [0.25, -1.5, 3])], to: "Rubén")

        #expect(try await sandbox.store.transcript(for: "a") == corregida)
        #expect(try sandbox.store.knownVoices() == [KnownVoice(person: "Rubén", embedding: [0.25, -1.5, 3], model: modelo)])
        await #expect(throws: (any Error).self) {
            try await sandbox.store.addCorrection(corregida, for: "nada", digest: nil, teaching: [voz("x", [1])], to: "Ana")
        }
        #expect(try sandbox.store.people().map(\.name) == ["Rubén"])
    }

    @Test("una huella guardada que no se puede leer se descarta en vez de leerse a medias")
    func huellaRota() async throws {
        let sandbox = try Sandbox()
        try await sandbox.store.addVoices([voz("x", [1, 0])], to: "Rubén", source: "a")
        try await sandbox.store.writer.write { db in
            try db.execute(sql: "UPDATE personVoice SET embedding = ?", arguments: [Data([1, 2, 3])])
        }

        #expect(try sandbox.store.knownVoices().isEmpty)
        #expect(decodedEmbedding(Data()) == nil)
        #expect(decodedEmbedding(encodedEmbedding([0.5, -2])) == [0.5, -2])
    }

    @Test("descartar una grabación borra sus huellas y lo reconocido; olvidar a alguien borra las suyas")
    func borrados() async throws {
        let sandbox = try Sandbox()
        try sandbox.store.save(
            try sandbox.recording("a"),
            conversacion.recognizing([Recognition(speaker: "Speaker 2", person: "Nuria", distance: 0.2)]), backend: "wk")
        try await sandbox.store.addVoices([voz("x", [1, 0])], to: "Nuria", source: "a")

        try await sandbox.store.discard(key: "a")
        try await sandbox.store.removePerson("Nuria")

        #expect(try cuenta(sandbox.store, "voice") == 0)
        #expect(try cuenta(sandbox.store, "recognition") == 0)
        #expect(try cuenta(sandbox.store, "personVoice") == 0)
    }
}
