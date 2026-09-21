import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let grabacion = Recording(
    url: URL(fileURLWithPath: "/tmp/a.m4a"), startedAt: Date(), key: "2026-08-29/10-00-00")

private func namedSink(_ name: String, into trace: Trace<String>) -> Sink {
    { _, _ in
        trace.append(name)
        return URL(fileURLWithPath: "/tmp/\(name)")
    }
}

@Suite("Sinks combinados")
struct SinkTests {
    @Test("ejecuta el primario y despues los demas, y devuelve la URL del primario")
    func ordenYResultado() async throws {
        let trace = Trace<String>()
        let combinado = sinks(
            primary: namedSink("txt", into: trace), also: namedSink("store", into: trace),
            namedSink("otro", into: trace))

        let salida = try await combinado(grabacion, Transcript(text: "hola"))

        #expect(trace.values == ["txt", "store", "otro"])
        #expect(salida == URL(fileURLWithPath: "/tmp/txt"))
    }

    @Test("un fallo en cualquiera se propaga")
    func falloSePropaga() async {
        let trace = Trace<String>()
        let roto: Sink = { _, _ in throw TranscriptionError.failed("disco lleno") }
        let combinado = sinks(primary: namedSink("txt", into: trace), also: roto)

        await #expect(throws: TranscriptionError.self) {
            try await combinado(grabacion, Transcript(text: "hola"))
        }
    }
}
