import Foundation
import EscribaCore

public let okfNotesFolder = "notas"
public let okfTranscriptsFolder = "transcripciones"
public let okfNoteType = "Nota de voz"
public let okfTranscriptType = "Transcripción"
public let okfSlugLimit = 60
public let okfDescriptionLimit = 200

public struct OKFExport: Equatable, Sendable, Codable {
    public var folder: String
    public var template: BodyTemplate
    public var separateTranscript: Bool

    public static let standardTemplate = BodyTemplate([
        .heading("Resumen"), .summary, .heading("Transcripción"), .transcript(.speakers),
    ])

    public init(
        folder: String, template: BodyTemplate = OKFExport.standardTemplate, separateTranscript: Bool = true
    ) {
        self.folder = folder
        self.template = template
        self.separateTranscript = separateTranscript
    }

    public var isUsable: Bool { !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var writesTranscript: Bool { separateTranscript && template.transcriptStyle != nil }
}

struct NoteFacts {
    let title: String
    let description: String
    let summary: String?
    let tags: [String]
    let key: String
    let startedAt: Date
    let speakers: [String]
    let duration: TimeInterval?
    let source: URL
}

func noteFacts(_ note: Note, timeZone: TimeZone) -> NoteFacts {
    let summary = note.digest?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    return NoteFacts(
        title: noteTitle(digest: note.digest, key: note.recording.key, text: note.transcript.text),
        description: okfDescription(summary: summary)
            ?? "Grabación del \(longDate(note.recording.startedAt, timeZone: timeZone)).",
        summary: summary.flatMap { $0.isEmpty ? nil : $0 },
        tags: note.digest?.tags ?? [],
        key: note.recording.key,
        startedAt: note.recording.startedAt,
        speakers: note.transcript.speakers,
        duration: note.transcript.duration,
        source: note.recording.url)
}

func noteDocument(
    _ facts: NoteFacts, transcript: Transcript, template: BodyTemplate, transcriptLink: String?,
    producer: String, now: Date, timeZone: TimeZone
) -> String {
    let header = frontmatter(
        type: okfNoteType, title: facts.title, description: facts.description, tags: okfTags(facts.tags),
        facts: facts, producer: producer, now: now, timeZone: timeZone)
    let rendered = template.blocks.map { block in
        (block, markdown(block, facts: facts, transcript: transcript, transcriptLink: transcriptLink, timeZone: timeZone))
    }
    let body = withoutEmptySections(rendered).joined(separator: "\n\n")
    return header + "\n" + body + "\n"
}

private func withoutEmptySections(_ rendered: [(TemplateBlock, String?)]) -> [String] {
    rendered.indices.compactMap { index in
        let (block, text) = rendered[index]
        guard case .heading = block else { return text }
        let section = rendered[(index + 1)...].prefix { if case .heading = $0.0 { false } else { true } }
        return section.contains { $0.1 != nil } ? text : nil
    }
}

func transcriptDocument(
    _ facts: NoteFacts, transcript: Transcript, style: TranscriptStyle, notePath: String,
    producer: String, now: Date, timeZone: TimeZone
) -> String {
    let header = frontmatter(
        type: okfTranscriptType, title: "Transcripción: \(facts.title)",
        description: "Transcripción completa de «\(facts.title)».", tags: [],
        facts: facts, producer: producer, now: now, timeZone: timeZone)
    let back = "De la nota [\(linkText(facts.title))](/\(notePath))."
    let body = [back, markdownTranscript(transcript, style: style)].compactMap { $0 }.joined(separator: "\n\n")
    return header + "\n" + body + "\n"
}

private func frontmatter(
    type: String, title: String, description: String, tags: [String], facts: NoteFacts,
    producer: String, now: Date, timeZone: TimeZone
) -> String {
    var lines = [
        "type: \(type)",
        "title: \(yamlQuoted(title))",
        "description: \(yamlQuoted(description))",
    ]
    if !tags.isEmpty { lines.append("tags: [\(tags.joined(separator: ", "))]") }
    lines.append("recorded_at: \(iso8601(facts.startedAt, timeZone: timeZone))")
    if let duration = facts.duration { lines.append("duration: \(Int(duration.rounded()))") }
    if !facts.speakers.isEmpty {
        lines.append("speakers: [\(facts.speakers.map(yamlQuoted).joined(separator: ", "))]")
    }
    lines.append("escriba_key: \(yamlQuoted(facts.key))")
    lines.append(
        "generated: { by: \(yamlQuoted(producer)), at: \(iso8601(now, timeZone: TimeZone(identifier: "UTC")!)) }")
    return "---\n" + lines.joined(separator: "\n") + "\n---\n"
}

private func markdown(
    _ block: TemplateBlock, facts: NoteFacts, transcript: Transcript, transcriptLink: String?,
    timeZone: TimeZone
) -> String? {
    switch block {
    case .text(let text):
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    case .heading(let text):
        return "# \(text)"
    case .summary:
        return facts.summary
    case .transcript(let style):
        if let transcriptLink { return "[Transcripción completa](\(transcriptLink))" }
        return markdownTranscript(transcript, style: style)
    case .audio:
        return "[Audio](\(facts.source.absoluteString))"
    case .field(let field):
        return fieldValue(field, of: facts, timeZone: timeZone).map { "**\(field.label):** \($0)" }
    }
}

private func fieldValue(_ field: NoteField, of facts: NoteFacts, timeZone: TimeZone) -> String? {
    switch field {
    case .title: facts.title
    case .date: longDate(facts.startedAt, timeZone: timeZone)
    case .speakers: facts.speakers.isEmpty ? nil : facts.speakers.joined(separator: ", ")
    case .duration: facts.duration.map(durationClock)
    case .key: facts.key
    case .source: facts.source.path(percentEncoded: false)
    case .summary: facts.summary
    case .tags: facts.tags.isEmpty ? nil : facts.tags.joined(separator: ", ")
    }
}

func markdownTranscript(_ transcript: Transcript, style: TranscriptStyle) -> String? {
    let paragraphs = transcript.turns.flatMap { turn -> [String] in
        let lines = turn.text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard let first = lines.first else { return [] }
        let lead = prefix(of: turn, style: style).map { "**\($0):** \(first)" } ?? first
        return [lead] + lines.dropFirst()
    }
    return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
}

private func prefix(of turn: TranscriptTurn, style: TranscriptStyle) -> String? {
    switch style {
    case .plain:
        return nil
    case .speakers:
        return turn.speaker
    case .timestamps:
        guard let start = turn.start else { return turn.speaker }
        return turn.speaker.map { "\(bracketStamp(start)) \($0)" } ?? bracketStamp(start)
    }
}

public func okfDescription(summary: String?) -> String? {
    guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
        return nil
    }
    let line = summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? summary
    let sentence = firstSentence(of: line)
    guard sentence.count > okfDescriptionLimit else { return sentence }
    var taken = ""
    for word in sentence.split(whereSeparator: \.isWhitespace) {
        let next = taken.isEmpty ? String(word) : taken + " " + word
        guard next.count < okfDescriptionLimit else { break }
        taken = next
    }
    return (taken.isEmpty ? String(sentence.prefix(okfDescriptionLimit - 1)) : taken) + "…"
}

private func firstSentence(of line: String) -> String {
    var index = line.startIndex
    while index < line.endIndex {
        let next = line.index(after: index)
        if ".?!".contains(line[index]), next == line.endIndex || line[next].isWhitespace {
            return String(line[...index])
        }
        index = next
    }
    return line
}

public func okfTags(_ raw: [String]) -> [String] {
    var seen: Set<String> = []
    return raw.map { asciiWords($0).joined(separator: "-") }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
}

public func slug(_ text: String) -> String {
    var result = ""
    for word in asciiWords(text) {
        let next = result.isEmpty ? word : result + "-" + word
        guard next.count <= okfSlugLimit else {
            if result.isEmpty { result = String(word.prefix(okfSlugLimit)) }
            break
        }
        result = next
    }
    return result.isEmpty ? "nota" : result
}

public func okfFileName(title: String, startedAt: Date, timeZone: TimeZone) -> String {
    "\(isoDay(startedAt, timeZone: timeZone))-\(slug(title)).md"
}

private func asciiWords(_ text: String) -> [String] {
    let folded = text
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        .lowercased()
    var words: [String] = []
    var current = ""
    for scalar in folded.unicodeScalars {
        if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) {
            current.unicodeScalars.append(scalar)
        } else if !current.isEmpty {
            words.append(current)
            current = ""
        }
    }
    if !current.isEmpty { words.append(current) }
    return words
}

func linkText(_ text: String) -> String {
    text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
}

func yamlQuoted(_ text: String) -> String {
    let flat = text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
    let escaped = flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private let monthNames = [
    "enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
]

func monthHeading(year: Int, month: Int) -> String {
    guard (1...12).contains(month) else { return "\(year)" }
    return monthNames[month - 1].prefix(1).uppercased() + monthNames[month - 1].dropFirst() + " de \(year)"
}

private func calendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

func isoDay(_ date: Date, timeZone: TimeZone) -> String {
    let parts = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

private func longDate(_ date: Date, timeZone: TimeZone) -> String {
    let parts = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let month = monthNames[max(0, min(11, (parts.month ?? 1) - 1))]
    let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    return "\(parts.day ?? 0) de \(month) de \(parts.year ?? 0), \(time)"
}

private func iso8601(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    return formatter.string(from: date)
}
