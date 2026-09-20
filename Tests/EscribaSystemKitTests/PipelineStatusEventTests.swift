import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaSystemKit

private final class EventSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PipelineEvent] = []

    var values: [PipelineEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: PipelineEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
}

private struct Sandbox {
    let root: URL
    let ledger: Ledger

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-status-tests-\(UUID().uuidString)")
        root = base.appending(path: "source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledger = try Ledger(path: base.appending(path: "ledger.db"))
    }

    func add(_ key: String) throws {
        let parts = key.split(separator: "/")
        let day = root.appending(path: String(parts[0]))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: day.appending(path: "\(parts[1]).m4a"))
    }

    func pipeline(events: EventSpy) -> Pipeline {
        Pipeline(
            source: justPressRecordSource(root: root),
            ledger: ledger,
            backend: TranscriptionBackend(
                name: "falso",
                transcribe: { _ throws(TranscriptionError) in Transcript(text: "texto") },
                preflight: {}),
            sink: { _, _ in URL(fileURLWithPath: "/tmp/x.txt") },
            settleSeconds: 0,
            onEvent: { events.append($0) })
    }
}

private func etiqueta(_ event: PipelineEvent) -> String {
    switch event {
    case .scanned: "scanned"
    case .passStarted: "passStarted"
    case .transcribing: "transcribing"
    case .transcribed: "transcribed"
    case .failed: "failed"
    case .backendUnavailable: "backendUnavailable"
    case .idle: "idle"
    case .scanFailed: "scanFailed"
    }
}

@Suite("Pipeline: anuncios de estado")
struct PipelineStatusEventTests {
    @Test("cada pasada anuncia todo lo escaneado, incluido lo ya hecho")
    func anunciaEscaneado() async throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-31/09-00-00")
        let eventos = EventSpy()
        let pipeline = sandbox.pipeline(events: eventos)

        try await pipeline.runOnce()
        try await pipeline.runOnce()

        let escaneos = eventos.values.compactMap { event -> Int? in
            if case .scanned(let recordings) = event { recordings.count } else { nil }
        }
        #expect(escaneos == [1, 1])
    }

    @Test("anuncia que transcribe antes de entregar el resultado")
    func anunciaTranscribiendo() async throws {
        let sandbox = try Sandbox()
        try sandbox.add("2026-08-31/09-00-00")
        let eventos = EventSpy()

        try await sandbox.pipeline(events: eventos).runOnce()

        let tipos = eventos.values.map(etiqueta)
        let inicio = try #require(tipos.firstIndex(of: "transcribing"))
        let fin = try #require(tipos.firstIndex(of: "transcribed"))
        #expect(inicio < fin)
    }
}
