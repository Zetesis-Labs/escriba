import Foundation
import Testing

@testable import JPRCore
@testable import JPRKit

@Suite("Fuentes de grabaciones")
struct SourceTests {
    private func makeTree(_ files: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-source-\(UUID().uuidString)")
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: url)
        }
        return root
    }

    @Test("la fuente de carpeta recoge audio de cualquier nombre y subcarpeta")
    func carpetaLibre() throws {
        let root = try makeTree([
            "llamada-cliente.wav", "2026/reunion.m4a", "notas/idea suelta.mp3",
        ])

        let keys = Set(try folderSource(name: "test", root: root).scan().map(\.key))

        #expect(keys == ["llamada-cliente", "2026/reunion", "notas/idea suelta"])
    }

    @Test("ignora lo que no es audio")
    func ignoraOtros() throws {
        let root = try makeTree(["bueno.m4a", "leeme.txt", "captura.png"])

        #expect(try folderSource(name: "test", root: root).scan().count == 1)
    }

    @Test("la fuente de Just Press Record solo acepta su esquema de nombres")
    func esquemaJPR() throws {
        let root = try makeTree(["2026-08-29/10-00-00.m4a", "suelto.m4a", "otro/11-00-00.m4a"])

        let keys = try justPressRecordSource(root: root).scan().map(\.key)

        #expect(keys == ["2026-08-29/10-00-00"])
    }

    @Test("cada fuente declara donde vigilar")
    func localizaciones() throws {
        let root = try makeTree(["x.m4a"])

        #expect(folderSource(name: "test", root: root).locations == [root])
    }
}
