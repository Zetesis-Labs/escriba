import Foundation

public struct TranscriptExport: Equatable, Sendable {
    public let version: Int
    public let key: String
    public let startedAt: Date
    public let source: String
    public let backend: String?
    public let duration: TimeInterval?
    public let speakers: [String]
    public let text: String
    public let segments: [TranscriptSegment]

    public func json() -> String {
        var fields = [
            "\"version\": \(version)",
            "\"key\": \(quoted(key))",
            "\"startedAt\": \(quoted(startedAt.formatted(.iso8601)))",
            "\"source\": \(quoted(source))",
        ]
        if let backend { fields.append("\"backend\": \(quoted(backend))") }
        if let duration { fields.append("\"duration\": \(number(duration))") }
        fields.append("\"speakers\": [\(speakers.map(quoted).joined(separator: ", "))]")
        fields.append("\"text\": \(quoted(text))")

        if !segments.isEmpty {
            fields.append("\"wordFormat\": [\"start\", \"end\", \"text\"]")
            let cuerpo = segments.map { "    \(json(for: $0))" }.joined(separator: ",\n")
            fields.append("\"segments\": [\n\(cuerpo)\n  ]")
        }

        return "{\n" + fields.map { "  \($0)" }.joined(separator: ",\n") + "\n}"
    }

    private func json(for segment: TranscriptSegment) -> String {
        var parts = ["\"start\": \(number(segment.start))", "\"end\": \(number(segment.end))"]
        if let speaker = segment.speaker { parts.append("\"speaker\": \(quoted(speaker))") }
        parts.append("\"text\": \(quoted(segment.text))")

        if !segment.words.isEmpty {
            let words = segment.words.map {
                "[\(number($0.start)), \(number($0.end)), \(quoted($0.text))]"
            }
            parts.append("\"words\": [\(words.joined(separator: ", "))]")
        }

        return "{\(parts.joined(separator: ", "))}"
    }
}

private func quoted(_ text: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard let data = try? encoder.encode(text) else { return "\"\"" }
    return String(decoding: data, as: UTF8.self)
}

private func number(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    return value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
}

public func transcriptExport(
    key: String, startedAt: Date, source: URL, backend: String?, transcript: Transcript
) -> TranscriptExport {
    TranscriptExport(
        version: 1,
        key: key,
        startedAt: startedAt,
        source: source.path(percentEncoded: false),
        backend: backend,
        duration: transcript.duration,
        speakers: transcript.speakers,
        text: transcript.text,
        segments: transcript.segments)
}

public enum RevealTarget: Equatable, Sendable {
    case file(URL)
    case folder(URL)
    case unavailable
}

public func sidecarTextURL(outputRoot: URL, key: String) -> URL {
    outputRoot.appending(path: "\(key).txt")
}

public func revealTarget(
    txtFolder: URL?, key: String, exists: (URL) -> Bool
) -> RevealTarget {
    guard let txtFolder else { return .unavailable }

    let file = sidecarTextURL(outputRoot: txtFolder, key: key)
    if exists(file) { return .file(file) }

    let folder = file.deletingLastPathComponent()
    return exists(folder) ? .folder(folder) : .unavailable
}
