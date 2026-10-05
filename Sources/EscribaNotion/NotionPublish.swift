import Foundation
import EscribaCore

public struct NotionExport: Equatable, Sendable, Codable {
    public var source: NotionDataSource
    public var columns: [String: String]
    public var body: String

    public static let standardBody = "{{transcripcion}}"

    public init(source: NotionDataSource, columns: [String: String], body: String = NotionExport.standardBody) {
        self.source = source
        self.columns = columns
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case source, columns, body, mapping, template
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(NotionDataSource.self, forKey: .source)
        if let columns = try container.decodeIfPresent([String: String].self, forKey: .columns) {
            self.columns = columns
        } else {
            let mapping = try container.decodeIfPresent(NotionMapping.self, forKey: .mapping) ?? NotionMapping()
            columns = EscribaNotion.columns(from: mapping, in: source)
        }
        if let body = try container.decodeIfPresent(String.self, forKey: .body) {
            self.body = body
        } else {
            body = try container.decodeIfPresent(BodyTemplate.self, forKey: .template).map(textTemplate(from:))
                ?? NotionExport.standardBody
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(columns, forKey: .columns)
        try container.encode(body, forKey: .body)
    }

    public var isUsable: Bool { notionProblem(self) == nil }

    public var needsAudio: Bool {
        templatePieces(body).contains { $0 == .token(.audio) }
    }

    public var keyColumn: String? {
        writableProperties(of: source)
            .first { $0.type == "rich_text" && columns[$0.name].flatMap(soleToken(of:)) == .key }?
            .name
    }
}

public func notionPage(
    for note: Note, as export: NotionExport, audio: String? = nil, timeZone: TimeZone = .current
) -> NotionPage {
    let values = NoteValues(note, timeZone: timeZone)
    return NotionPage(
        key: note.recording.key,
        properties: notionProperties(export.columns, in: export.source, values: values),
        blocks: notionBody(export.body, values: values, audio: audio))
}

public func publish(
    _ note: Note, as export: NotionExport,
    using client: NotionClient, known: NotionPageRef? = nil, timeZone: TimeZone = .current
) async throws(NotionError) -> NotionPageRef {
    let upload: String? = if export.needsAudio { try await client.uploadFile(note.recording.url) } else { nil }
    return try await publish(
        notionPage(for: note, as: export, audio: upload, timeZone: timeZone), as: export, using: client,
        known: known)
}

public func publish(
    _ page: NotionPage, as export: NotionExport, using client: NotionClient,
    known: NotionPageRef? = nil
) async throws(NotionError) -> NotionPageRef {
    let existing: NotionPageRef? =
        if let known { known } else {
            try await existingPage(for: page.key, export: export, client: client)
        }

    guard let existing else {
        return try await create(page, as: export, using: client)
    }

    do {
        return try await rewrite(existing, with: page, using: client)
    } catch .notFound {
        return try await create(page, as: export, using: client)
    }
}

private func create(
    _ page: NotionPage, as export: NotionExport, using client: NotionClient
) async throws(NotionError) -> NotionPageRef {
    let created = try await client.createPage(createPageBody(page, in: export.source))
    try await append(notionBatches(page.blocks).dropFirst(), to: created.id, using: client)
    return created
}

private func rewrite(
    _ existing: NotionPageRef, with page: NotionPage, using client: NotionClient
) async throws(NotionError) -> NotionPageRef {
    try await client.updatePage(existing.id, updatePageBody(page))
    for block in try await client.childBlocks(existing.id) {
        try await client.deleteBlock(block)
    }
    try await append(notionBatches(page.blocks)[...], to: existing.id, using: client)
    return existing
}

private func existingPage(
    for key: String, export: NotionExport, client: NotionClient
) async throws(NotionError) -> NotionPageRef? {
    guard let query = findByKeyBody(key, column: export.keyColumn) else { return nil }
    return try await client.findPage(export.source.id, query)
}

private func append(
    _ batches: ArraySlice<[NotionBlock]>, to pageId: String, using client: NotionClient
) async throws(NotionError) {
    for batch in batches where !batch.isEmpty {
        try await client.appendBlocks(pageId, appendChildrenBody(batch))
    }
}

public func unpublish(pageId: String, using client: NotionClient) async throws(NotionError) {
    try await client.updatePage(pageId, archivePageBody())
}
