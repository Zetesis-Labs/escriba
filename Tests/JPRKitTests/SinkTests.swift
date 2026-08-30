import Foundation
import Testing

@testable import JPRCore
@testable import JPRKit

private let grabacion = Recording(
    url: URL(fileURLWithPath: "/tmp/a.m4a"), startedAt: Date(), key: "2026-08-29/10-00-00")

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func sink(_ name: String) -> Sink {
        { _, _ in
            self.lock.withLock { self.storage.append(name) }
            return URL(fileURLWithPath: "/tmp/\(name)")
        }
    }
}

@Suite("Sinks combinados")
struct SinkTests {
    @Test("ejecuta el primario y despues los demas, y devuelve la URL del primario")
    func ordenYResultado() throws {
        let trace = Trace()
        let combinado = sinks(primary: trace.sink("txt"), also: trace.sink("store"), trace.sink("otro"))

        let salida = try combinado(grabacion, Transcript(text: "hola"))

        #expect(trace.values == ["txt", "store", "otro"])
        #expect(salida == URL(fileURLWithPath: "/tmp/txt"))
    }

    @Test("un fallo en cualquiera se propaga")
    func falloSePropaga() throws {
        let trace = Trace()
        let roto: Sink = { _, _ in throw TranscriptionError.failed("disco lleno") }
        let combinado = sinks(primary: trace.sink("txt"), also: roto)

        #expect(throws: TranscriptionError.self) {
            try combinado(grabacion, Transcript(text: "hola"))
        }
    }
}
