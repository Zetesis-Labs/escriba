import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaSystemKit

private func waitUntil(
    _ comment: Comment, timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("timeout esperando: \(comment)")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite("Senal de despertar")
struct WakeSignalTests {
    @Test("una senal previa despierta el siguiente wait al instante")
    func senalPrevia() async {
        let waker = WakeSignal()
        await waker.signal()

        let start = Date()
        let woken = await waker.wait(upTo: 5)

        #expect(woken)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test("sin senal, el plazo vence y devuelve false")
    func vencimiento() async {
        let waker = WakeSignal()
        #expect(await waker.wait(upTo: 0.05) == false)
    }

    @Test("una senal en mitad de la espera despierta con true, sin agotar el plazo")
    func senalDurante() async throws {
        let waker = WakeSignal()
        let start = Date()
        async let woken = waker.wait(upTo: 10)
        try await Task.sleep(for: .milliseconds(50))
        await waker.signal()

        #expect(await woken)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }
    func bump() { count.withLock { $0 += 1 } }
}

private struct Sandbox {
    let controller: DaemonController
    let passes = Counter()

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-daemon-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base.appending(path: "source"), withIntermediateDirectories: true)

        let pipeline = Pipeline(
            source: justPressRecordSource(root: base.appending(path: "source")),
            ledger: try Ledger(path: base.appending(path: "ledger.db")),
            backend: TranscriptionBackend(
                name: "falso", transcribe: { _ in Transcript(text: "") }),
            sink: { _, _ in base },
            onEvent: { [passes] event in
                if case .idle = event { passes.bump() }
            }
        )
        controller = DaemonController(
            pipeline: pipeline, reconcileInterval: 3600, retryInterval: 3600, debounce: 0)
    }
}

@Suite("Daemon estructurado")
struct DaemonControllerTests {
    @Test("hace una pasada al arrancar y otra por cada despertar")
    func pasadas() async throws {
        let sandbox = try Sandbox()
        sandbox.controller.start()
        try await waitUntil("la pasada inicial") { sandbox.passes.value == 1 }

        sandbox.controller.wake()

        try await waitUntil("la pasada del despertar") { sandbox.passes.value == 2 }
        sandbox.controller.stop()
    }

    @Test("tras stop no hay mas pasadas ni despertares que valgan")
    func parada() async throws {
        let sandbox = try Sandbox()
        sandbox.controller.start()
        try await waitUntil("la pasada inicial") { sandbox.passes.value == 1 }

        sandbox.controller.stop()
        sandbox.controller.wake()
        try await Task.sleep(for: .milliseconds(200))

        #expect(sandbox.passes.value == 1)
    }
}
