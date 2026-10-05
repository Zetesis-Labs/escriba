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

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    public var isTranscript: Bool {
        if case .transcript = self { return true }
        return false
    }

    public func label(transcriptAsLink: Bool = false) -> String {
        switch self {
        case .text(let text): text
        case .heading(let text): "Encabezado: \(text)"
        case .transcript(let style) where transcriptAsLink:
            "Enlace a la transcripción completa · \(style.label.lowercased())"
        case .transcript(let style): "Transcripción completa · \(style.label.lowercased())"
        case .summary: "Texto del resumen"
        case .audio: "Audio de la grabación"
        case .field(let field): "Dato: \(field.label)"
        }
    }
}

public struct BodyTemplate: Equatable, Sendable, Codable, Hashable {
    public var blocks: [TemplateBlock]

    public init(_ blocks: [TemplateBlock]) {
        self.blocks = blocks
    }

    public static let standard = BodyTemplate([.transcript(.speakers)])

    public var needsAudio: Bool { blocks.contains(.audio) }

    public var transcriptStyle: TranscriptStyle? {
        for block in blocks {
            if case .transcript(let style) = block { return style }
        }
        return nil
    }

    public func inserting(_ block: TemplateBlock, at index: Int) -> BodyTemplate {
        var blocks = blocks
        blocks.insert(block, at: min(max(index, 0), blocks.count))
        return BodyTemplate(blocks)
    }

    public func removing(at index: Int) -> BodyTemplate {
        guard blocks.indices.contains(index) else { return self }
        var blocks = blocks
        blocks.remove(at: index)
        return BodyTemplate(blocks)
    }

    public func moving(from source: IndexSet, to destination: Int) -> BodyTemplate {
        BodyTemplate(moved(blocks, from: source, to: destination))
    }

    public func settingText(_ text: String, at index: Int) -> BodyTemplate {
        guard blocks.indices.contains(index) else { return self }
        switch blocks[index] {
        case .text: return replacing(at: index, with: .text(text)) ?? self
        case .heading: return replacing(at: index, with: .heading(text)) ?? self
        default: return self
        }
    }

    public func applying(command typed: String, at index: Int) -> BodyTemplate? {
        guard let block = templateBlock(forCommand: typed) else { return nil }
        return replacing(at: index, with: block)
    }

    public func togglingField(_ field: NoteField, on wanted: Bool) -> BodyTemplate {
        let present = blocks.firstIndex(of: .field(field))
        switch (wanted, present) {
        case (true, nil): return inserting(.field(field), at: blocks.firstIndex { !$0.isText } ?? blocks.count)
        case (false, let index?): return removing(at: index)
        default: return self
        }
    }

    private func replacing(at index: Int, with block: TemplateBlock) -> BodyTemplate? {
        guard blocks.indices.contains(index) else { return nil }
        var blocks = blocks
        blocks[index] = block
        return BodyTemplate(blocks)
    }
}

public func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
    let moving = source.sorted().compactMap { items.indices.contains($0) ? items[$0] : nil }
    var rest = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
    let before = source.filter { $0 < destination }.count
    rest.insert(contentsOf: moving, at: min(max(destination - before, 0), rest.count))
    return rest
}

public struct SlashCommand: Equatable, Sendable, Identifiable {
    public let command: String
    public let block: TemplateBlock
    public let help: String

    public var id: String { command }
}

public let slashCommands: [SlashCommand] = [
    SlashCommand(command: "/transcripcion", block: .transcript(.speakers), help: "Un párrafo por hablante"),
    SlashCommand(command: "/transcripcion-tiempos", block: .transcript(.timestamps), help: "Con marca de tiempo"),
    SlashCommand(command: "/transcripcion-texto", block: .transcript(.plain), help: "Solo el texto"),
    SlashCommand(command: "/resumen", block: .summary, help: "El resumen generado por el modelo"),
    SlashCommand(command: "/etiquetas", block: .field(.tags), help: "Las etiquetas del resumen"),
    SlashCommand(command: "/audio", block: .audio, help: "El fichero de audio, reproducible"),
    SlashCommand(command: "/encabezado", block: .heading("Encabezado"), help: "Un encabezado"),
    SlashCommand(command: "/titulo", block: .field(.title), help: "El título de la grabación"),
    SlashCommand(command: "/fecha", block: .field(.date), help: "Fecha y hora de la grabación"),
    SlashCommand(command: "/hablantes", block: .field(.speakers), help: "Quién habla"),
    SlashCommand(command: "/duracion", block: .field(.duration), help: "Cuánto dura"),
    SlashCommand(command: "/origen", block: .field(.source), help: "El fichero de origen"),
    SlashCommand(command: "/clave", block: .field(.key), help: "Identificador de la grabación"),
]

public func slashCommands(matching typed: String) -> [SlashCommand] {
    let needle = folded(typed)
    guard needle.hasPrefix("/") else { return [] }
    return slashCommands.filter { folded($0.command).hasPrefix(needle) }
}

public func templateBlock(forCommand typed: String) -> TemplateBlock? {
    slashCommands.first { folded($0.command) == folded(typed) }?.block
}

private func folded(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        .trimmingCharacters(in: .whitespaces)
}
