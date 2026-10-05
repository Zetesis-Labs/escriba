import Foundation
import EscribaCore

public struct NotionPreview: Equatable, Sendable {
    public struct Property: Equatable, Sendable, Identifiable {
        public let name: String
        public let value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        public var id: String { name }
    }

    public let properties: [Property]
    public let text: String
}

public func notionPreview(_ export: NotionExport, now: Date = Date(), timeZone: TimeZone = .current) -> NotionPreview {
    let page = notionPage(
        for: sampleNote(recordedAt: now.addingTimeInterval(-2 * 3600)), as: export,
        audio: export.needsAudio ? "ejemplo" : nil, timeZone: timeZone)
    let properties = writableProperties(of: export.source).compactMap { property in
        page.properties[property.name].map { NotionPreview.Property(name: property.name, value: displayed($0)) }
    }
    return NotionPreview(properties: properties, text: page.blocks.map(displayed).joined(separator: "\n\n"))
}

private func displayed(_ value: JSONValue) -> String {
    guard case .object(let fields) = value, let (type, content) = fields.first else { return "—" }
    let text: String =
        switch (type, content) {
        case ("title", .array(let runs)), ("rich_text", .array(let runs)):
            runs.compactMap { $0["text"]?["content"]?.text }.joined()
        case ("multi_select", .array(let options)):
            options.compactMap { $0["name"]?.text }.joined(separator: ", ")
        case ("select", _):
            content["name"]?.text ?? ""
        case ("date", _):
            content["start"]?.text ?? ""
        case ("number", .number(let number)):
            number.rounded() == number ? String(Int(number)) : String(number)
        case ("url", .string(let url)):
            url
        default:
            ""
        }
    return text.isEmpty ? "—" : text
}

private func displayed(_ block: NotionBlock) -> String {
    switch block.kind {
    case .heading(let level): String(repeating: "#", count: level) + " " + block.plainText
    case .bullet: "• " + block.plainText
    case .audio: "▶︎ Audio"
    case .paragraph: block.plainText
    }
}
