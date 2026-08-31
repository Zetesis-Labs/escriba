import Foundation

actor WakeSignal {
    private var pending = false
    private var waiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    func signal() {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: true)
        } else {
            pending = true
        }
    }

    func wait(upTo seconds: TimeInterval) async -> Bool {
        if pending {
            pending = false
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiter = (id, continuation)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    await self?.expire(id)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.abandonWait() }
        }
    }

    private func expire(_ id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: false)
    }

    private func abandonWait() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: false)
    }
}
