import Foundation
import EscribaCore

public let writableColumnTypes = ["title", "rich_text", "multi_select", "select", "date", "number", "url"]

public func writableProperties(of source: NotionDataSource) -> [NotionProperty] {
    let writable = source.properties.filter { writableColumnTypes.contains($0.type) }
    return writable.filter { $0.type == "title" } + writable.filter { $0.type != "title" }
}

public func columnTypeLabel(_ type: String) -> String {
    switch type {
    case "title": "título"
    case "rich_text": "texto"
    case "multi_select": "selección múltiple"
    case "select": "selección"
    case "date": "fecha"
    case "number": "número"
    case "url": "URL"
    default: type
    }
}

public func suggestedColumns(for source: NotionDataSource) -> [String: String] {
    columns(from: suggestedMapping(for: source), in: source)
}

public func refreshedColumns(_ columns: [String: String], for source: NotionDataSource) -> [String: String] {
    let names = Set(writableProperties(of: source).map(\.name))
    var refreshed = columns.filter { names.contains($0.key) }
    for (name, value) in suggestedColumns(for: source) where refreshed[name] == nil {
        refreshed[name] = value
    }
    return refreshed
}

func columns(from mapping: NotionMapping, in source: NotionDataSource) -> [String: String] {
    Dictionary(
        mapping.assigned.compactMap { field, name -> (String, String)? in
            guard let type = source.properties.first(where: { $0.name == name })?.type else { return nil }
            return (name, "{{\(legacyToken(field, type: type).marker)}}")
        },
        uniquingKeysWith: { first, _ in first })
}

private func legacyToken(_ field: NoteField, type: String) -> TemplateToken {
    switch (field, type) {
    case (.date, _): .isoDate
    case (.duration, "number"): .seconds
    case (.source, "url"): .audio
    default: token(for: field)
    }
}

func notionProperties(
    _ columns: [String: String], in source: NotionDataSource, values: NoteValues
) -> [String: JSONValue] {
    var properties: [String: JSONValue] = [:]
    for property in writableProperties(of: source) {
        guard let template = columns[property.name],
            !template.trimmingCharacters(in: .whitespaces).isEmpty,
            let value = columnValue(template, type: property.type, values: values)
        else { continue }
        properties[property.name] = value
    }
    return properties
}

private func columnValue(_ template: String, type: String, values: NoteValues) -> JSONValue? {
    let sole = soleToken(of: template)
    let text = values.inline(template).trimmingCharacters(in: .whitespacesAndNewlines)
    switch type {
    case "title":
        return .object(["title": richText(text)])
    case "rich_text":
        return .object(["rich_text": richText(text)])
    case "multi_select":
        let names: [String] =
            switch sole {
            case .tags?: values.tags
            case .speakers?: values.speakers
            default: text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        return .object(["multi_select": .array(names.filter { !$0.isEmpty }.map { .object(["name": .string($0)]) })])
    case "select":
        return .object(["select": text.isEmpty ? .null : .object(["name": .string(text)])])
    case "date":
        guard sole == .isoDate || sole == .date else { return nil }
        return .object(["date": .object(["start": .string(iso8601(values.startedAt, timeZone: values.timeZone))])])
    case "number":
        if sole == .seconds || sole == .duration {
            return .object(["number": values.duration.map { .number($0.rounded()) } ?? .null])
        }
        return .object(["number": Double(text.replacingOccurrences(of: ",", with: ".")).map(JSONValue.number) ?? .null])
    case "url":
        return .object(["url": text.isEmpty ? .null : .string(text)])
    default:
        return nil
    }
}

func richText(_ text: String) -> JSONValue {
    guard !text.isEmpty else { return .array([]) }
    return .array([
        .object(["type": .string("text"), "text": .object(["content": .string(String(text.prefix(notionTextLimit)))])]),
    ])
}

public func notionProblem(_ export: NotionExport) -> String? {
    if let problem = usabilityProblem(for: export.source) { return problem }
    guard let title = export.source.properties.first(where: { $0.type == "title" }) else { return nil }
    let template = export.columns[title.name] ?? ""
    guard template.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return "Escribe qué va en «\(title.name)», la columna del título."
}
