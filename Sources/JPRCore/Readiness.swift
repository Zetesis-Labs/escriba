import Foundation

public func classify(probe: Probe, previous: Probe?, settleSeconds: TimeInterval) -> FileState {
    if probe.isDataless { return .dataless }
    if probe.size == 0 { return .empty }
    if let previous, previous.size != probe.size { return .growing }
    if probe.observedAt.timeIntervalSince(probe.modifiedAt) < settleSeconds { return .growing }
    return .ready
}

public func selectPending(_ recordings: [Recording], done: Set<String>) -> [Recording] {
    recordings
        .filter { !done.contains($0.key) }
        .sorted { $0.startedAt < $1.startedAt }
}
