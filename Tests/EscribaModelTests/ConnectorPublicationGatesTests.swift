import Foundation
import Testing
import Synchronization
import EscribaCore
import EscribaEngine
import EscribaStore
import EscribaSystemKit
import EscribaJSC
@testable import EscribaModel

private actor PublicationGate {
    private var arrived = false
    private var ready: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func enter() async {
        arrived = true
        ready?.resume()
        ready = nil
        await withCheckedContinuation { resume = $0 }
    }

    func waitUntilEntered() async {
        if !arrived { await withCheckedContinuation { ready = $0 } }
    }

    func release() { resume?.resume(); resume = nil }
}

@MainActor
struct ConnectorPublicationGatesTests {
    private func fixture() throws -> (URL, Store, Note, ConnectorArchive, ConnectorPermission) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = try Store(root: root.appending(path: "library"))
        let audio = root.appending(path: "nota.m4a")
        try Data("sintético".utf8).write(to: audio)
        let note = Note(recording: Recording(url: audio, startedAt: .now, key: "nota"), transcript: Transcript(text: "Texto de prueba"))
        _ = try store.save(note.recording, note.transcript, backend: "sintético")
        let archive = ConnectorArchive(directory: root.appending(path: "archive"))
        let folder = root.appending(path: "bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let permission = ConnectorPermission(account: "cuenta", capability: "folder", folder: folder.path, enabled: true)
        return (root, store, note, archive, permission)
    }

    @Test("dos publicaciones concurrentes crean una sola vez y la segunda recibe el recibo")
    func dosPublicacionesConcurrentes() async throws {
        let (root, store, note, archive, permission) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let program = ConnectorProgram(source: "adaptador controlado", fingerprint: "concurrente")
        try await archive.retain(program)
        let binding = ConnectorBinding(key: "destino", provider: "prueba", configurationJSON: "{}", programFingerprint: program.fingerprint, permission: permission)
        let gate = PublicationGate()
        let actions = Mutex<[String]>([])
        let runtime = ConnectorRuntime { _, request, bridge in
            let object = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
            let previous = object["previous"] as? [String: Any]
            let action = previous?["locator"] as? String == "una-pagina" ? "actualizar" : "crear"
            actions.withLock { $0.append(action) }
            if action == "crear" { await gate.enter() }
            _ = try await bridge.call(#"{"op":"files.apply","changes":[]}"#)
            _ = try await bridge.call(#"{"op":"checkpoint","receipt":{"locator":"una-pagina"}}"#)
            return #"{"locator":"una-pagina","receipt":{"locator":"una-pagina"}}"#
        }
        let publications = ConnectorPublications(store: store, archive: archive, runtime: runtime,
            authority: { _ in permission }, credentials: { _ in nil })
        let first = Task { try await publications.publish(note, to: binding) }
        await gate.waitUntilEntered()
        let second = Task { try await publications.publish(note, to: binding) }
        await Task.yield()
        #expect(actions.withLock { $0 } == ["crear"])
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        #expect(actions.withLock { $0 } == ["crear", "actualizar"])
        #expect(try await archive.load(recording: "nota", destination: "destino")?.locator == "una-pagina")
        #expect(try store.recording(for: "nota")?.publication(in: "destino")?.pageId == "una-pagina")
    }

    @Test("una configuración inválida sin efectos permite corregir el programa y publicar")
    func corrigeValidacionSinEfectos() async throws {
        let (root, store, note, archive, permission) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let program = try BundledConnectors.program()
        try await archive.retain(program)
        let publications = ConnectorPublications(store: store, archive: archive, runtime: try javaScriptCoreConnectorRuntime(),
            authority: { _ in permission }, credentials: { _ in nil })
        var binding = ConnectorBinding(key: "destino", provider: "okf", configurationJSON: "{}", programFingerprint: program.fingerprint, permission: permission)
        await #expect(throws: RecipeError.self) { try await publications.publish(note, to: binding) }
        let failed = try #require(try await archive.load(recording: "nota", destination: "destino"))
        #expect(failed.state == "prepared")
        #expect(failed.receiptJSON == nil)
        let replacement = ConnectorProgram(source: program.source + "\n", fingerprint: connectorFingerprint(program.source + "\n"))
        try await archive.retain(replacement)
        binding.programFingerprint = replacement.fingerprint
        binding.configurationJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["folder": try #require(permission.folder)]), as: UTF8.self)
        let published = try #require(try await publications.publish(note, to: binding))
        #expect(FileManager.default.fileExists(atPath: published.path))
        let completed = try #require(try await archive.load(recording: "nota", destination: "destino"))
        #expect(completed.state == "published")
        #expect(completed.programFingerprint == replacement.fingerprint)
    }

    @Test("si falla guardar el localizador tras crear Notion, reabrir no crea una segunda página")
    func checkpointFallaTrasCrearNotion() async throws {
        enum PersistenceFailure: Error { case unavailable }
        let (root, store, note, archive, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let program = try BundledConnectors.program()
        try await archive.retain(program)
        let permission = ConnectorPermission(account: "cuenta", capability: "http", origin: "https://api.notion.com", enabled: true)
        let binding = ConnectorBinding(key: "destino", provider: "notion", configurationJSON: #"{"source":{"id":"fuente","title":"Notas","properties":[{"name":"Nombre","type":"title"}]},"columns":{"Nombre":"{{titulo}}"}}"#,
            programFingerprint: program.fingerprint, permission: permission)
        let actualRuntime = try javaScriptCoreConnectorRuntime()
        let created = Mutex(0)
        let controlledRuntime = ConnectorRuntime { retained, request, persistence in
            try await actualRuntime.execute(retained, request, ConnectorBridge { message in
                let call = try #require(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
                if call["op"] as? String == "http" {
                    #expect(call["url"] as? String == "https://api.notion.com/v1/pages")
                    created.withLock { $0 += 1 }
                    return #"{"status":200,"headers":{},"body":"{\"object\":\"page\",\"id\":\"creada\",\"url\":\"https://notion.so/creada\"}"}"#
                }
                let receipt = call["receipt"] as? [String: Any]
                if receipt?["locator"] as? String == "creada" { throw PersistenceFailure.unavailable }
                return try await persistence.call(message)
            })
        }
        let publications = ConnectorPublications(store: store, archive: archive, runtime: controlledRuntime,
            authority: { _ in permission }, credentials: { _ in nil })
        await #expect(throws: PersistenceFailure.unavailable) { try await publications.publish(note, to: binding) }
        #expect(created.withLock { $0 } == 1)
        let reopened = ConnectorArchive(directory: root.appending(path: "archive"))
        let saved = try #require(try await reopened.load(recording: "nota", destination: "destino"))
        let checkpointJSON = try #require(saved.receiptJSON)
        let checkpoint = try #require(JSONSerialization.jsonObject(with: Data(checkpointJSON.utf8)) as? [String: Any])
        #expect(checkpoint["state"] as? String == "creating")
        #expect(checkpoint["locator"] as? String == "")
        let next = ConnectorPublications(store: try Store(root: root.appending(path: "library")), archive: reopened, runtime: controlledRuntime,
            authority: { _ in permission }, credentials: { _ in nil })
        await #expect(throws: RecipeError.self) { try await next.publish(note, to: binding) }
        #expect(created.withLock { $0 } == 1)
        #expect(try store.recording(for: "nota")?.publication(in: "destino")?.pageId == nil)
    }
}
