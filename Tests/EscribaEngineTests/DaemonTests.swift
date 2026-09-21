import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

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

private final class FakeWatcher: Sendable {
    private let callbacks = Mutex<[@Sendable () -> Void]>([])
    private let stopped = Mutex(0)

    var watching: Int { callbacks.withLock { $0.count } }
    var stops: Int { stopped.withLock { $0 } }

    var watcher: FolderWatcher {
        { _, onChange in
            self.callbacks.withLock { $0.append(onChange) }
            return FolderWatch(stop: { self.stopped.withLock { $0 += 1 } })
        }
    }

    func touchFile() {
        callbacks.withLock { $0 }.forEach { $0() }
    }
}

private struct Sandbox {
    let controller: DaemonController
    let watcher = FakeWatcher()
    let passes = Trace<Int>()

    init() {
        let pipeline = Pipeline(
            source: source([]), ledger: MemoryLedger().port,
            backend: backend { _ in Transcript(text: "") }, sink: sink(into: Trace()),
            onEvent: { [passes] event in
                if case .idle(let scanned) = event { passes.append(scanned) }
            })
        controller = DaemonController(
            pipeline: pipeline, watch: watcher.watcher,
            reconcileInterval: 3600, retryInterval: 3600, debounce: 0)
    }
}

@Suite("Daemon sobre puertos falsos")
struct DaemonControllerTests {
    @Test("hace una pasada al arrancar y otra por cada despertar")
    func pasadas() async throws {
        let sandbox = Sandbox()
        sandbox.controller.start()
        try await waitUntil("la pasada inicial") { sandbox.passes.count == 1 }

        sandbox.controller.wake()

        try await waitUntil("la pasada del despertar") { sandbox.passes.count == 2 }
        sandbox.controller.stop()
    }

    @Test("un cambio en la carpeta vigilada provoca una pasada")
    func eventoDeFichero() async throws {
        let sandbox = Sandbox()
        sandbox.controller.start()
        try await waitUntil("la pasada inicial") { sandbox.passes.count == 1 }
        #expect(sandbox.watcher.watching == 1)

        sandbox.watcher.touchFile()

        try await waitUntil("la pasada por el fichero") { sandbox.passes.count == 2 }
        sandbox.controller.stop()
    }

    @Test("tras stop se sueltan los vigilantes y no hay mas pasadas")
    func parada() async throws {
        let sandbox = Sandbox()
        sandbox.controller.start()
        try await waitUntil("la pasada inicial") { sandbox.passes.count == 1 }

        sandbox.controller.stop()
        sandbox.controller.wake()
        sandbox.watcher.touchFile()
        try await Task.sleep(for: .milliseconds(200))

        #expect(sandbox.watcher.stops == 1)
        #expect(sandbox.passes.count == 1)
    }

    @Test("una pasada que falla no tumba el bucle: la siguiente vuelve a intentarlo")
    func pasadaFallida() async throws {
        let pasadas = Trace<String>()
        let pipeline = Pipeline(
            source: brokenSource(), ledger: MemoryLedger().port,
            backend: backend { _ in Transcript(text: "") }, sink: sink(into: Trace()),
            onEvent: { pasadas.append(label($0)) })
        let controller = DaemonController(
            pipeline: pipeline, reconcileInterval: 3600, retryInterval: 3600, debounce: 0)
        controller.start()
        try await waitUntil("la primera pasada") { pasadas.count == 1 }

        controller.wake()

        try await waitUntil("la segunda pasada") { pasadas.count == 2 }
        #expect(pasadas.values == ["scanFailed", "scanFailed"])
        controller.stop()
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
