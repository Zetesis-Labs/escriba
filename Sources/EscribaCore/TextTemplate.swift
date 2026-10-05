import Foundation

public enum TemplateToken: Hashable, Sendable {
    case title
    case description
    case summary
    case tags
    case date
    case isoDate
    case day
    case speakers
    case duration
    case seconds
    case key
    case source
    case audio
    case transcript(TranscriptStyle)
    case link(String)

    public static let catalog: [TemplateToken] = [
        .title, .description, .summary, .tags, .date, .isoDate, .day, .speakers, .duration, .seconds,
        .key, .source, .audio, .transcript(.speakers), .transcript(.timestamps), .transcript(.plain),
    ]

    public static let pathCatalog: [TemplateToken] = [.day, .title, .key]

    public var marker: String {
        switch self {
        case .title: "titulo"
        case .description: "descripcion"
        case .summary: "resumen"
        case .tags: "etiquetas"
        case .date: "fecha"
        case .isoDate: "fecha-iso"
        case .day: "dia"
        case .speakers: "hablantes"
        case .duration: "duracion"
        case .seconds: "segundos"
        case .key: "clave"
        case .source: "origen"
        case .audio: "audio"
        case .transcript(.speakers): "transcripcion"
        case .transcript(.timestamps): "transcripcion-tiempos"
        case .transcript(.plain): "transcripcion-texto"
        case .link(let id): "enlace:\(id)"
        }
    }

    public init?(marker: String) {
        if marker.hasPrefix("enlace:") {
            let id = String(marker.dropFirst("enlace:".count))
            guard !id.isEmpty else { return nil }
            self = .link(id)
            return
        }
        guard let token = Self.catalog.first(where: { $0.marker == marker }) else { return nil }
        self = token
    }

    public func label(names: [String: String] = [:]) -> String {
        switch self {
        case .title: "Título"
        case .description: "Descripción"
        case .summary: "Resumen"
        case .tags: "Etiquetas"
        case .date: "Fecha"
        case .isoDate: "Fecha ISO"
        case .day: "Día"
        case .speakers: "Hablantes"
        case .duration: "Duración"
        case .seconds: "Segundos"
        case .key: "Clave"
        case .source: "Fichero de origen"
        case .audio: "Audio"
        case .transcript(.speakers): "Transcripción"
        case .transcript(.timestamps): "Transcripción con tiempos"
        case .transcript(.plain): "Transcripción (solo texto)"
        case .link(let id): names[id].map { "Enlace a «\($0)»" } ?? "Enlace a un documento que ya no existe"
        }
    }

    public var help: String {
        switch self {
        case .title: "El título del resumen, o el principio del texto"
        case .description: "La primera frase del resumen"
        case .summary: "El resumen completo"
        case .tags: "Las etiquetas del resumen"
        case .date: "Fecha y hora, para leer"
        case .isoDate: "Fecha y hora en ISO 8601"
        case .day: "AAAA-MM-DD, para nombres de fichero"
        case .speakers: "Quién habla"
        case .duration: "mm:ss"
        case .seconds: "La duración en segundos"
        case .key: "El identificador de la grabación"
        case .source: "La ruta del fichero de audio"
        case .audio: "Enlace al fichero de audio"
        case .transcript(.speakers): "Un párrafo por hablante"
        case .transcript(.timestamps): "Cada párrafo con su minuto"
        case .transcript(.plain): "Sin hablantes ni tiempos"
        case .link: "Enlace a ese documento de la misma grabación"
        }
    }
}

public enum TemplatePiece: Hashable, Sendable {
    case text(String)
    case token(TemplateToken)
}

public func templatePieces(_ source: String) -> [TemplatePiece] {
    var pieces: [TemplatePiece] = []
    var literal = ""
    var rest = Substring(source)
    while let open = rest.range(of: "{{") {
        literal += rest[..<open.lowerBound]
        let afterOpen = rest[open.upperBound...]
        guard let close = afterOpen.range(of: "}}"),
            let token = TemplateToken(marker: String(afterOpen[..<close.lowerBound]))
        else {
            literal += "{{"
            rest = afterOpen
            continue
        }
        if !literal.isEmpty { pieces.append(.text(literal)) }
        literal = ""
        pieces.append(.token(token))
        rest = afterOpen[close.upperBound...]
    }
    literal += rest
    if !literal.isEmpty { pieces.append(.text(literal)) }
    return pieces
}

public func templateSource(_ pieces: [TemplatePiece]) -> String {
    pieces.map { piece in
        switch piece {
        case .text(let text): text
        case .token(let token): "{{\(token.marker)}}"
        }
    }.joined()
}

public enum TemplateContext: Sendable {
    case body
    case property
    case path
}

public struct LinkTarget: Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct TokenSuggestion: Equatable, Sendable, Identifiable {
    public let token: TemplateToken
    public let label: String
    public let help: String

    public var id: String { token.marker }
}

public func tokenSuggestions(
    matching query: String, in context: TemplateContext, links: [LinkTarget] = [], excluding current: String? = nil
) -> [TokenSuggestion] {
    let names = Dictionary(links.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let candidates: [TemplateToken] =
        switch context {
        case .path: TemplateToken.pathCatalog
        case .body, .property: TemplateToken.catalog + links.filter { $0.id != current }.map { .link($0.id) }
        }
    let needle = folded(query)
    return candidates
        .map { TokenSuggestion(token: $0, label: $0.label(names: names), help: $0.help) }
        .filter { suggestion in
            needle.isEmpty
                || folded(suggestion.token.marker).hasPrefix(needle)
                || folded(suggestion.label).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .contains { $0.hasPrefix(needle) }
        }
}

private func folded(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        .trimmingCharacters(in: .whitespaces)
}
