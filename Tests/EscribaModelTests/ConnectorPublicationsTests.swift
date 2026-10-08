import Foundation
import Testing
import Synchronization
import EscribaCore
import EscribaEngine
import EscribaStore
import EscribaSystemKit
@testable import EscribaModel

@MainActor
struct ConnectorPublicationsTests {
    @Test("la publicación retiene programa y recibo para regenerar aunque cambie el destino")
    func conservaProgramaYRecibo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root.appending(path: "library"))
        let audio = root.appending(path: "nota.m4a")
        try Data("synthetic".utf8).write(to: audio)
        let note = Note(recording: Recording(url: audio, startedAt: .now, key: "nota"), transcript: Transcript(text: "hola"))
        _ = try store.save(note.recording, note.transcript, backend: "fake")
        let archive = ConnectorArchive(directory: root.appending(path: "archive"))
        let first = ConnectorProgram(source: "original", fingerprint: "a")
        let second = ConnectorProgram(source: "changed", fingerprint: "b")
        try await archive.retain(first)
        try await archive.retain(second)
        let calls = Mutex<[String]>([])
        let runtime = ConnectorRuntime { program, request, bridge in
            calls.withLock { $0.append(program.source + ":" + request) }
            _ = try await bridge.call(#"{"op":"checkpoint","receipt":{"locator":"external-1","state":"published"}}"#)
            return #"{"locator":"external-1","receipt":{"locator":"external-1","state":"published"}}"#
        }
        let permission = ConnectorPermission(account: "account", capability: "folder", folder: root.path, enabled: true)
        let publications = ConnectorPublications(store: store, archive: archive, runtime: runtime,
            authority: { _ in permission }, credentials: { _ in nil })
        var binding = ConnectorBinding(key: "destination", provider: "custom", configurationJSON: "{}", programFingerprint: "a", permission: permission)
        _ = try await publications.publish(note, to: binding)
        binding.programFingerprint = "b"
        _ = try await publications.publish(note, to: binding)
        #expect(calls.withLock { $0.count } == 2)
        #expect(calls.withLock { $0.last?.hasPrefix("original:") } == true)
        #expect(calls.withLock { $0.last?.contains("external-1") } == true)
        #expect(try store.recording(for: "nota")?.publication(in: "destination")?.pageId == "external-1")
    }

    @Test("revocar una cuenta impide nuevos efectos incluso desde un programa retenido")
    func revocaDuranteEjecucion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store(root: root.appending(path: "library"))
        let audio = root.appending(path: "nota.m4a")
        try Data("synthetic".utf8).write(to: audio)
        let note = Note(recording: Recording(url: audio, startedAt: .now, key: "nota"), transcript: Transcript(text: "hola"))
        _ = try store.save(note.recording, note.transcript, backend: "fake")
        let archive = ConnectorArchive(directory: root.appending(path: "archive"))
        try await archive.retain(ConnectorProgram(source: "fake", fingerprint: "a"))
        let permission = ConnectorPermission(account: "account", capability: "folder", folder: root.path, enabled: true)
        let enabled = Mutex(true)
        let runtime = ConnectorRuntime { _, _, bridge in
            enabled.withLock { $0 = false }
            _ = try await bridge.call(#"{"op":"files.apply","changes":[{"path":"escape.md","contents":"no"}]}"#)
            return "{}"
        }
        let publications = ConnectorPublications(store: store, archive: archive, runtime: runtime,
            authority: { _ in enabled.withLock { $0 } ? permission : nil }, credentials: { _ in nil })
        let binding = ConnectorBinding(key: "destination", provider: "custom", configurationJSON: "{}", programFingerprint: "a", permission: permission)
        await #expect(throws: ConnectorHostError.self) { try await publications.publish(note, to: binding) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "escape.md").path))
    }
}

@MainActor
struct ConnectorRecoveryTests {
    private func fixture() throws -> (URL, Store, Note, ConnectorArchive, ConnectorBinding) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = try Store(root: root.appending(path: "library"))
        let audio = root.appending(path: "nota.m4a")
        try Data("synthetic".utf8).write(to: audio)
        let note = Note(recording: Recording(url: audio, startedAt: .now, key: "nota"), transcript: Transcript(text: "hola"))
        _ = try store.save(note.recording, note.transcript, backend: "fake")
        let archive = ConnectorArchive(directory: root.appending(path: "archive"))
        let permission = ConnectorPermission(account: "account", capability: "folder", folder: root.path, enabled: true)
        let binding = ConnectorBinding(key: "destination", provider: "custom", configurationJSON: "{}", programFingerprint: "a", permission: permission)
        return (root, store, note, archive, binding)
    }

    @Test("un fallo tras guardar recibo se recupera al reabrir sin crear otra publicación")
    func recuperaTrasFalloParcial() async throws {
        let (root, store, note, archive, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await archive.retain(ConnectorProgram(source: "fake", fingerprint: "a"))
        let permission = binding.permission
        let failing = ConnectorPublications(store: store, archive: archive, runtime: ConnectorRuntime { _, _, bridge in
            _ = try await bridge.call(#"{"op":"checkpoint","receipt":{"locator":"created-before-crash"}}"#)
            throw ConnectorHostError.transport
        }, authority: { _ in permission }, credentials: { _ in nil })
        await #expect(throws: ConnectorHostError.self) { try await failing.publish(note, to: binding) }
        let reopened = ConnectorArchive(directory: root.appending(path: "archive"))
        let recovering = ConnectorPublications(store: store, archive: reopened, runtime: ConnectorRuntime { _, request, _ in
            let payload = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
            let previous = payload?["previous"] as? [String: Any]
            #expect(previous?["locator"] as? String == "created-before-crash")
            return #"{"locator":"created-before-crash","receipt":{"locator":"created-before-crash"}}"#
        }, authority: { _ in permission }, credentials: { _ in nil })
        _ = try await recovering.publish(note, to: binding)
        #expect(try store.recording(for: "nota")?.publication(in: "destination")?.pageId == "created-before-crash")
    }

    @Test("una creación sin recibo no se vuelve a ejecutar a ciegas")
    func bloqueaCreacionIncierta() async throws {
        let (root, store, note, archive, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await archive.retain(ConnectorProgram(source: "fake", fingerprint: "a"))
        let permission = binding.permission
        let calls = Mutex(0)
        let publications = ConnectorPublications(store: store, archive: archive, runtime: ConnectorRuntime { _, _, bridge in
            calls.withLock { $0 += 1 }
            _ = try await bridge.call(#"{"op":"files.apply","changes":[{"path":"effect.txt","contents":"written"}]}"#)
            throw ConnectorHostError.transport
        }, authority: { _ in permission }, credentials: { _ in nil })
        await #expect(throws: ConnectorHostError.self) { try await publications.publish(note, to: binding) }
        await #expect(throws: ConnectorPublicationError.self) { try await publications.publish(note, to: binding) }
        #expect(calls.withLock { $0 } == 1)
    }
}

@MainActor extension ConnectorRecoveryTests {
    @Test("volver a publicar tras retirar ignora el rastro antiguo de la biblioteca")
    func publicarTrasRetiradaConfirmada() async throws {
        let (root, store, note, archive, binding) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await archive.retain(ConnectorProgram(source: "fake", fingerprint: "a"))
        let permission = binding.permission
        let publications = ConnectorPublications(store: store, archive: archive, runtime: ConnectorRuntime { _, request, _ in
            let payload = try JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any]
            if payload?["operation"] as? String == "remove" {
                return #"{"receipt":{"locator":"external-1","state":"removed"}}"#
            }
            #expect(payload?["previous"] == nil)
            return #"{"locator":"external-1","receipt":{"locator":"external-1"}}"#
        }, authority: { _ in permission }, credentials: { _ in nil })
        _ = try await publications.publish(note, to: binding)
        try await publications.remove(key: "nota", locator: "external-1", from: binding)
        #expect(try store.recording(for: "nota")?.publication(in: "destination")?.pageId == "external-1")
        _ = try await publications.publish(note, to: binding)
    }
}
