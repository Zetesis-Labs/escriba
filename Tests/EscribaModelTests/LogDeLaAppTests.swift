import Foundation
import Testing

@testable import EscribaEngine
@testable import EscribaModel

@MainActor
@Suite("El log de la app se ve en vivo")
struct LogDeLaAppTests {
    @Test("lee el final del fichero y se pone al dia cuando crece")
    func enVivo() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-app-\(UUID().uuidString).log")
        try "2026-10-07 23:31:13 INFO   uno\n".write(to: url, atomically: true, encoding: .utf8)
        let modelo = AppLogModel(url: url, interval: .milliseconds(20))
        modelo.start()

        try await espera { modelo.lines.map(\.message) == ["uno"] }
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("2026-10-07 23:31:14 ERROR  dos\n".utf8))
        try handle.close()
        try await espera { modelo.lines.map(\.message) == ["uno", "dos"] }

        #expect(modelo.lines.last?.level == .error)
        modelo.stop()
    }

    private func espera(_ condicion: () -> Bool) async throws {
        let limite = Date().addingTimeInterval(5)
        while !condicion() {
            guard Date() < limite else {
                Issue.record("no llego a cumplirse")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
