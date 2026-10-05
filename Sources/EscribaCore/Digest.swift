import Foundation

public struct Digest: Sendable, Equatable, Codable {
    public let title: String
    public let summary: String
    public let tags: [String]

    public init(title: String, summary: String, tags: [String]) {
        self.title = title
        self.summary = summary
        self.tags = tags
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public let digestTagLimit = 5
public let digestTitleLimit = 80

public func normalizedTags(_ raw: [String], limit: Int = digestTagLimit) -> [String] {
    var seen: Set<String> = []
    return raw
        .map { tag in
            tag.drop { $0 == "#" || $0.isWhitespace }
                .split { $0.isWhitespace || $0 == "," }
                .joined(separator: " ")
                .lowercased()
        }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .prefix(limit)
        .map { $0 }
}

public func normalizedDigest(_ digest: Digest) -> Digest {
    Digest(
        title: normalizedTitle(digest.title),
        summary: digest.summary.trimmingCharacters(in: .whitespacesAndNewlines),
        tags: normalizedTags(digest.tags))
}

private func normalizedTitle(_ raw: String) -> String {
    let words = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'«»"))
        .split(whereSeparator: \.isWhitespace)
        .map(String.init)
    var taken: [String] = []
    var length = 0
    for word in words {
        let next = taken.isEmpty ? word.count : length + 1 + word.count
        guard next <= digestTitleLimit - 1 else { break }
        length = next
        taken.append(word)
    }
    guard let first = words.first else { return "" }
    guard !taken.isEmpty else { return String(first.prefix(digestTitleLimit - 1)) + "…" }

    let joined = taken.joined(separator: " ")
    let trimmed = joined.hasSuffix(".") ? String(joined.dropLast()) : joined
    return taken.count < words.count ? trimmed + "…" : trimmed
}

public func digestChunks(of text: String, maxCharacters: Int) -> [String] {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return [] }
    guard body.count > maxCharacters else { return [body] }
    let paragraphs = body.split(whereSeparator: \.isNewline).map(String.init)
    return packed(paragraphs, separator: "\n", limit: maxCharacters) { paragraph in
        packed(sentences(of: paragraph), separator: " ", limit: maxCharacters) { sentence in
            packed(sentence.split(whereSeparator: \.isWhitespace).map(String.init), separator: " ", limit: maxCharacters) {
                hardSplit($0, every: maxCharacters)
            }
        }
    }
}

private func packed(
    _ pieces: [String], separator: String, limit: Int, oversized: (String) -> [String]
) -> [String] {
    var chunks: [String] = []
    var current = ""
    func flush() {
        if !current.isEmpty { chunks.append(current) }
        current = ""
    }
    for piece in pieces {
        if piece.count > limit {
            flush()
            chunks.append(contentsOf: oversized(piece))
            continue
        }
        let candidate = current.isEmpty ? piece : current + separator + piece
        if candidate.count <= limit {
            current = candidate
        } else {
            flush()
            current = piece
        }
    }
    flush()
    return chunks
}

private func sentences(of paragraph: String) -> [String] {
    var result: [String] = []
    var current = ""
    for character in paragraph {
        current.append(character)
        if ".!?".contains(character) {
            result.append(current)
            current = ""
        }
    }
    if !current.isEmpty { result.append(current) }
    return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

private func hardSplit(_ word: String, every limit: Int) -> [String] {
    guard limit > 0 else { return [word] }
    var pieces: [String] = []
    var rest = Substring(word)
    while !rest.isEmpty {
        pieces.append(String(rest.prefix(limit)))
        rest = rest.dropFirst(limit)
    }
    return pieces
}

public enum DigestPrompt {
    public static let standard = """
        Eres un asistente que lee la transcripción de una nota de voz o de una reunión \
        y devuelve un título, un resumen y unas etiquetas. \
        El título es breve y concreto, sin comillas. El resumen es fiel al contenido, \
        de tres a cinco frases y nunca más de 600 caracteres, sin inventar nada que no \
        esté en el texto. \
        Las etiquetas son de dos a cinco temas cortos, en minúsculas.
        """

    public static func instructions(language: String?, base: String? = nil) -> String {
        let idiom = languageName(language).map { "Responde en \($0)." }
            ?? "Responde en el mismo idioma en que está escrita la transcripción."
        let custom = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (custom.isEmpty ? standard : custom) + "\n\n" + idiom
    }

    public static func request(text: String) -> String {
        "Transcripción:\n\(text)"
    }

    public static func reduce(partials: [String]) -> String {
        "Resúmenes parciales, en orden, de una misma grabación. Únelos en un solo título, resumen y etiquetas:\n\n"
            + partials.joined(separator: "\n\n")
    }

    private static func languageName(_ code: String?) -> String? {
        switch code?.lowercased() {
        case "es": "español"
        case "en": "inglés"
        case "eu": "euskera"
        case "ca": "catalán"
        case "gl": "gallego"
        case "fr": "francés"
        case "de": "alemán"
        case "it": "italiano"
        case "pt": "portugués"
        default: nil
        }
    }
}

public struct DigestRequest: Sendable, Equatable {
    public let instructions: String
    public let prompt: String

    public init(instructions: String, prompt: String) {
        self.instructions = instructions
        self.prompt = prompt
    }
}

public func digestRequest(text: String, language: String?, prompt: String? = nil) -> DigestRequest {
    DigestRequest(
        instructions: DigestPrompt.instructions(language: language, base: prompt),
        prompt: DigestPrompt.request(text: text))
}

public func reduceRequest(partials: [String], language: String?, prompt: String? = nil) -> DigestRequest {
    DigestRequest(
        instructions: DigestPrompt.instructions(language: language, base: prompt),
        prompt: DigestPrompt.reduce(partials: partials))
}

extension Digest {
    public var rendered: String {
        [
            title.isEmpty ? nil : "Título: \(title)",
            summary.isEmpty ? nil : "Resumen: \(summary)",
            tags.isEmpty ? nil : "Etiquetas: \(tags.joined(separator: ", "))",
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}
