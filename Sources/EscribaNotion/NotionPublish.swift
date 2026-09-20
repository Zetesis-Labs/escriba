import Foundation
import EscribaCore

public struct NotionExport: Equatable, Sendable, Codable {
    public var source: NotionDataSource
    public var mapping: NotionMapping
    public var template: BodyTemplate

    public init(
        source: NotionDataSource, mapping: NotionMapping, template: BodyTemplate = .standard
    ) {
        self.source = source
        self.mapping = mapping
        self.template = template
    }

    public init(source: NotionDataSource, mapping: NotionMapping, style: NotionBodyStyle) {
        self.init(source: source, mapping: mapping, template: BodyTemplate([.transcript(style)]))
    }

    public var isUsable: Bool { EscribaNotion.isUsable(mapping, for: source) }
}

public func publish(
    _ recording: Recording, _ transcript: Transcript, as export: NotionExport,
    using client: NotionClient, known: NotionPageRef? = nil, timeZone: TimeZone = .current
) async throws(NotionError) -> NotionPageRef {
    let upload: String? =
        if export.template.needsAudio { try await client.uploadFile(recording.url) } else { nil }
    let page = notionPage(for: recording, transcript: transcript)
    let blocks = render(export.template, for: page, transcript: transcript, audio: upload, timeZone: timeZone)
    return try await publish(
        page.replacing(blocks: blocks), as: export, using: client, known: known, timeZone: timeZone)
}

public func publish(
    _ page: NotionPage, as export: NotionExport, using client: NotionClient,
    known: NotionPageRef? = nil, timeZone: TimeZone = .current
) async throws(NotionError) -> NotionPageRef {
    let existing: NotionPageRef? =
        if let known { known } else {
            try await existingPage(for: page.key, export: export, client: client)
        }

    guard let existing else {
        return try await create(page, as: export, using: client, timeZone: timeZone)
    }

    do {
        return try await rewrite(existing, with: page, as: export, using: client, timeZone: timeZone)
    } catch .notFound {
        return try await create(page, as: export, using: client, timeZone: timeZone)
    }
}

private func create(
    _ page: NotionPage, as export: NotionExport, using client: NotionClient, timeZone: TimeZone
) async throws(NotionError) -> NotionPageRef {
    let created = try await client.createPage(
        createPageBody(page, in: export.source, mapping: export.mapping, timeZone: timeZone))
    try await append(notionBatches(page.blocks).dropFirst(), to: created.id, using: client)
    return created
}

private func rewrite(
    _ existing: NotionPageRef, with page: NotionPage, as export: NotionExport,
    using client: NotionClient, timeZone: TimeZone
) async throws(NotionError) -> NotionPageRef {
    try await client.updatePage(
        existing.id,
        updatePageBody(page, in: export.source, mapping: export.mapping, timeZone: timeZone))
    for block in try await client.childBlocks(existing.id) {
        try await client.deleteBlock(block)
    }
    try await append(notionBatches(page.blocks)[...], to: existing.id, using: client)
    return existing
}

private func existingPage(
    for key: String, export: NotionExport, client: NotionClient
) async throws(NotionError) -> NotionPageRef? {
    guard let query = findByKeyBody(key, mapping: export.mapping) else { return nil }
    return try await client.findPage(export.source.id, query)
}

private func append(
    _ batches: ArraySlice<[NotionBlock]>, to pageId: String, using client: NotionClient
) async throws(NotionError) {
    for batch in batches where !batch.isEmpty {
        try await client.appendBlocks(pageId, appendChildrenBody(batch))
    }
}
