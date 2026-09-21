import Foundation

typealias Sleeper = @Sendable (Duration) async throws -> Void

actor IdleUnloader {
    private let delay: Duration
    private let sleep: Sleeper
    private let unload: @Sendable () async -> Void
    private var pending: Task<Void, Never>?

    init(
        after delay: Duration,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        unload: @escaping @Sendable () async -> Void
    ) {
        self.delay = delay
        self.sleep = sleep
        self.unload = unload
    }

    func touch() {
        pending?.cancel()
        pending = Task { [sleep, delay, unload] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await unload()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
