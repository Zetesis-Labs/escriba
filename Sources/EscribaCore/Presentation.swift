import Foundation

public func clockStamp(_ seconds: TimeInterval) -> String {
    let whole = Int(max(seconds, 0).rounded(.down))
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

extension Transcript {
    public func speaker(before index: Int) -> String? {
        guard index > 0, index <= segments.count else { return nil }
        return segments[index - 1].speaker
    }

    public func startsNewSpeaker(at index: Int) -> Bool {
        guard segments.indices.contains(index) else { return false }
        return segments[index].speaker != speaker(before: index)
    }
}
