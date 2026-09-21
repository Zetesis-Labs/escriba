import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine

private let grabacion = Recording(
    url: URL(fileURLWithPath: "/tmp/a.m4a"), startedAt: Date(), key: "2026-08-29/10-00-00")

private func nota(_ text: String) -> Note {
    Note(recording: grabacion, transcript: Transcript(text: text))
}

private func namedSink(_ name: String, into trace: Trace<String>) -> Sink {
    { _ in
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

        let salida = try await combinado(nota("hola"))

        #expect(trace.values == ["txt", "store", "otro"])
        #expect(salida == URL(fileURLWithPath: "/tmp/txt"))
    }

    @Test("un fallo en cualquiera se propaga")
    func falloSePropaga() async {
        let trace = Trace<String>()
        let roto: Sink = { _ in throw TranscriptionError.failed("disco lleno") }
        let combinado = sinks(primary: namedSink("txt", into: trace), also: roto)

        await #expect(throws: TranscriptionError.self) {
            try await combinado(nota("hola"))
        }
    }

    @Test("forgiving se traga el fallo del sink, devuelve la URL de la grabacion y deja seguir la cadena")
    func forgivingNoRompe() async throws {
        let trace = Trace<String>()
        let roto: Sink = { _ in throw TranscriptionError.failed("sin red") }
        let combinado = sinks(primary: namedSink("txt", into: trace), also: forgiving(roto), namedSink("otro", into: trace))

        let salida = try await combinado(nota("hola"))

        #expect(salida == URL(fileURLWithPath: "/tmp/txt"))
        #expect(trace.values == ["txt", "otro"])
        #expect(try await forgiving(roto)(nota("hola")) == grabacion.url)
    }
}
