import Foundation
import EscribaCore

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
        case .summary:
            guard let summary = page.summary, !summary.isEmpty else { return [] }
            return notionBlocks(for: Transcript(text: summary), style: .plain)
        case .audio:
            return audio.map { [NotionBlock(kind: .audio(uploadId: $0), runs: [])] } ?? []
        case .field(let field):
            return fieldValue(field, of: page, timeZone: timeZone).map {
                [NotionBlock(runs: [NotionRun(text: "\(field.label): ", bold: true), NotionRun(text: $0, bold: false)])]
            } ?? []
        }
    }
}

func fieldValue(_ field: NoteField, of page: NotionPage, timeZone: TimeZone) -> String? {
    switch field {
    case .title: page.title
    case .date: page.startedAt.formatted(.dateTime.day().month(.wide).year().hour().minute())
    case .speakers: page.speakers.isEmpty ? nil : page.speakers.joined(separator: ", ")
    case .duration: page.duration.map(durationClock)
    case .key: page.key
    case .source: page.source
    case .summary: page.summary.flatMap { $0.isEmpty ? nil : $0 }
    case .tags: page.tags.isEmpty ? nil : page.tags.joined(separator: ", ")
    }
}
