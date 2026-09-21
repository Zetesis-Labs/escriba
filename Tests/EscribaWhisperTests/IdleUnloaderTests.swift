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
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var doomed: Set<Int> = []
    private var next = 0
    private(set) var started = 0
    private(set) var cancelled = 0

    nonisolated var sleeper: Sleeper {
        { _ in try await self.sleep() }
    }

    private func sleep() async throws {
        let id = next
        next += 1
        started += 1
        try await withTaskCancellationHandler {
            if doomed.contains(id) {
                cancelled += 1
                throw CancellationError()
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(continuation, for: id)
            }
        } onCancel: {
            Task { await self.interrupt(id) }
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, any Error>, for id: Int) {
        waiters[id] = continuation
    }

    private func interrupt(_ id: Int) {
        if let waiter = waiters.removeValue(forKey: id) {
            cancelled += 1
            waiter.resume(throwing: CancellationError())
        } else {
            doomed.insert(id)
        }
    }

    func elapse() {
        let all = waiters
        waiters = [:]
        all.values.forEach { $0.resume() }
    }

    var isSleeping: Bool { !waiters.isEmpty }
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
