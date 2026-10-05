import Foundation

public func clockStamp(_ seconds: TimeInterval) -> String {
    let whole = Int(max(seconds, 0).rounded(.down))
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

public func bracketStamp(_ seconds: TimeInterval) -> String {
    let total = Int(max(seconds, 0).rounded(.down))
    let hours = total / 3600
    let body = String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
    return hours > 0 ? "[\(hours):\(body)]" : "[\(body)]"
}

public func durationClock(_ seconds: TimeInterval) -> String {
    let total = Int(max(seconds, 0).rounded(.down))
    let body = String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
    return total >= 3600 ? "\(total / 3600):\(body)" : body
}

public let noteTitleLimit = 80

public func noteTitle(digest: Digest?, key: String, text: String, limit: Int = noteTitleLimit) -> String {
    if let title = digest?.title, !title.isEmpty { return title }
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return key }
    var length = 0
    var taken: [String] = []
    for word in words {
        let next = taken.isEmpty ? word.count : length + 1 + word.count
        guard next <= limit else { break }
        length = next
        taken.append(word)
    }
    let head = taken.joined(separator: " ")
    return taken.count < words.count ? head + "…" : head
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
