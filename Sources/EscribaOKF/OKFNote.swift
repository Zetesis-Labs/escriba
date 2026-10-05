import Foundation
import EscribaCore

public let okfSlugLimit = 60
public let okfDescriptionLimit = 200

public struct OKFProperty: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var key: String
    public var value: String

    public init(id: String = UUID().uuidString, key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

public struct OKFDocument: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var properties: [OKFProperty]
    public var body: String

    public init(id: String = UUID().uuidString, name: String, path: String, properties: [OKFProperty], body: String) {
        self.id = id
        self.name = name
        self.path = path
        self.properties = properties
        self.body = body
    }

    public var type: String? { properties.first { $0.key.trimmingCharacters(in: .whitespaces) == "type" }?.value }
}

public struct OKFExport: Equatable, Sendable, Codable {
    public var folder: String
    public var documents: [OKFDocument]

    public init(folder: String, documents: [OKFDocument] = OKFExport.standardDocuments()) {
        self.folder = folder
        self.documents = documents
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decode(String.self, forKey: .folder)
        documents = try container.decodeIfPresent([OKFDocument].self, forKey: .documents)
            ?? OKFExport.standardDocuments()
    }

    public var isUsable: Bool { okfProblem(self) == nil }

    public static func standardDocuments(
        noteID: String = UUID().uuidString, transcriptID: String = UUID().uuidString
    ) -> [OKFDocument] {
        let recording = [("recorded_at", "{{fecha-iso}}"), ("duration", "{{segundos}}"), ("speakers", "{{hablantes}}")]
        return [
            OKFDocument(
                id: noteID, name: "Nota", path: "notas/{{dia}}-{{titulo}}.md",
                properties: properties(
                    [("type", "Nota de voz"), ("title", "{{titulo}}"), ("description", "{{descripcion}}"),
                     ("tags", "{{etiquetas}}")] + recording),
                body: "# Resumen\n\n{{resumen}}\n\n# Transcripción\n\n{{enlace:\(transcriptID)}}"),
            OKFDocument(
                id: transcriptID, name: "Transcripción", path: "transcripciones/{{dia}}-{{titulo}}.md",
                properties: properties(
                    [("type", "Transcripción"), ("title", "Transcripción: {{titulo}}"),
                     ("description", "Transcripción completa de «{{titulo}}».")] + recording),
                body: "De la nota {{enlace:\(noteID)}}.\n\n{{transcripcion}}"),
        ]
    }

    public static func newDocument(number: Int) -> OKFDocument {
        OKFDocument(
            name: "Documento \(number)", path: "documentos/{{dia}}-{{titulo}}.md",
            properties: properties([("type", "Documento"), ("title", "{{titulo}}")]),
            body: "{{resumen}}")
    }

    private static func properties(_ pairs: [(String, String)]) -> [OKFProperty] {
        pairs.map { OKFProperty(key: $0.0, value: $0.1) }
    }
}

public func okfProblem(_ export: OKFExport) -> String? {
    guard !export.folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Elige la carpeta donde guardar las notas."
    }
    guard !export.documents.isEmpty else { return "Añade al menos un documento." }
    for document in export.documents
    where document.type?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
        return "«\(document.name)» necesita un valor en type: OKF lo exige."
    }
    for (index, document) in export.documents.enumerated() {
        if let twin = export.documents[(index + 1)...].first(where: { normalized($0.path) == normalized(document.path) }) {
            return "«\(document.name)» y «\(twin.name)» escriben en la misma ruta."
        }
    }
    return nil
}

private func normalized(_ path: String) -> String {
    path.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
    let transcript: Transcript
    let timeZone: TimeZone
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
        source: note.recording.url,
        transcript: note.transcript,
        timeZone: timeZone)
}

struct RenderedLink {
    let path: String
    let title: String
}

func inlineValue(_ token: TemplateToken, of facts: NoteFacts, links: [String: RenderedLink]) -> String {
    switch token {
    case .title: facts.title
    case .description: facts.description
    case .summary: facts.summary ?? ""
    case .tags: facts.tags.joined(separator: ", ")
    case .date: longDate(facts.startedAt, timeZone: facts.timeZone)
    case .isoDate: iso8601(facts.startedAt, timeZone: facts.timeZone)
    case .day: isoDay(facts.startedAt, timeZone: facts.timeZone)
    case .speakers: facts.speakers.joined(separator: ", ")
    case .duration: facts.duration.map(durationClock) ?? ""
    case .seconds: facts.duration.map { "\(Int($0.rounded()))" } ?? ""
    case .key: facts.key
    case .source: facts.source.path(percentEncoded: false)
    case .audio: facts.source.absoluteString
    case .transcript: facts.transcript.rendered
    case .link(let id): links[id].map { "/\($0.path)" } ?? ""
    }
}

private func bodyValue(_ token: TemplateToken, of facts: NoteFacts, links: [String: RenderedLink]) -> String {
    switch token {
    case .transcript(let style): markdownTranscript(facts.transcript, style: style) ?? ""
    case .audio: "[Audio](\(facts.source.absoluteString))"
    case .link(let id): links[id].map { "[\(linkText($0.title))](/\($0.path))" } ?? ""
    default: inlineValue(token, of: facts, links: links)
    }
}

func renderedInline(_ template: String, of facts: NoteFacts, links: [String: RenderedLink]) -> String {
    templatePieces(template).map { piece in
        switch piece {
        case .text(let text): text
        case .token(let token): inlineValue(token, of: facts, links: links)
        }
    }.joined()
}

func renderedPath(_ template: String, of facts: NoteFacts) -> String {
    let raw = templatePieces(template).map { piece in
        switch piece {
        case .text(let text): text
        case .token(.day): isoDay(facts.startedAt, timeZone: facts.timeZone)
        case .token(let token): slug(inlineValue(token, of: facts, links: [:]))
        }
    }.joined()
    let segments = raw.split(separator: "/")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    guard !segments.isEmpty else { return "nota.md" }
    let path = segments.joined(separator: "/")
    return path.lowercased().hasSuffix(".md") ? path : path + ".md"
}

func documentTitle(_ document: OKFDocument, of facts: NoteFacts) -> String {
    let title = document.properties.first { $0.key.trimmingCharacters(in: .whitespaces) == "title" }
        .map { renderedInline($0.value, of: facts, links: [:]).trimmingCharacters(in: .whitespaces) }
    return title.flatMap { $0.isEmpty ? nil : $0 } ?? facts.title
}

func documentDescription(_ document: OKFDocument, of facts: NoteFacts) -> String? {
    document.properties.first { $0.key.trimmingCharacters(in: .whitespaces) == "description" }
        .map { renderedInline($0.value, of: facts, links: [:]).trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
}

private let reservedKeys: Set<String> = ["type", "escriba_key", "generated"]

func documentContents(
    _ document: OKFDocument, of facts: NoteFacts, links: [String: RenderedLink], producer: String, now: Date
) -> String {
    let type = document.type.map { renderedInline($0, of: facts, links: links).trimmingCharacters(in: .whitespaces) }
    var lines = ["type: \(yamlPlainOrQuoted(type.flatMap { $0.isEmpty ? nil : $0 } ?? "Documento"))"]
    lines += document.properties.compactMap { yamlLine($0, of: facts, links: links) }
    lines.append("escriba_key: \(yamlQuoted(facts.key))")
    lines.append(
        "generated: { by: \(yamlQuoted(producer)), at: \(iso8601(now, timeZone: TimeZone(identifier: "UTC")!)) }")
    let header = "---\n" + lines.joined(separator: "\n") + "\n---\n"
    let body = renderedBody(document.body, of: facts, links: links)
    return body.isEmpty ? header : header + "\n" + body + "\n"
}

private func yamlLine(_ property: OKFProperty, of facts: NoteFacts, links: [String: RenderedLink]) -> String? {
    let key = property.key.trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty, !reservedKeys.contains(key) else { return nil }
    let pieces = templatePieces(property.value).filter { piece in
        if case .text(let text) = piece { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }
    if pieces.count == 1, case .token(let token) = pieces[0], let typed = typedValue(token, of: facts) {
        return typed.isEmpty ? nil : "\(yamlKey(key)): \(typed)"
    }
    let value = renderedInline(property.value, of: facts, links: links).trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : "\(yamlKey(key)): \(yamlQuoted(value))"
}

private func typedValue(_ token: TemplateToken, of facts: NoteFacts) -> String? {
    switch token {
    case .tags:
        let tags = okfTags(facts.tags)
        return tags.isEmpty ? "" : "[\(tags.joined(separator: ", "))]"
    case .speakers:
        return facts.speakers.isEmpty ? "" : "[\(facts.speakers.map(yamlQuoted).joined(separator: ", "))]"
    case .seconds:
        return facts.duration.map { "\(Int($0.rounded()))" } ?? ""
    case .isoDate:
        return iso8601(facts.startedAt, timeZone: facts.timeZone)
    default:
        return nil
    }
}

func renderedBody(_ template: String, of facts: NoteFacts, links: [String: RenderedLink]) -> String {
    let rendered = template.components(separatedBy: "\n").compactMap { line -> String? in
        let pieces = templatePieces(line)
        let hasToken = pieces.contains { if case .token = $0 { true } else { false } }
        let hasText = pieces.contains { piece in
            if case .text(let text) = piece { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
            return false
        }
        let value = pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .token(let token): bodyValue(token, of: facts, links: links)
            }
        }.joined()
        return hasToken && !hasText && value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
    let lines = rendered.joined(separator: "\n").components(separatedBy: "\n")
    return collapsedBlankLines(withoutEmptyHeadings(lines)).joined(separator: "\n")
}

private func headingLevel(_ line: String) -> Int? {
    guard let match = line.prefixMatch(of: /(#{1,6})(\s|$)/) else { return nil }
    return match.1.count
}

private func withoutEmptyHeadings(_ lines: [String]) -> [String] {
    var kept = Array(repeating: true, count: lines.count)
    for index in lines.indices.reversed() {
        guard let level = headingLevel(lines[index]) else { continue }
        var hasContent = false
        var next = index + 1
        while next < lines.count {
            if let inner = headingLevel(lines[next]) {
                if inner <= level { break }
                if kept[next] { hasContent = true }
            } else if !lines[next].trimmingCharacters(in: .whitespaces).isEmpty {
                hasContent = true
            }
            next += 1
        }
        let title = lines[index].drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        kept[index] = hasContent && !title.isEmpty
    }
    return lines.indices.filter { kept[$0] }.map { lines[$0] }
}

private func collapsedBlankLines(_ lines: [String]) -> [String] {
    var result: [String] = []
    for line in lines {
        let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
        if blank, result.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? true { continue }
        result.append(blank ? "" : line)
    }
    while result.last == "" { result.removeLast() }
    return result
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

private func yamlPlainOrQuoted(_ text: String) -> String {
    let unsafeStart = "-?:,[]{}#&*!|>'\"%@`"
    let safe = !text.isEmpty
        && text == text.trimmingCharacters(in: .whitespaces)
        && !unsafeStart.contains(text.first!)
        && !text.contains(": ") && !text.contains(" #") && !text.contains(where: \.isNewline)
    return safe ? text : yamlQuoted(text)
}

private func yamlKey(_ key: String) -> String {
    key.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_.\-]*/) != nil ? key : yamlQuoted(key)
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
