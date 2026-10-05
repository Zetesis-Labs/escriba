import Foundation

public enum TranscriptStyle: String, CaseIterable, Sendable, Codable {
    case plain
    case speakers
    case timestamps

    public var label: String {
        switch self {
        case .plain: "Solo el texto"
        case .speakers: "Un párrafo por hablante"
        case .timestamps: "Con marca de tiempo"
        }
    }
}

public enum NoteField: String, CaseIterable, Sendable, Codable {
    case title
    case date
    case speakers
    case duration
    case key
    case source
    case summary
    case tags

    public var label: String {
        switch self {
        case .title: "Título"
        case .date: "Fecha de la grabación"
        case .speakers: "Hablantes"
        case .duration: "Duración (segundos)"
        case .key: "Clave de la grabación"
        case .source: "Fichero de origen"
        case .summary: "Resumen"
        case .tags: "Etiquetas"
        }
    }
}

public enum TemplateBlock: Equatable, Sendable, Codable, Hashable {
    case text(String)
    case heading(String)
    case transcript(TranscriptStyle)
    case summary
    case audio
    case field(NoteField)
}

public struct BodyTemplate: Equatable, Sendable, Codable, Hashable {
    public var blocks: [TemplateBlock]

    public init(_ blocks: [TemplateBlock]) {
        self.blocks = blocks
    }
}
