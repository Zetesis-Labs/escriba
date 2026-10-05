import Foundation

public let noteDescriptionLimit = 200

public struct NoteValues: Sendable {
    public let title: String
    public let description: String
    public let summary: String?
    public let tags: [String]
    public let key: String
    public let startedAt: Date
    public let speakers: [String]
    public let duration: TimeInterval?
    public let source: URL
    public let transcript: Transcript
    public let timeZone: TimeZone

    public init(_ note: Note, timeZone: TimeZone) {
        let summary = note.digest?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        title = noteTitle(digest: note.digest, key: note.recording.key, text: note.transcript.text)
        description = noteDescription(summary: summary)
            ?? "Grabación del \(longDate(note.recording.startedAt, timeZone: timeZone))."
        self.summary = summary.flatMap { $0.isEmpty ? nil : $0 }
        tags = note.digest?.tags ?? []
        key = note.recording.key
        startedAt = note.recording.startedAt
        speakers = note.transcript.speakers
        duration = note.transcript.duration
        source = note.recording.url
        transcript = note.transcript
        self.timeZone = timeZone
    }

    public func inline(_ token: TemplateToken) -> String {
        switch token {
        case .title: title
        case .description: description
        case .summary: summary ?? ""
        case .tags: tags.joined(separator: ", ")
        case .date: longDate(startedAt, timeZone: timeZone)
        case .isoDate: iso8601(startedAt, timeZone: timeZone)
        case .day: isoDay(startedAt, timeZone: timeZone)
        case .speakers: speakers.joined(separator: ", ")
        case .duration: duration.map(durationClock) ?? ""
        case .seconds: duration.map { "\(Int($0.rounded()))" } ?? ""
        case .key: key
        case .source: source.path(percentEncoded: false)
        case .audio: source.absoluteString
        case .transcript: transcript.rendered
        case .link: ""
        }
    }

    public func inline(_ template: String, link: (String) -> String = { _ in "" }) -> String {
        templatePieces(template).map { piece in
            switch piece {
            case .text(let text): text
            case .token(.link(let id)): link(id)
            case .token(let token): inline(token)
            }
        }.joined()
    }
}

public func soleToken(of template: String) -> TemplateToken? {
    let pieces = templatePieces(template).filter { piece in
        if case .text(let text) = piece { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }
    guard pieces.count == 1, case .token(let token) = pieces[0] else { return nil }
    return token
}

public func noteDescription(summary: String?) -> String? {
    guard let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
        return nil
    }
    let line = summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? summary
    let sentence = firstSentence(of: line)
    guard sentence.count > noteDescriptionLimit else { return sentence }
    var taken = ""
    for word in sentence.split(whereSeparator: \.isWhitespace) {
        let next = taken.isEmpty ? String(word) : taken + " " + word
        guard next.count < noteDescriptionLimit else { break }
        taken = next
    }
    return (taken.isEmpty ? String(sentence.prefix(noteDescriptionLimit - 1)) : taken) + "…"
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

public func withoutEmptySections<Item>(
    _ items: [Item], level: (Item) -> Int?, isBlank: (Item) -> Bool
) -> [Item] {
    var kept = Array(repeating: true, count: items.count)
    for index in items.indices.reversed() {
        guard let own = level(items[index]) else { continue }
        var hasContent = false
        var next = index + 1
        while next < items.count {
            if let inner = level(items[next]) {
                if inner <= own { break }
                if kept[next] { hasContent = true }
            } else if !isBlank(items[next]) {
                hasContent = true
            }
            next += 1
        }
        kept[index] = hasContent
    }
    return items.indices.filter { kept[$0] }.map { items[$0] }
}

public func markdownHeadingLevel(_ line: String) -> Int? {
    guard let match = line.prefixMatch(of: /(#{1,6})(\s|$)/) else { return nil }
    return match.1.count
}

private let monthNames = [
    "enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
]

public func monthHeading(year: Int, month: Int) -> String {
    guard (1...12).contains(month) else { return "\(year)" }
    return monthNames[month - 1].prefix(1).uppercased() + monthNames[month - 1].dropFirst() + " de \(year)"
}

private func calendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

public func isoDay(_ date: Date, timeZone: TimeZone) -> String {
    let parts = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

public func longDate(_ date: Date, timeZone: TimeZone) -> String {
    let parts = calendar(timeZone).dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let month = monthNames[max(0, min(11, (parts.month ?? 1) - 1))]
    let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    return "\(parts.day ?? 0) de \(month) de \(parts.year ?? 0), \(time)"
}

public func iso8601(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    return formatter.string(from: date)
}

public func sampleNote(recordedAt: Date) -> Note {
    Note(
        recording: Recording(
            url: URL(fileURLWithPath: "/Notas de voz/Reunion del lanzamiento.m4a"),
            startedAt: recordedAt, key: "ejemplo"),
        transcript: Transcript(segments: [
            TranscriptSegment(start: 0, end: 8, speaker: "Ana", text: "¿Cómo vamos con el lanzamiento del jueves?"),
            TranscriptSegment(start: 8, end: 21, speaker: "Luis", text: "La migración no llega; propongo moverla una semana."),
            TranscriptSegment(start: 21, end: 29, speaker: "Ana", text: "Vale, y avisamos a soporte hoy mismo."),
        ]),
        digest: Digest(
            title: "Lanzamiento del jueves",
            summary: "Ana y Luis repasan el lanzamiento del jueves. Acuerdan mover la migración una semana y avisar hoy a soporte.",
            tags: ["lanzamiento", "migración"]))
}

public func textTemplate(from template: BodyTemplate) -> String {
    template.blocks.compactMap { block -> String? in
        switch block {
        case .text(let text): text.isEmpty ? nil : text
        case .heading(let text): text.isEmpty ? nil : "# \(text)"
        case .transcript(let style): "{{\(TemplateToken.transcript(style).marker)}}"
        case .summary: "{{resumen}}"
        case .audio: "{{audio}}"
        case .field(let field): "**\(field.label):** {{\(token(for: field).marker)}}"
        }
    }.joined(separator: "\n\n")
}

public func token(for field: NoteField) -> TemplateToken {
    switch field {
    case .title: .title
    case .date: .date
    case .speakers: .speakers
    case .duration: .duration
    case .key: .key
    case .source: .source
    case .summary: .summary
    case .tags: .tags
    }
}
