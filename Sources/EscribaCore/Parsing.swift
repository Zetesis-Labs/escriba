import Foundation

public enum RecordingParser {
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    public static func parse(_ url: URL, root: URL) -> Recording? {
        guard url.pathExtension.lowercased() == "m4a" else { return nil }

        let dayDirectory = url.deletingLastPathComponent()
        guard normalized(dayDirectory.deletingLastPathComponent()) == normalized(root)
        else { return nil }

        let day = dayDirectory.lastPathComponent
        let time = url.deletingPathExtension().lastPathComponent

        guard let (year, month, dayOfMonth) = split(day, separator: "-", widths: [4, 2, 2]),
              let (hour, minute, second) = split(time, separator: "-", widths: [2, 2, 2]),
              let startedAt = date(year, month, dayOfMonth, hour, minute, second)
        else { return nil }

        return Recording(url: url, startedAt: startedAt, key: "\(day)/\(time)")
    }

    public static func startDate(fromKey key: String) -> Date? {
        let parts = key.split(separator: "/")
        guard parts.count >= 2,
              let (year, month, dayOfMonth) = split(
                String(parts[parts.count - 2]), separator: "-", widths: [4, 2, 2]),
              let (hour, minute, second) = split(
                String(parts[parts.count - 1]), separator: "-", widths: [2, 2, 2])
        else { return nil }
        return date(year, month, dayOfMonth, hour, minute, second)
    }

    private static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func split(
        _ text: String, separator: Character, widths: [Int]
    ) -> (Int, Int, Int)? {
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == widths.count else { return nil }

        var values: [Int] = []
        for (part, width) in zip(parts, widths) {
            guard part.count == width, part.allSatisfy(\.isNumber), let value = Int(part)
            else { return nil }
            values.append(value)
        }
        return (values[0], values[1], values[2])
    }

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }
}

public let audioExtensions: Set<String> = [
    "m4a", "mp3", "wav", "aac", "flac", "opus", "ogg", "caf", "aiff", "aif", "mp4", "mov",
]

public func recordingKey(for url: URL, root: URL) -> String? {
    guard audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }

    var base = root.standardizedFileURL.path(percentEncoded: false)
    while base.count > 1 && base.hasSuffix("/") { base.removeLast() }

    let file = url.standardizedFileURL.path(percentEncoded: false)
    let prefix = base == "/" ? "/" : base + "/"
    guard file.hasPrefix(prefix) else { return nil }

    let relative = String(file.dropFirst(prefix.count))
    guard !relative.isEmpty else { return nil }

    return (relative as NSString).deletingPathExtension
}
