import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-memoria-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func recording(_ key: String) throws -> Recording {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return Recording(url: url, startedAt: Date(timeIntervalSince1970: 1_000_000), key: key)
    }

    func memory() -> NoteMemory {
        store.memory()
    }
}

private let es = TranscriptionOptions(language: "es")
private let dos = TranscriptionOptions(language: "es", diarize: true, speakerCount: 2)
private let entradas = TranscriptionInputs(backend: "wk", options: es)
private let resumen = Digest(title: "Hola", summary: "Adiós", tags: ["x"])

private let conversacion = Transcript(segments: [
    TranscriptSegment(
        start: 0, end: 1.5, speaker: "Speaker 1", text: "Hola, que tal.",
        words: [
            TranscriptWord(start: 0, end: 0.4, text: "Hola,"),
            TranscriptWord(start: 0.5, end: 1.5, text: "que tal."),
        ]),
    TranscriptSegment(
        start: 1.6, end: 3, speaker: "Speaker 2", text: "Bien.",
        words: [TranscriptWord(start: 1.6, end: 3, text: "Bien.")]),
])

@Suite("La biblioteca recuerda lo ya hecho")
struct MemoriaTests {
    @Test("recuerda la ultima version del mismo motor con los mismos criterios, intacta y con su resumen")
    func recuerdaLaUltimaQueCasa() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        try sandbox.store.save(recording, Transcript(text: "v1"), backend: "wk", options: es)
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk", options: dos)
        try await sandbox.store.addTranscript(conversacion, for: "a", backend: "wk", options: es, digest: resumen)
        try await sandbox.store.addTranscript(Transcript(text: "v4"), for: "a", backend: "wk", options: dos)

        let recordada = try await sandbox.memory().recall(recording, entradas)
        let versiones = try await sandbox.store.versions(for: "a")

        #expect(recordada?.version == versiones[2].id)
        #expect(recordada?.transcript == conversacion)
        #expect(recordada?.digest == resumen)
    }

    @Test("una version de otro motor, con otros criterios o sin criterios guardados no se recuerda")
    func noCasa() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        try sandbox.store.save(recording, Transcript(text: "sin criterios"), backend: "wk")
        try await sandbox.store.addTranscript(Transcript(text: "otro motor"), for: "a", backend: "Groq", options: es)
        try await sandbox.store.addTranscript(Transcript(text: "otros criterios"), for: "a", backend: "wk", options: dos)

        #expect(try await sandbox.memory().recall(recording, entradas) == nil)
    }

    @Test("sin la grabacion en la biblioteca no hay nada que recordar")
    func grabacionNueva() async throws {
        let sandbox = try Sandbox()

        #expect(try await sandbox.memory().recall(try sandbox.recording("a"), entradas) == nil)
    }

    @Test("lo transcrito se guarda en cuanto llega: version vigente, con sus criterios y la copia del audio")
    func guardaLoTranscrito() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")

        let version = try await sandbox.memory().keepTranscript(recording, conversacion, entradas)

        let versiones = try await sandbox.store.versions(for: "a")
        let guardada = try sandbox.store.recording(for: "a")
        #expect(versiones.map(\.id) == [version])
        #expect(versiones.first?.isCurrent == true)
        #expect(versiones.first?.options == es)
        #expect(versiones.first?.backend == "wk")
        #expect(try await sandbox.store.transcript(for: "a") == conversacion)
        #expect(guardada?.audio == .libraryCopy)
        #expect(guardada?.status == .done)
    }

    @Test("lo guardado a mitad se recuerda despues")
    func idaYVuelta() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        let memoria = sandbox.memory()

        let version = try await memoria.keepTranscript(recording, conversacion, entradas)
        try await memoria.keepDigest(recording, version, resumen)

        #expect(try await memoria.recall(recording, entradas)
            == Remembered(version: version, transcript: conversacion, digest: resumen))
    }

    @Test("el resumen va a la version que se transcribio aunque mientras tanto se haya reprocesado")
    func resumenAnclado() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        let memoria = sandbox.memory()
        let version = try await memoria.keepTranscript(recording, Transcript(text: "v1"), entradas)
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk", options: dos)

        try await memoria.keepDigest(recording, version, resumen)

        #expect(try await memoria.recall(recording, entradas)?.digest == resumen)
        #expect(try await sandbox.store.digest(for: "a") == nil)
    }

    @Test("sin .txt, lo que se entrega es la copia del audio que guarda la biblioteca")
    func salidaSinTexto() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")
        _ = try await sandbox.memory().keepTranscript(recording, Transcript(text: "hola"), entradas)

        let salida = try await sandbox.store.audioCopySink()(Note(recording: recording, transcript: Transcript(text: "hola")))

        #expect(salida == sandbox.store.root.appending(path: "audio/a.m4a"))
        #expect(FileManager.default.fileExists(atPath: salida.path(percentEncoded: false)))
    }

    @Test("sin la grabacion guardada no hay copia que entregar")
    func salidaSinGrabacion() async throws {
        let sandbox = try Sandbox()
        let recording = try sandbox.recording("a")

        await #expect(throws: StoreError.self) {
            try await sandbox.store.audioCopySink()(Note(recording: recording, transcript: Transcript(text: "hola")))
        }
    }
}
