import Foundation
import Testing
import EscribaCore
import EscribaEngine
import EscribaStore
import EscribaSystemKit
import EscribaJSC
@testable import EscribaModel

@MainActor
struct TypeScriptConnectorIntegrationTests {
    @Test("OKF real publica, corrige y retira N documentos con recibos durables sin fuentes")
    func cicloRealConJavaScriptCore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try Store(root: root.appending(path: "library"))
        let audio = root.appending(path: "nota.m4a")
        try Data("audio sintético".utf8).write(to: audio)
        let recording = Recording(url: audio, startedAt: Date(timeIntervalSince1970: 1_758_013_200), key: "integracion")
        let transcript = Transcript(segments: [
            TranscriptSegment(start: 0, end: 12, speaker: "Ana", text: "Revisamos el lanzamiento."),
            TranscriptSegment(start: 12, end: 30, speaker: "Luis", text: "Lo pasamos al jueves."),
        ])
        let note = Note(recording: recording, transcript: transcript,
            digest: Digest(title: "Lanzamiento", summary: "Se acuerda el jueves.", tags: ["equipo"]))
        _ = try store.save(recording, transcript, backend: "sintético")
        let archiveURL = root.appending(path: "archive")
        let archive = ConnectorArchive(directory: archiveURL)
        let program = try BundledConnectors.program()
        try await archive.retain(program)
        let permission = ConnectorPermission(account: "carpeta", capability: "folder", folder: folder.path, enabled: true)
        let config = String(decoding: try JSONSerialization.data(withJSONObject: ["folder": folder.path]), as: UTF8.self)
        let binding = ConnectorBinding(key: "destino", provider: "okf", configurationJSON: config,
            programFingerprint: program.fingerprint, permission: permission)
        let runtime = try javaScriptCoreConnectorRuntime()
        let publications = ConnectorPublications(store: store, archive: archive, runtime: runtime,
            authority: { _ in permission }, credentials: { _ in nil })
        let firstURL = try #require(try await publications.publish(note, to: binding))
        #expect(try String(contentsOf: firstURL, encoding: .utf8).contains("Se acuerda el jueves."))
        let saved = try #require(try await archive.load(recording: recording.key, destination: binding.key))
        #expect(saved.state == "published")
        let receiptJSON = try #require(saved.receiptJSON)
        let receipt = try #require(try JSONSerialization.jsonObject(with: Data(receiptJSON.utf8)) as? [String: Any])
        let paths = try #require(receipt["files"] as? [String: String])
        #expect(paths.keys.filter { $0.hasPrefix("transcripciones/") && !$0.hasSuffix("index.md") }.count == 1)
        #expect(paths.count == 6)
        #expect(paths.values.allSatisfy { $0.count == 64 })

        let reopened = ConnectorArchive(directory: archiveURL)
        let reopenedStore = try Store(root: root.appending(path: "library"))
        let restored = ConnectorPublications(store: reopenedStore, archive: reopened, runtime: runtime,
            authority: { _ in permission }, credentials: { _ in nil })
        var missingProject = binding
        missingProject.programFingerprint = "fuentes-borradas"
        missingProject.configurationJSON = "{}"
        let corrected = Note(recording: recording, transcript: Transcript(text: "Texto corregido sin resumen."))
        let correctedURL = try #require(try await restored.publish(corrected, to: missingProject))
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(try String(contentsOf: correctedURL, encoding: .utf8).contains("# Transcripción"))
        #expect(!(try String(contentsOf: correctedURL, encoding: .utf8)).contains("Se acuerda el jueves."))
        let correctedRecord = try #require(try await reopened.load(recording: recording.key, destination: binding.key))
        let locator = try #require(correctedRecord.locator)
        #expect(try reopenedStore.recording(for: recording.key)?.publication(in: binding.key)?.pageId == locator)
        try await restored.remove(key: recording.key, locator: locator, from: missingProject)
        #expect(!FileManager.default.fileExists(atPath: correctedURL.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "index.md").path))
        #expect(try await reopened.load(recording: recording.key, destination: binding.key)?.state == "removed")
        #expect(try String(contentsOf: folder.appending(path: "log.md"), encoding: .utf8).contains("**Baja**"))

        let again = try #require(try await restored.publish(note, to: binding))
        #expect(FileManager.default.fileExists(atPath: again.path))
        #expect(try await reopened.load(recording: recording.key, destination: binding.key)?.state == "published")
    }
}
