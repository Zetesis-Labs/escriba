import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaStore

private struct Sandbox {
    let base: URL
    let store: Store

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-resumen-\(UUID().uuidString)")
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
}

private let resumen = Digest(title: "Backups", summary: "Se habló de MinIO.", tags: ["backups", "minio"])

@Suite("Resumen guardado con la transcripcion")
struct ResumenGuardadoTests {
    @Test("el resumen viaja con la version que lo genero")
    func porVersion() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")
        try sandbox.store.save(grabacion, Transcript(text: "v1"), backend: "wk", digest: resumen)
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk")

        #expect(try await sandbox.store.digest(for: "a") == nil)

        let primera = try #require(try await sandbox.store.versions(for: "a").first)
        try await sandbox.store.choose(version: primera.id, for: "a")

        #expect(try await sandbox.store.digest(for: "a") == resumen)
        #expect(try sandbox.store.recordings().first?.digest == resumen)
    }

    @Test("se puede generar el resumen despues y queda en la version vigente")
    func generadoDespues() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")
        try sandbox.store.save(grabacion, Transcript(text: "v1"), backend: "wk")

        try await sandbox.store.setDigest(resumen, for: "a")

        #expect(try await sandbox.store.digest(for: "a") == resumen)
        #expect(try sandbox.store.recordings().first?.digest?.tags == ["backups", "minio"])
    }

    @Test("el titular es el titulo del resumen y, sin resumen, el nombre del fichero")
    func titular() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")
        try sandbox.store.save(grabacion, Transcript(text: "v1"), backend: "wk")

        #expect(try sandbox.store.recording(for: "a")?.headline == "a")

        try await sandbox.store.setDigest(resumen, for: "a")

        #expect(try sandbox.store.recording(for: "a")?.headline == "Backups")
        #expect(try sandbox.store.recording(for: "a")?.title == "a")
    }

    @Test("resumir una grabacion que no esta en la biblioteca lo dice")
    func desconocida() async {
        await #expect(throws: StoreError.self) {
            try await Sandbox().store.setDigest(resumen, for: "fantasma")
        }
    }

    @Test("el resumen se escribe en la version que se pidio, aunque entre otra por medio")
    func ancladoASuVersion() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")
        try sandbox.store.save(grabacion, Transcript(text: "v1"), backend: "wk")
        let primera = try #require(try await sandbox.store.currentVersion(for: "a"))
        try await sandbox.store.addTranscript(Transcript(text: "v2"), for: "a", backend: "wk")

        try await sandbox.store.setDigest(resumen, for: "a", version: primera)

        #expect(try await sandbox.store.digest(for: "a") == nil)
        try await sandbox.store.choose(version: primera, for: "a")
        #expect(try await sandbox.store.digest(for: "a") == resumen)
    }

    @Test("una grabacion registrada pero sin transcribir lo dice con su propio error")
    func sinTranscripcion() async throws {
        let sandbox = try Sandbox()
        try await sandbox.store.register([try sandbox.recording("a")])

        let fallo = await #expect(throws: StoreError.self) {
            try await sandbox.store.setDigest(resumen, for: "a")
        }
        #expect("\(fallo!)".contains("aun no tiene transcripcion"))
    }

    @Test("el sink guarda el resumen que traiga la nota")
    func sinkConResumen() async throws {
        let sandbox = try Sandbox()
        let grabacion = try sandbox.recording("a")

        _ = try await sandbox.store.sink(backend: "wk")(
            Note(recording: grabacion, transcript: Transcript(text: "hola"), digest: resumen))

        #expect(try await sandbox.store.digest(for: "a") == resumen)
    }
}
