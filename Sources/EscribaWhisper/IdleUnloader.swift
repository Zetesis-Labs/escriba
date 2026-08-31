import Foundation

actor IdleUnloader {
    private let delay: Duration
    private let unload: @Sendable () async -> Void
    private var pending: Task<Void, Never>?

    init(after delay: Duration, unload: @escaping @Sendable () async -> Void) {
        self.delay = delay
        self.unload = unload
    }

    func touch() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await unload()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
