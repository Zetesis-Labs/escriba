import Foundation
import EscribaCore

extension NoteField {
    public var accepts: [String] {
        switch self {
        case .title: ["title"]
        case .date: ["date"]
        case .speakers: ["multi_select", "rich_text"]
        case .duration: ["number", "rich_text"]
        case .key: ["rich_text"]
        case .source: ["url", "rich_text"]
        case .summary: ["rich_text"]
        case .tags: ["multi_select", "rich_text"]
        }
    }

    var hints: [String] {
        switch self {
        case .title: ["titulo", "nombre", "asunto"]
        case .date: ["fecha", "grabacion", "date", "dia", "momento"]
        case .speakers: ["hablante", "speaker", "participante", "persona", "quien"]
        case .duration: ["duracion", "duration", "segundo", "length", "largo"]
        case .key: ["clave", "key", "id", "identificador"]
        case .source: ["origen", "source", "fichero", "archivo", "ruta", "audio"]
        case .summary: ["resumen", "summary", "sintesis", "abstract"]
        case .tags: ["etiqueta", "tag", "tema", "categoria", "topic"]
        }
    }
}

public struct NotionProperty: Equatable, Hashable, Sendable, Codable {
    public let name: String
    public let type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

public struct NotionDataSource: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    public let databaseTitle: String
    public let title: String
    public let properties: [NotionProperty]

    public init(id: String, databaseTitle: String, title: String, properties: [NotionProperty]) {
        self.id = id
        self.databaseTitle = databaseTitle
        self.title = title
        self.properties = properties
    }

    public var label: String {
        databaseTitle == title || title.isEmpty ? databaseTitle : "\(databaseTitle) › \(title)"
    }
}

public struct NotionMapping: Equatable, Sendable, Codable {
    private var byField: [String: String]

    public init(_ byField: [NoteField: String] = [:]) {
        self.byField = Dictionary(
            uniqueKeysWithValues: byField.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(field: NoteField) -> String? {
        get { byField[field.rawValue] }
        set {
            if let newValue {
                for (raw, name) in byField where name == newValue { byField[raw] = nil }
            }
            byField[field.rawValue] = newValue
        }
    }

    public var assigned: [NoteField: String] {
        Dictionary(uniqueKeysWithValues: byField.compactMap { raw, name in
            NoteField(rawValue: raw).map { ($0, name) }
        })
    }

    public func fillingGaps(from source: NotionDataSource) -> NotionMapping {
        var filled = self
        let suggested = suggestedMapping(for: source)
        let taken = Set(assigned.values)
        for field in NoteField.allCases where filled[field] == nil {
            guard let name = suggested[field], !taken.contains(name) else { continue }
            filled[field] = name
        }
        return filled
    }

    public func pruned(to source: NotionDataSource) -> NotionMapping {
        var pruned = self
        for (field, name) in assigned where !compatible(field, in: source).contains(where: { $0.name == name }) {
            pruned[field] = nil
        }
        return pruned
    }
}

public func compatible(_ field: NoteField, in source: NotionDataSource) -> [NotionProperty] {
    field.accepts.flatMap { type in source.properties.filter { $0.type == type } }
}

public func suggestedMapping(for source: NotionDataSource) -> NotionMapping {
    var mapping = NotionMapping()
    var taken: Set<String> = []

    for field in NoteField.allCases {
        guard let chosen = compatible(field, in: source)
            .first(where: { !taken.contains($0.name) && named($0, like: field) })
        else { continue }
        mapping[field] = chosen.name
        taken.insert(chosen.name)
    }

    for field in NoteField.allCases where mapping[field] == nil {
        guard let chosen = compatible(field, in: source)
            .first(where: { !taken.contains($0.name) && !claimed($0, by: field) })
        else { continue }
        mapping[field] = chosen.name
        taken.insert(chosen.name)
    }
    return mapping
}

public func isUsable(_ mapping: NotionMapping, for source: NotionDataSource) -> Bool {
    usabilityProblem(for: source) == nil && mapping[.title] != nil
}

public func usabilityProblem(for source: NotionDataSource) -> String? {
    guard compatible(.title, in: source).isEmpty else { return nil }
    return "La base «\(source.title)» no tiene propiedad de título."
}

private func claimed(_ property: NotionProperty, by field: NoteField) -> Bool {
    NoteField.allCases.contains { $0 != field && named(property, like: $0) }
}

private func named(_ property: NotionProperty, like field: NoteField) -> Bool {
    let name = folded(property.name)
    return field.hints.contains { name.contains($0) }
}

private func folded(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
}
