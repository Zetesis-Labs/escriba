import Foundation
import Testing
import EscribaSystemKit

@Suite("Captura del proyecto de conectores")
struct ConectoresProyectoTests {
    @Test("captura código npm y su lockfile y excluye enlaces fuera del proyecto")
    func capturaDependencias() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "node_modules/cliente"), withIntermediateDirectories: true)
        try "{}".write(to: root.appending(path: "package-lock.json"), atomically: true, encoding: .utf8)
        try "module.exports = 42".write(to: root.appending(path: "node_modules/cliente/index.cjs"), atomically: true, encoding: .utf8)
        let snapshot = try snapshotConnectorProject(root: root)
        #expect(snapshot.sources["node_modules/cliente/index.cjs"] == "module.exports = 42")
        #expect(snapshot.paths.contains("package-lock.json"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "fuera.ts"), withDestinationURL: root.deletingLastPathComponent().appending(path: "secreto.ts"))
        #expect(throws: (any Error).self) { _ = try snapshotConnectorProject(root: root) }
    }
}
