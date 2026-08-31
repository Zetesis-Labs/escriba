import Foundation

func offloaded<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            do {
                continuation.resume(returning: try body())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

func offloaded<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: body())
        }
    }
}
