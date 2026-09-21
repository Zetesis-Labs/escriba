import Foundation

public func createPageBody(
    _ page: NotionPage, in source: NotionDataSource, mapping: NotionMapping, timeZone: TimeZone
) -> JSONValue {
    let first = notionBatches(page.blocks).first ?? []

    return .object([
        "parent": .object([
            "type": .string("data_source_id"), "data_source_id": .string(source.id),
        ]),
        "properties": .object(properties(page, in: source, mapping: mapping, timeZone: timeZone)),
        "children": .array(first.map(block(_:))),
    ])
}

public func updatePageBody(
    _ page: NotionPage, in source: NotionDataSource, mapping: NotionMapping, timeZone: TimeZone
) -> JSONValue {
    .object([
        "properties": .object(properties(page, in: source, mapping: mapping, timeZone: timeZone))
    ])
}

public func appendChildrenBody(_ blocks: [NotionBlock]) -> JSONValue {
    .object(["children": .array(blocks.map(block(_:)))])
}

public func findByKeyBody(_ key: String, mapping: NotionMapping) -> JSONValue? {
    guard let property = mapping[.key] else { return nil }

    return .object([
        "filter": .object([
            "property": .string(property),
            "rich_text": .object(["equals": .string(key)]),
        ]),
        "page_size": .number(1),
    ])
}

public func notionDateString(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    return formatter.string(from: date)
}

func clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.down))
    let body = String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
    return total >= 3600 ? "\(total / 3600):\(body)" : body
}

private func properties(
    _ page: NotionPage, in source: NotionDataSource, mapping: NotionMapping, timeZone: TimeZone
) -> [String: JSONValue] {
    var properties: [String: JSONValue] = [:]

    for (field, name) in mapping.assigned {
        guard let type = source.properties.first(where: { $0.name == name })?.type,
            let value = value(of: field, in: page, as: type, timeZone: timeZone)
        else { continue }
        properties[name] = value
    }
    return properties
}

private func value(
    of field: NotionField, in page: NotionPage, as type: String, timeZone: TimeZone
) -> JSONValue? {
    switch (field, type) {
    case (.title, _):
        return .object(["title": richText(page.title)])
    case (.date, _):
        return .object(["date": .object(["start": .string(notionDateString(page.startedAt, timeZone: timeZone))])])
    case (.speakers, "multi_select"):
        guard !page.speakers.isEmpty else { return nil }
        return .object(["multi_select": .array(page.speakers.map { .object(["name": .string($0)]) })])
    case (.speakers, _):
        guard !page.speakers.isEmpty else { return nil }
        return .object(["rich_text": richText(page.speakers.joined(separator: ", "))])
    case (.duration, "number"):
        guard let duration = page.duration else { return nil }
        return .object(["number": .number(duration.rounded())])
    case (.duration, _):
        guard let duration = page.duration else { return nil }
        return .object(["rich_text": richText(clock(duration))])
    case (.key, _):
        return .object(["rich_text": richText(page.key)])
    case (.source, "url"):
        return .object(["url": .string(URL(fileURLWithPath: page.source).absoluteString)])
    case (.source, _):
        return .object(["rich_text": richText(page.source)])
    case (.summary, _):
        guard let summary = page.summary, !summary.isEmpty else { return .object(["rich_text": .array([])]) }
        return .object(["rich_text": richText(String(summary.prefix(notionTextLimit)))])
    case (.tags, "multi_select"):
        return .object(["multi_select": .array(page.tags.map { .object(["name": .string($0)]) })])
    case (.tags, _):
        guard !page.tags.isEmpty else { return .object(["rich_text": .array([])]) }
        return .object(["rich_text": richText(page.tags.joined(separator: ", "))])
    }
}

private func richText(_ text: String) -> JSONValue {
    .array([.object(["type": .string("text"), "text": .object(["content": .string(text)])])])
}

private func block(_ block: NotionBlock) -> JSONValue {
    switch block.kind {
    case .paragraph:
        .object([
            "object": .string("block"),
            "type": .string("paragraph"),
            "paragraph": .object(["rich_text": .array(block.runs.map(run(_:)))]),
        ])
    case .heading:
        .object([
            "object": .string("block"),
            "type": .string("heading_2"),
            "heading_2": .object(["rich_text": .array(block.runs.map(run(_:)))]),
        ])
    case .audio(let uploadId):
        .object([
            "object": .string("block"),
            "type": .string("audio"),
            "audio": .object([
                "type": .string("file_upload"),
                "file_upload": .object(["id": .string(uploadId)]),
            ]),
        ])
    }
}

private func run(_ run: NotionRun) -> JSONValue {
    .object([
        "type": .string("text"),
        "text": .object(["content": .string(run.text)]),
        "annotations": .object(["bold": .bool(run.bold)]),
    ])
}

public func archivePageBody() -> JSONValue {
    .object(["archived": .bool(true)])
}
