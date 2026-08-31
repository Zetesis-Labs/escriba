import Foundation
import Testing

@testable import EscribaWhisper

private final class Spy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var unloads: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

@Suite("Descarga del modelo por inactividad")
struct IdleUnloaderTests {
    @Test("tras el plazo sin trabajo, descarga una sola vez")
    func descargaTrasElPlazo() async throws {
        let spy = Spy()
        let unloader = IdleUnloader(after: .milliseconds(80)) { spy.bump() }

        await unloader.touch()
        try await Task.sleep(for: .milliseconds(400))

        #expect(spy.unloads == 1)
    }

    @Test("cada trabajo nuevo reinicia el plazo")
    func elTrabajoReiniciaElPlazo() async throws {
        let spy = Spy()
        let unloader = IdleUnloader(after: .milliseconds(200)) { spy.bump() }

        for _ in 0..<4 {
            await unloader.touch()
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(spy.unloads == 0)

        try await Task.sleep(for: .milliseconds(500))
        #expect(spy.unloads == 1)
    }

    @Test("cancelar mientras se trabaja evita la descarga")
    func cancelarEvitaLaDescarga() async throws {
        let spy = Spy()
        let unloader = IdleUnloader(after: .milliseconds(80)) { spy.bump() }

        await unloader.touch()
        await unloader.cancel()
        try await Task.sleep(for: .milliseconds(300))

        #expect(spy.unloads == 0)
    }
}
