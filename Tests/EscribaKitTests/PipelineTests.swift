import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaKit

private final class Spy<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { values.count }

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

private struct Sandbox {
    let root: URL
    let output: URL
    let ledger: Ledger

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-tests-\(UUID().uuidString)")
        root = base.appending(path: "source")
        output = base.appending(path: "output")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledger = try Ledger(path: base.appending(path: "ledger.db"))
    }

    func add(_ key: String) throws {
        let parts = key.split(separator: "/")
        let day = root.appending(path: String(parts[0]))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: day.appending(path: "\(parts[1]).m4a"))
    }
}

private func backend(
    name: String = "falso",
    transcribe: @escaping @Sendable (URL) throws(TranscriptionError) -> Transcript
) -> TranscriptionBackend {
    TranscriptionBackend(name: name, transcribe: transcribe, preflight: {})
}

private func capturingSink(into spy: Spy<String>, output: URL) -> Sink {
    { recording, transcript in
        spy.append(transcript.text)
        return output.appending(path: "\(recording.key).txt")
    }
}

@Suite("Pipeline con backend inyectado")
struct PipelineTests {
    @Test("transcribe lo pendiente, lo pasa al sink y lo marca como hecho")
    func casoFeliz() throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-29/10-00-00")
        let escrito = Spy<String>()

        let pipeline = Pipeline(
            source: justPressRecordSource(root: sandbox.root),
            ledger: sandbox.ledger,
            backend: backend { _ in Transcript(text: "hola que tal") },
            sink: capturingSink(into: escrito, output: sandbox.output),
            settleSeconds: 0)

        let outcome = try pipeline.runOnce()

        #expect(outcome.processed == 1)
        #expect(outcome.deferred == 0)
        #expect(escrito.values == ["hola que tal"])
        #expect(try sandbox.ledger.settledKeys().contains("2026-08-29/10-00-00"))
    }

    @Test("no reprocesa lo que ya esta en el ledger")
    func idempotencia() throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-29/10-00-00")
        let llamadas = Spy<URL>()
        let escrito = Spy<String>()

        let pipeline = Pipeline(
            source: justPressRecordSource(root: sandbox.root),
            ledger: sandbox.ledger,
            backend: backend { url in
                llamadas.append(url)
                return Transcript(text: "texto")
            },
            sink: capturingSink(into: escrito, output: sandbox.output),
            settleSeconds: 0)

        try pipeline.runOnce()
        let segunda = try pipeline.runOnce()

        #expect(llamadas.count == 1)
        #expect(segunda.processed == 0)
    }

    @Test("un backend caido aplaza sin consumir intentos, para reintentarlo despues")
    func backendCaido() throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-29/10-00-00")
        let eventos = Spy<PipelineEvent>()

        let pipeline = Pipeline(
            source: justPressRecordSource(root: sandbox.root),
            ledger: sandbox.ledger,
            backend: backend { _ throws(TranscriptionError) in
                throw TranscriptionError.backendUnavailable("apagado")
            },
            sink: capturingSink(into: Spy<String>(), output: sandbox.output),
            settleSeconds: 0,
            onEvent: { eventos.append($0) })

        let outcome = try pipeline.runOnce()

        #expect(outcome.processed == 0)
        #expect(outcome.deferred == 1)
        #expect(try sandbox.ledger.settledKeys().isEmpty)
        #expect(try sandbox.ledger.failures().isEmpty)
        #expect(eventos.values.contains { if case .backendUnavailable = $0 { true } else { false } })
    }

    @Test("un backend caido corta la pasada en vez de quemar el resto de grabaciones")
    func backendCaidoCortaLaPasada() throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-29/10-00-00")
        try sandbox.add("2026-08-29/11-00-00")
        try sandbox.add("2026-08-29/12-00-00")
        let llamadas = Spy<URL>()

        let pipeline = Pipeline(
            source: justPressRecordSource(root: sandbox.root),
            ledger: sandbox.ledger,
            backend: backend { url throws(TranscriptionError) in
                llamadas.append(url)
                throw TranscriptionError.backendUnavailable("apagado")
            },
            sink: capturingSink(into: Spy<String>(), output: sandbox.output),
            settleSeconds: 0)

        _ = try pipeline.runOnce()

        #expect(llamadas.count == 1)
    }

    @Test("un fallo de transcripcion queda registrado con su motivo y suma un intento")
    func falloDeTranscripcion() throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-29/10-00-00")

        let pipeline = Pipeline(
            source: justPressRecordSource(root: sandbox.root),
            ledger: sandbox.ledger,
            backend: backend { _ throws(TranscriptionError) in
                throw TranscriptionError.failed("audio corrupto")
            },
            sink: capturingSink(into: Spy<String>(), output: sandbox.output),
            settleSeconds: 0)

        let outcome = try pipeline.runOnce()
        let fallos = try sandbox.ledger.failures()

        #expect(outcome.processed == 0)
        #expect(fallos.count == 1)
        #expect(fallos[0].key == "2026-08-29/10-00-00")
        #expect(fallos[0].attempts == 1)
        #expect(fallos[0].error.contains("audio corrupto"))
    }

    @Test("una grabacion que aun se esta escribiendo se deja para el proximo ciclo")
    func grabacionSinAsentar() throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-29/10-00-00")
        let llamadas = Spy<URL>()

        let pipeline = Pipeline(
            source: justPressRecordSource(root: sandbox.root),
            ledger: sandbox.ledger,
            backend: backend { url in
                llamadas.append(url)
                return Transcript(text: "texto")
            },
            sink: capturingSink(into: Spy<String>(), output: sandbox.output),
            settleSeconds: 3600)

        let outcome = try pipeline.runOnce()

        #expect(llamadas.count == 0)
        #expect(outcome.deferred == 1)
        #expect(try sandbox.ledger.settledKeys().isEmpty)
    }
}
