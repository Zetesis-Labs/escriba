import Foundation

public struct DroppedFile: Equatable, Sendable {
    public let source: URL
    public let name: String
}

public struct DropPlan: Equatable, Sendable {
    public let accepted: [DroppedFile]
    public let rejected: [URL]
}

public func isSupportedAudio(_ url: URL) -> Bool {
    url.isFileURL && audioExtensions.contains(url.pathExtension.lowercased())
}

public func inboxName(for original: String, taken: Set<String>) -> String {
    let used = Set(taken.map { $0.lowercased() })
    guard used.contains(original.lowercased()) else { return original }
    let url = URL(fileURLWithPath: original)
    let stem = url.deletingPathExtension().lastPathComponent
    let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
    return (2...).lazy.map { "\(stem) \($0)\(suffix)" }.first { !used.contains($0.lowercased()) } ?? original
}

public func dropPlan(_ urls: [URL], taken: Set<String>) -> DropPlan {
    var names = taken
    var accepted: [DroppedFile] = []
    var rejected: [URL] = []
    for url in urls {
        guard isSupportedAudio(url) else {
            rejected.append(url)
            continue
        }
        let name = inboxName(for: url.lastPathComponent, taken: names)
        names.insert(name)
        accepted.append(DroppedFile(source: url, name: name))
    }
    return DropPlan(accepted: accepted, rejected: rejected)
}

public func recordingName(startedAt: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: startedAt)
    let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    let time = String(format: "%02d.%02d.%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    return "Grabación \(day) \(time).m4a"
}

public func meterLevel(decibels: Float) -> Double {
    guard decibels.isFinite else { return 0 }
    return min(max(Double(decibels + 60) / 60, 0), 1)
}
