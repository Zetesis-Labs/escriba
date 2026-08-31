import Foundation
import Testing

@testable import EscribaKit

private func fakeHome() throws -> URL {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "escriba-migracion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

@Suite("Migracion desde jpr-transcribe")
struct LegacyMigrationTests {
    @Test("las carpetas viejas se mueven enteras a su sitio nuevo")
    func mueve() throws {
        let home = try fakeHome()
        let vieja = home.appending(path: "Library/Application Support/jpr-transcribe/library")
        try FileManager.default.createDirectory(at: vieja, withIntermediateDirectories: true)
        try Data("datos".utf8).write(to: vieja.appending(path: "library.sqlite"))

        LegacyMigration.run(home: home)

        let nueva = home.appending(
            path: "Library/Application Support/escriba/library/library.sqlite")
        #expect(FileManager.default.fileExists(atPath: nueva.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(
            atPath: home.appending(path: "Library/Application Support/jpr-transcribe")
                .path(percentEncoded: false)))
    }

    @Test("si el destino ya existe, no se pisa nada")
    func noPisa() throws {
        let home = try fakeHome()
        let vieja = home.appending(path: ".local/state/jpr-transcribe")
        let nueva = home.appending(path: ".local/state/escriba")
        try FileManager.default.createDirectory(at: vieja, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nueva, withIntermediateDirectories: true)
        try Data("nuevo".utf8).write(to: nueva.appending(path: "ledger.db"))

        LegacyMigration.run(home: home)

        let contenido = try String(
            contentsOf: nueva.appending(path: "ledger.db"), encoding: .utf8)
        #expect(contenido == "nuevo")
        #expect(FileManager.default.fileExists(atPath: vieja.path(percentEncoded: false)))
    }

    @Test("sin nada viejo, no hace nada y no falla")
    func sinNadaViejo() throws {
        LegacyMigration.run(home: try fakeHome())
    }
}
