import Foundation
import EscribaCore

public enum TemplateBlock: Equatable, Sendable, Codable, Hashable {
    case text(String)
    case heading(String)
    case transcript(NotionBodyStyle)
    case audio
    case field(NotionField)

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .text(let text): text
        case .heading(let text): text
        case .transcript(let style): "Transcripción · \(style.label.lowercased())"
        case .audio: "Audio"
        case .field(let field): field.label
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

public func render(
    _ template: BodyTemplate, for page: NotionPage, transcript: Transcript, audio: String?,
    timeZone: TimeZone = .current
) -> [NotionBlock] {
    template.blocks.flatMap { block -> [NotionBlock] in
        switch block {
        case .text(let text):
            return text.isEmpty ? [] : notionBlocks(for: Transcript(text: text), style: .plain)
        case .heading(let text):
            return [NotionBlock(kind: .heading, runs: [NotionRun(text: text, bold: false)])]
        case .transcript(let style):
            return notionBlocks(for: transcript, style: style)
        case .audio:
            return audio.map { [NotionBlock(kind: .audio(uploadId: $0), runs: [])] } ?? []
        case .field(let field):
            return fieldValue(field, of: page, timeZone: timeZone).map {
                [NotionBlock(runs: [NotionRun(text: "\(field.label): ", bold: true), NotionRun(text: $0, bold: false)])]
            } ?? []
        }
    }
}

func fieldValue(_ field: NotionField, of page: NotionPage, timeZone: TimeZone) -> String? {
    switch field {
    case .title: page.title
    case .date: page.startedAt.formatted(.dateTime.day().month(.wide).year().hour().minute())
    case .speakers: page.speakers.isEmpty ? nil : page.speakers.joined(separator: ", ")
    case .duration: page.duration.map(clock)
    case .key: page.key
    case .source: page.source
    }
}

private func folded(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
        .trimmingCharacters(in: .whitespaces)
}
