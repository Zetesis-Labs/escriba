import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaSystemKit

@Suite("Fuente de Notas de Voz")
struct VoiceMemosSourceTests {
    private func makeTree(_ files: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-vm-\(UUID().uuidString)")
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: url)
        }
        return root
    }

    @Test("recoge las grabaciones del primer nivel")
    func primerNivel() throws {
        let root = try makeTree(["una.m4a", "otra.m4a"])

        #expect(try voiceMemosSource(root: root).scan().count == 2)
    }

    @Test("no baja a las subcarpetas de edicion")
    func sinSubcarpetas() throws {
        let root = try makeTree(["buena.m4a", "edicion.composition/trozo.m4a"])

        let urls = try voiceMemosSource(root: root).scan().map { $0.url.lastPathComponent }

        #expect(urls == ["buena.m4a"])
    }

    @Test("renombrar el fichero en disco no cambia su clave")
    func renombradoReal() throws {
        let root = try makeTree(["Nueva grabacion.m4a"])
        let source = voiceMemosSource(root: root)
        let antes = try source.scan()

        try FileManager.default.moveItem(
            at: root.appending(path: "Nueva grabacion.m4a"),
            to: root.appending(path: "Reunion con Aritz.m4a"))
        let despues = try source.scan()

        #expect(antes.map(\.key) == despues.map(\.key))
        #expect(despues.map { $0.url.lastPathComponent } == ["Reunion con Aritz.m4a"])
    }

    @Test("una carpeta ilegible se reporta como problema de acceso")
    func carpetaIlegible() throws {
        let root = try makeTree(["x.m4a"])
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        #expect(FileSystem.accessProblem(root: root) != nil)
    }

    @Test("una carpeta legible no reporta problema")
    func carpetaLegible() throws {
        let root = try makeTree(["x.m4a"])

        #expect(FileSystem.accessProblem(root: root) == nil)
    }

    @Test("una carpeta que no existe se reporta como problema")
    func carpetaInexistente() {
        let root = URL(fileURLWithPath: "/no/existe/\(UUID().uuidString)")

        #expect(FileSystem.accessProblem(root: root) != nil)
    }

    @Test("la fuente declara donde vigilar y como se llama")
    func identidadDeLaFuente() throws {
        let root = try makeTree(["x.m4a"])
        let source = voiceMemosSource(root: root)

        #expect(source.locations == [root])
        #expect(source.name == "Notas de Voz")
    }
}
