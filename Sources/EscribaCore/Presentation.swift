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

public func recordingTitle(digest: Digest?, preview: String?, startedAt: Date, timeZone: TimeZone) -> String {
    let text = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if digest?.title.isEmpty == false || !text.isEmpty {
        return noteTitle(digest: digest, key: "", text: text, limit: 60)
    }
    return "Grabación del \(longDate(startedAt, timeZone: timeZone))"
}

public func recordingExcerpt(digest: Digest?, preview: String?) -> String? {
    if let summary = noteDescription(summary: digest?.summary) { return summary }
    let flat = preview?.split(whereSeparator: \.isNewline).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return flat.flatMap { $0.isEmpty ? nil : $0 }
}

public func recordingWhen(_ date: Date, now: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let time = String(
        format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    if calendar.isDate(date, inSameDayAs: now) { return "hoy, \(time)" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
        return "ayer, \(time)"
    }
    let day = calendar.component(.day, from: date)
    let month = shortMonthNames[calendar.component(.month, from: date) - 1]
    let year = calendar.component(.year, from: date)
    return year == calendar.component(.year, from: now) ? "\(day) \(month), \(time)" : "\(day) \(month) \(year)"
}

public func visibleTags(_ tags: [String], limit: Int = 3) -> (shown: [String], hidden: Int) {
    (Array(tags.prefix(limit)), max(tags.count - limit, 0))
}

private let shortMonthNames = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"]
