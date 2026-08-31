import Foundation

public struct PassOutcome: Sendable, Equatable {
    public let processed: Int
    public let deferred: Int

    public init(processed: Int, deferred: Int) {
        self.processed = processed
        self.deferred = deferred
    }

    public var hasWorkInFlight: Bool { deferred > 0 }
}

public func nextWakeInterval(
    after outcome: PassOutcome,
    retryInterval: TimeInterval,
    reconcileInterval: TimeInterval
) -> TimeInterval {
    outcome.hasWorkInFlight ? retryInterval : reconcileInterval
}
