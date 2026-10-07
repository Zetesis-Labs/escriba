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
