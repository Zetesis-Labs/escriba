import Foundation
import EscribaCore

private enum BodyLine {
    case heading(Int, String)
    case text(String)
    case bullet(String)
    case blocks([NotionBlock])
    case blank

    var level: Int? {
        if case .heading(let level, _) = self { return level }
        return nil
    }

    var isBlank: Bool {
        switch self {
        case .blank: true
        case .blocks(let blocks): blocks.isEmpty
        default: false
        }
    }
}

public func notionBody(_ template: String, values: NoteValues, audio: String?) -> [NotionBlock] {
    let lines = template.components(separatedBy: "\n").flatMap { bodyLines($0, values: values, audio: audio) }
    return withoutEmptySections(lines, level: \.level, isBlank: \.isBlank).flatMap { line -> [NotionBlock] in
        switch line {
        case .heading(let level, let text): paragraphBlocks(text, kind: .heading(min(level, 3)))
        case .text(let text): paragraphBlocks(text)
        case .bullet(let text): paragraphBlocks(text, kind: .bullet)
        case .blocks(let blocks): blocks
        case .blank: []
        }
    }
}

private func bodyLines(_ line: String, values: NoteValues, audio: String?) -> [BodyLine] {
    switch soleToken(of: line) {
    case .transcript(let style)?:
        return [.blocks(notionBlocks(for: values.transcript, style: style))]
    case .audio?:
        return audio.map { [.blocks([NotionBlock(kind: .audio(uploadId: $0), runs: [])])] } ?? []
    case .link?:
        return []
    default:
        break
    }
    let pieces = templatePieces(line)
    let hasToken = pieces.contains { if case .token = $0 { true } else { false } }
    let hasText = pieces.contains { piece in
        if case .text(let text) = piece { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }
    let rendered = values.inline(line)
    if hasToken, !hasText, rendered.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
    return rendered.split(separator: "\n", omittingEmptySubsequences: false).map { physical in
        let text = String(physical)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .blank }
        if let level = markdownHeadingLevel(text) {
            let title = text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? .blank : .heading(level, title)
        }
        if text.hasPrefix("- ") || text.hasPrefix("* ") { return .bullet(String(text.dropFirst(2))) }
        return .text(text)
    }
}
