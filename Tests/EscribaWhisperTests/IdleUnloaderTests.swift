import Foundation
import Synchronization
import Testing

@testable import EscribaWhisper

private final class Spy: Sendable {
    private let count = Mutex(0)

    var unloads: Int { count.withLock { $0 } }
    func bump() { count.withLock { $0 += 1 } }
}

private actor ManualClock {
    private var waiter: CheckedContinuation<Void, any Error>?
    private(set) var started = 0
    private(set) var cancelled = 0

    nonisolated var sleeper: Sleeper {
        { _ in try await self.sleep() }
    }

    private func sleep() async throws {
        started += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
            }
        } onCancel: {
            Task { await self.interrupt() }
        }
    }

    private func interrupt() {
        guard let waiter else { return }
        self.waiter = nil
        cancelled += 1
        waiter.resume(throwing: CancellationError())
    }

    func elapse() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume()
    }

    var isSleeping: Bool { waiter != nil }
}

private func settle() async throws {
    try await Task.sleep(for: .milliseconds(20))
}

private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<100 where await !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Descarga del modelo por inactividad")
struct IdleUnloaderTests {
    @Test("tras el plazo sin trabajo, descarga una sola vez")
    func descargaTrasElPlazo() async throws {
        let spy = Spy()
        let clock = ManualClock()
        let unloader = IdleUnloader(after: .seconds(300), sleep: clock.sleeper) { spy.bump() }

        await unloader.touch()
        try await waitUntil { await clock.isSleeping }
        #expect(spy.unloads == 0)

        await clock.elapse()
        try await waitUntil { spy.unloads == 1 }

        #expect(spy.unloads == 1)
        #expect(await clock.started == 1)
    }

    @Test("cada trabajo nuevo reinicia el plazo: solo cuenta el ultimo")
    func elTrabajoReiniciaElPlazo() async throws {
        let spy = Spy()
        let clock = ManualClock()
        let unloader = IdleUnloader(after: .seconds(300), sleep: clock.sleeper) { spy.bump() }

        for _ in 0..<4 {
            await unloader.touch()
            try await waitUntil { await clock.isSleeping }
        }
        try await waitUntil { await clock.cancelled == 3 }
        #expect(spy.unloads == 0)
        #expect(await clock.cancelled == 3)

        await clock.elapse()
        try await waitUntil { spy.unloads == 1 }
        try await settle()

        #expect(spy.unloads == 1)
    }

    @Test("cancelar mientras se trabaja evita la descarga")
    func cancelarEvitaLaDescarga() async throws {
        let spy = Spy()
        let clock = ManualClock()
        let unloader = IdleUnloader(after: .seconds(300), sleep: clock.sleeper) { spy.bump() }

        await unloader.touch()
        try await waitUntil { await clock.isSleeping }
        await unloader.cancel()
        try await waitUntil { await clock.cancelled == 1 }
        await clock.elapse()
        try await settle()

        #expect(spy.unloads == 0)
    }
}
