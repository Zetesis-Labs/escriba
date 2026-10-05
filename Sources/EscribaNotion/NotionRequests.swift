import Foundation
import EscribaCore

public func createPageBody(_ page: NotionPage, in source: NotionDataSource) -> JSONValue {
    let first = notionBatches(page.blocks).first ?? []

    return .object([
        "parent": .object([
            "type": .string("data_source_id"), "data_source_id": .string(source.id),
        ]),
        "properties": .object(page.properties),
        "children": .array(first.map(block(_:))),
    ])
}

public func updatePageBody(_ page: NotionPage) -> JSONValue {
    .object(["properties": .object(page.properties)])
}

public func appendChildrenBody(_ blocks: [NotionBlock]) -> JSONValue {
    .object(["children": .array(blocks.map(block(_:)))])
}

public func findByKeyBody(_ key: String, column: String?) -> JSONValue? {
    guard let column else { return nil }

    return .object([
        "filter": .object([
            "property": .string(column),
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

private func block(_ block: NotionBlock) -> JSONValue {
    switch block.kind {
    case .paragraph:
        .object([
            "object": .string("block"),
            "type": .string("paragraph"),
            "paragraph": .object(["rich_text": .array(block.runs.map(run(_:)))]),
        ])
    case .heading(let level):
        .object([
            "object": .string("block"),
            "type": .string("heading_\(min(max(level, 1), 3))"),
            "heading_\(min(max(level, 1), 3))": .object(["rich_text": .array(block.runs.map(run(_:)))]),
        ])
    case .bullet:
        .object([
            "object": .string("block"),
            "type": .string("bulleted_list_item"),
            "bulleted_list_item": .object(["rich_text": .array(block.runs.map(run(_:)))]),
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
