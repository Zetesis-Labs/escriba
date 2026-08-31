import Foundation
import Testing

@testable import JPRApp
@testable import JPRCore
@testable import JPRStore

private struct Sandbox {
    let base: URL
    let store: Store
    let model: LibraryModel

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
        model = LibraryModel(store: store)
    }

    func save(_ key: String, text: String = "hola") throws {
        let url = base.appending(path: "source/\(key).m4a")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        let recording = Recording(url: url, startedAt: Date(), key: key)
        try store.save(recording, Transcript(text: text), backend: "falso")
    }
}

private func waitUntil(
    _ comment: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("timeout esperando: \(comment)")
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }
}

private let salida = URL(fileURLWithPath: "/tmp/x.txt")

@Suite("Modelo de la biblioteca")
struct LibraryModelTests {
    @Test("observa el store: lo guardado aparece en la lista sin recargar nada")
    func observa() async throws {
        let sandbox = try Sandbox()
        sandbox.model.startObserving()
        try await waitUntil("estado inicial") { sandbox.model.recordings.isEmpty == false || true }

        try sandbox.save("2026-08-31/10-00-00")

        try await waitUntil("la grabacion llega") {
            sandbox.model.recordings.map(\.key) == ["2026-08-31/10-00-00"]
        }
    }

    @Test("los eventos del pipeline mueven el estado del vigilante")
    func estados() throws {
        let sandbox = try Sandbox()
        #expect(sandbox.model.status == .starting)

        sandbox.model.apply(.passStarted(pending: 2))
        #expect(sandbox.model.status == .working(pending: 2))

        sandbox.model.apply(.transcribed(key: "k", transcript: Transcript(text: "t"), output: salida))
        #expect(sandbox.model.status == .watching)

        sandbox.model.apply(.idle(scanned: 7))
        #expect(sandbox.model.status == .watching)
        #expect(sandbox.model.scanned == 7)
    }

    @Test("un problema se queda a la vista: un ciclo tranquilo no lo tapa")
    func problemaPersistente() throws {
        let sandbox = try Sandbox()

        sandbox.model.apply(.failed(key: "k", reason: "audio corrupto"))
        guard case .problem = sandbox.model.status else {
            Issue.record("esperaba .problem, hay \(sandbox.model.status)")
            return
        }

        sandbox.model.apply(.idle(scanned: 3))
        guard case .problem = sandbox.model.status else {
            Issue.record("el idle tapo el problema")
            return
        }

        sandbox.model.apply(.passStarted(pending: 1))
        sandbox.model.apply(.transcribed(key: "k", transcript: Transcript(text: "t"), output: salida))
        #expect(sandbox.model.status == .watching)
    }

    @Test("el detalle de una grabacion sale del store")
    func detalle() throws {
        let sandbox = try Sandbox()
        try sandbox.save("2026-08-31/10-00-00", text: "el contenido")

        #expect(try sandbox.model.transcript(for: "2026-08-31/10-00-00")?.text == "el contenido")
        #expect(try sandbox.model.transcript(for: "no/existe") == nil)
    }
}
