import Foundation
import EscribaCore

public let okfSlugLimit = 60

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

struct RenderedLink {
    let path: String
    let title: String
}

private func bodyValue(_ token: TemplateToken, of values: NoteValues, links: [String: RenderedLink]) -> String {
    switch token {
    case .transcript(let style): markdownTranscript(values.transcript, style: style) ?? ""
    case .audio: "[Audio](\(values.source.absoluteString))"
    case .link(let id): links[id].map { "[\(linkText($0.title))](/\($0.path))" } ?? ""
    default: values.inline(token)
    }
}

func renderedInline(_ template: String, of values: NoteValues, links: [String: RenderedLink]) -> String {
    values.inline(template) { id in links[id].map { "/\($0.path)" } ?? "" }
}

func renderedPath(_ template: String, of values: NoteValues) -> String {
    let raw = templatePieces(template).map { piece in
        switch piece {
        case .text(let text): text
        case .token(.day): isoDay(values.startedAt, timeZone: values.timeZone)
        case .token(let token): slug(values.inline(token))
        }
    }.joined()
    let segments = raw.split(separator: "/")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
    guard !segments.isEmpty else { return "nota.md" }
    let path = segments.joined(separator: "/")
    return path.lowercased().hasSuffix(".md") ? path : path + ".md"
}

func documentTitle(_ document: OKFDocument, of values: NoteValues) -> String {
    let title = document.properties.first { $0.key.trimmingCharacters(in: .whitespaces) == "title" }
        .map { renderedInline($0.value, of: values, links: [:]).trimmingCharacters(in: .whitespaces) }
    return title.flatMap { $0.isEmpty ? nil : $0 } ?? values.title
}

func documentDescription(_ document: OKFDocument, of values: NoteValues) -> String? {
    document.properties.first { $0.key.trimmingCharacters(in: .whitespaces) == "description" }
        .map { renderedInline($0.value, of: values, links: [:]).trimmingCharacters(in: .whitespaces) }
        .flatMap { $0.isEmpty ? nil : $0 }
}

private let reservedKeys: Set<String> = ["type", "escriba_key", "generated"]

func documentContents(
    _ document: OKFDocument, of values: NoteValues, links: [String: RenderedLink], producer: String, now: Date
) -> String {
    let type = document.type.map { renderedInline($0, of: values, links: links).trimmingCharacters(in: .whitespaces) }
    var lines = ["type: \(yamlPlainOrQuoted(type.flatMap { $0.isEmpty ? nil : $0 } ?? "Documento"))"]
    lines += document.properties.compactMap { yamlLine($0, of: values, links: links) }
    lines.append("escriba_key: \(yamlQuoted(values.key))")
    lines.append(
        "generated: { by: \(yamlQuoted(producer)), at: \(iso8601(now, timeZone: TimeZone(identifier: "UTC")!)) }")
    let header = "---\n" + lines.joined(separator: "\n") + "\n---\n"
    let body = renderedBody(document.body, of: values, links: links)
    return body.isEmpty ? header : header + "\n" + body + "\n"
}

private func yamlLine(_ property: OKFProperty, of values: NoteValues, links: [String: RenderedLink]) -> String? {
    let key = property.key.trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty, !reservedKeys.contains(key) else { return nil }
    let pieces = templatePieces(property.value).filter { piece in
        if case .text(let text) = piece { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }
    if pieces.count == 1, case .token(let token) = pieces[0], let typed = typedValue(token, of: values) {
        return typed.isEmpty ? nil : "\(yamlKey(key)): \(typed)"
    }
    let value = renderedInline(property.value, of: values, links: links).trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : "\(yamlKey(key)): \(yamlQuoted(value))"
}

private func typedValue(_ token: TemplateToken, of values: NoteValues) -> String? {
    switch token {
    case .tags:
        let tags = okfTags(values.tags)
        return tags.isEmpty ? "" : "[\(tags.joined(separator: ", "))]"
    case .speakers:
        return values.speakers.isEmpty ? "" : "[\(values.speakers.map(yamlQuoted).joined(separator: ", "))]"
    case .seconds:
        return values.duration.map { "\(Int($0.rounded()))" } ?? ""
    case .isoDate:
        return iso8601(values.startedAt, timeZone: values.timeZone)
    default:
        return nil
    }
}

func renderedBody(_ template: String, of values: NoteValues, links: [String: RenderedLink]) -> String {
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
            case .token(let token): bodyValue(token, of: values, links: links)
            }
        }.joined()
        return hasToken && !hasText && value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
    }
    let lines = rendered.joined(separator: "\n").components(separatedBy: "\n").filter { line in
        markdownHeadingLevel(line) == nil || !line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).isEmpty
    }
    let sections = withoutEmptySections(
        lines, level: markdownHeadingLevel, isBlank: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    return collapsedBlankLines(sections).joined(separator: "\n")
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
