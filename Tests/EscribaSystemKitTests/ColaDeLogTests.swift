import Foundation
import Testing

@testable import EscribaSystemKit

@Suite("El final del log, sin leer el fichero entero")
struct ColaDeLogTests {
    private func fichero(_ lineas: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-cola-\(UUID().uuidString).log")
        try (0..<lineas).map { "línea \($0)" }.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("de un fichero grande devuelve solo las ultimas lineas completas")
    func cola() throws {
        let url = try fichero(1000)

        let cola = try logTail(of: url, maxBytes: 100)

        #expect(cola.last == "línea 999")
        #expect(cola.count < 20)
        #expect(cola.allSatisfy { $0.hasPrefix("línea ") })
    }

    @Test("de un fichero pequeño devuelve todas sus lineas")
    func entero() throws {
        let url = try fichero(3)

        #expect(try logTail(of: url, maxBytes: 10_000) == ["línea 0", "línea 1", "línea 2"])
    }

    @Test("sin fichero todavia no hay lineas")
    func sinFichero() throws {
        #expect(try logTail(of: URL(fileURLWithPath: "/no/existe.log"), maxBytes: 100).isEmpty)
    }
}

@Suite("Rotar el log de la app al arrancar")
struct RotarLogTests {
    private func carpeta() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-rotar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("un log que pasa del limite se aparta como .1 y se empieza de cero, sustituyendo al .1 anterior")
    func rota() throws {
        let base = try carpeta()
        let log = base.appending(path: "escriba.log")
        try String(repeating: "x", count: 200).write(to: log, atomically: true, encoding: .utf8)
        try "viejo".write(to: base.appending(path: "escriba.1.log"), atomically: true, encoding: .utf8)

        try rotateLog(at: log, maxBytes: 100)

        #expect(!FileManager.default.fileExists(atPath: log.path(percentEncoded: false)))
        #expect(try String(contentsOf: base.appending(path: "escriba.1.log"), encoding: .utf8).count == 200)
    }

    @Test("un log pequeño, o que aun no existe, se deja como esta")
    func noRota() throws {
        let base = try carpeta()
        let log = base.appending(path: "escriba.log")
        try "poco".write(to: log, atomically: true, encoding: .utf8)

        try rotateLog(at: log, maxBytes: 100)
        try rotateLog(at: base.appending(path: "otro.log"), maxBytes: 100)

        #expect(try String(contentsOf: log, encoding: .utf8) == "poco")
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "escriba.1.log").path(percentEncoded: false)))
    }
}
