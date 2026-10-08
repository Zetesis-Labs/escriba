import Foundation
import Testing
import EscribaCore

@testable import EscribaSystemKit

private func carpetaTemporal() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "escriba-bandeja-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fecha(_ url: URL) throws -> Date? {
    try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

@Suite("Bandeja sobre una carpeta de verdad")
struct BandejaSistemaTests {
    @Test("añadir copia el fichero con su fecha, sin tocar el original, y la carpeta lo ve como grabacion")
    func anadir() throws {
        let raiz = try carpetaTemporal()
        let origen = try carpetaTemporal()
        defer {
            try? FileManager.default.removeItem(at: raiz)
            try? FileManager.default.removeItem(at: origen)
        }
        let original = origen.appending(path: "Reunión.m4a")
        try Data("audio".utf8).write(to: original)
        let ayer = Date(timeIntervalSince1970: 1_791_133_200)
        try FileManager.default.setAttributes([.modificationDate: ayer], ofItemAtPath: original.path)
        let bandeja = fileInbox(root: raiz)

        try bandeja.importFile(original, "Reunión.m4a", nil)

        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try bandeja.names() == ["Reunión.m4a"])
        let grabaciones = try FileSystem.scanAudio(root: raiz)
        #expect(grabaciones.map(\.key) == ["Reunión"])
        #expect(grabaciones.first?.startedAt == ayer)
    }

    @Test("una grabacion en curso vive en una carpeta oculta que el escaneo no ve")
    func enCurso() throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let bandeja = fileInbox(root: raiz)

        let temporal = try bandeja.recordingURL()
        try Data("audio".utf8).write(to: temporal)

        #expect(temporal.path.hasPrefix(raiz.path))
        #expect(try FileSystem.scanAudio(root: raiz).isEmpty)
        #expect(try bandeja.names().isEmpty)
    }

    @Test("terminar una grabacion la deja en la bandeja con la hora de inicio como fecha")
    func terminar() throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let bandeja = fileInbox(root: raiz)
        let temporal = try bandeja.recordingURL()
        try Data("audio".utf8).write(to: temporal)
        let inicio = Date(timeIntervalSince1970: 1_791_219_600)

        try bandeja.finishRecording(temporal, "Grabación 2026-10-05 19.00.00.m4a", inicio, nil)

        #expect(!FileManager.default.fileExists(atPath: temporal.path))
        let grabaciones = try FileSystem.scanAudio(root: raiz)
        #expect(grabaciones.map(\.key) == ["Grabación 2026-10-05 19.00.00"])
        #expect(grabaciones.first?.startedAt == inicio)
    }

    @Test("descartar una grabacion borra el temporal y no deja nada en la bandeja")
    func descartar() throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let bandeja = fileInbox(root: raiz)
        let temporal = try bandeja.recordingURL()
        try Data("audio".utf8).write(to: temporal)

        bandeja.discardRecording(temporal)

        #expect(!FileManager.default.fileExists(atPath: temporal.path))
        #expect(try FileSystem.scanAudio(root: raiz).isEmpty)
    }

    @Test("lo que entra con receta elegida la lleva al lado, oculta al escaneo; lo que entra sin elegir no lleva ninguna")
    func conReceta() throws {
        let raiz = try carpetaTemporal()
        let origen = try carpetaTemporal()
        defer {
            try? FileManager.default.removeItem(at: raiz)
            try? FileManager.default.removeItem(at: origen)
        }
        let original = origen.appending(path: "Reunión.m4a")
        try Data("audio".utf8).write(to: original)
        let bandeja = fileInbox(root: raiz)
        let temporal = try bandeja.recordingURL()
        try Data("audio".utf8).write(to: temporal)

        try bandeja.importFile(original, "Reunión.m4a", "reparto")
        try bandeja.importFile(original, "Sin elegir.m4a", nil)
        try bandeja.finishRecording(temporal, "Grabación 2026-10-05 19.00.00.m4a", Date(), "V1")

        let grabaciones = try FileSystem.scanAudio(root: raiz)
        #expect(Set(grabaciones.map(\.key)) == ["Reunión", "Sin elegir", "Grabación 2026-10-05 19.00.00"])
        #expect(try bandeja.names() == ["Reunión.m4a", "Sin elegir.m4a", "Grabación 2026-10-05 19.00.00.m4a"])
        let elegidas = Dictionary(uniqueKeysWithValues: try grabaciones.map { ($0.key, try bandeja.recipe($0.url)) })
        #expect(elegidas == ["Reunión": "reparto", "Sin elegir": nil, "Grabación 2026-10-05 19.00.00": "V1"])
    }

    @Test("un audio que entra con el nombre de otro ya borrado no hereda la receta que eligió aquel")
    func sinHerencia() throws {
        let raiz = try carpetaTemporal()
        let origen = try carpetaTemporal()
        defer {
            try? FileManager.default.removeItem(at: raiz)
            try? FileManager.default.removeItem(at: origen)
        }
        let original = origen.appending(path: "Reunión.m4a")
        try Data("audio".utf8).write(to: original)
        let bandeja = fileInbox(root: raiz)
        let enBandeja = raiz.appending(path: "Reunión.m4a")

        try bandeja.importFile(original, "Reunión.m4a", "reparto")
        try FileManager.default.removeItem(at: enBandeja)
        try bandeja.importFile(original, "Reunión.m4a", nil)

        #expect(try bandeja.recipe(enBandeja) == nil)
    }

    @Test("si ya hay un audio con ese nombre no entra, y la receta que eligió aquel no cambia")
    func nombreOcupado() throws {
        let raiz = try carpetaTemporal()
        let origen = try carpetaTemporal()
        defer {
            try? FileManager.default.removeItem(at: raiz)
            try? FileManager.default.removeItem(at: origen)
        }
        let original = origen.appending(path: "Reunión.m4a")
        try Data("audio".utf8).write(to: original)
        let bandeja = fileInbox(root: raiz)
        try bandeja.importFile(original, "Reunión.m4a", "reparto")
        try bandeja.importFile(original, "Sin elegir.m4a", nil)

        #expect(throws: CocoaError.self) { try bandeja.importFile(original, "Reunión.m4a", "otra") }
        #expect(throws: CocoaError.self) { try bandeja.importFile(original, "Sin elegir.m4a", "otra") }

        #expect(try bandeja.recipe(raiz.appending(path: "Reunión.m4a")) == "reparto")
        #expect(try bandeja.recipe(raiz.appending(path: "Sin elegir.m4a")) == nil)
    }

    @Test("dos grabaciones seguidas no comparten fichero temporal")
    func temporalesDistintos() throws {
        let raiz = try carpetaTemporal()
        defer { try? FileManager.default.removeItem(at: raiz) }
        let bandeja = fileInbox(root: raiz)

        #expect(try bandeja.recordingURL() != bandeja.recordingURL())
    }
}
