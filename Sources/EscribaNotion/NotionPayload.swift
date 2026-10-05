import Foundation
import EscribaCore

public let notionTextLimit = 2000
public let notionBatchLimit = 100
public let notionTitleLimit = 80

public struct NotionRun: Equatable, Sendable {
    public let text: String
    public let bold: Bool

    public init(text: String, bold: Bool) {
        self.text = text
        self.bold = bold
    }
}

public struct NotionBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case bullet
        case audio(uploadId: String)
    }

    public let kind: Kind
    public let runs: [NotionRun]

    public init(kind: Kind = .paragraph, runs: [NotionRun]) {
        self.kind = kind
        self.runs = runs
    }

    public var plainText: String { runs.map(\.text).joined() }
}

public struct NotionPage: Equatable, Sendable {
    public let key: String
    public let properties: [String: JSONValue]
    public let blocks: [NotionBlock]

    public init(key: String, properties: [String: JSONValue], blocks: [NotionBlock]) {
        self.key = key
        self.properties = properties
        self.blocks = blocks
    }
}

public func notionBlocks(for transcript: Transcript, style: TranscriptStyle) -> [NotionBlock] {
    switch style {
    case .plain:
        return transcript.turns.flatMap { blocks(for: TranscriptTurn(speaker: nil, text: $0.text)) }
    case .speakers:
        return transcript.turns.flatMap(blocks(for:))
    case .timestamps:
        return timestamped(transcript).flatMap(blocks(for:))
    }
}

private func timestamped(_ transcript: Transcript) -> [TranscriptTurn] {
    transcript.turns.map { turn in
        guard let start = turn.start else { return turn }
        let head = turn.speaker.map { "\(bracketStamp(start)) \($0)" } ?? bracketStamp(start)
        return TranscriptTurn(speaker: head, text: turn.text, start: start)
    }
}

public func notionBatches(_ blocks: [NotionBlock]) -> [[NotionBlock]] {
    stride(from: 0, to: blocks.count, by: notionBatchLimit).map {
        Array(blocks[$0..<min($0 + notionBatchLimit, blocks.count)])
    }
}

public func paragraphBlocks(_ text: String, kind: NotionBlock.Kind = .paragraph) -> [NotionBlock] {
    let runs = textRuns(text)
    guard runs.map(\.text.count).reduce(0, +) > notionTextLimit else {
        return runs.isEmpty ? [] : [NotionBlock(kind: kind, runs: runs)]
    }
    let lead = runs.first.flatMap { $0.bold ? $0.text : nil }
    let rest = runs.dropFirst(lead == nil ? 0 : 1).map(\.text).joined()
    return blocks(for: TranscriptTurn(speaker: nil, text: rest), prefix: lead.map { NotionRun(text: $0, bold: true) })
        .map { NotionBlock(kind: kind, runs: $0.runs) }
}

func textRuns(_ text: String) -> [NotionRun] {
    let parts = text.components(separatedBy: "**")
    guard parts.count % 2 == 1 else { return text.isEmpty ? [] : [NotionRun(text: text, bold: false)] }
    return parts.enumerated()
        .filter { !$0.element.isEmpty }
        .map { NotionRun(text: $0.element, bold: $0.offset % 2 == 1) }
}

private func blocks(for turn: TranscriptTurn) -> [NotionBlock] {
    blocks(for: TranscriptTurn(speaker: nil, text: turn.text), prefix: turn.speaker.map { NotionRun(text: "\($0): ", bold: true) })
}

private func blocks(for turn: TranscriptTurn, prefix: NotionRun?) -> [NotionBlock] {
    let lines = turn.text.split(whereSeparator: \.isNewline).map(String.init)

    var blocks: [NotionBlock] = []
    for line in lines {
        let room = blocks.isEmpty ? notionTextLimit - (prefix?.text.count ?? 0) : notionTextLimit
        for piece in chunked(line, firstLimit: room, limit: notionTextLimit) {
            let body = NotionRun(text: piece, bold: false)
            let runs = blocks.isEmpty ? [prefix, body].compactMap { $0 } : [body]
            blocks.append(NotionBlock(runs: runs))
        }
    }
    return blocks
}

private func chunked(_ text: String, firstLimit: Int, limit: Int) -> [String] {
    var pending = text.split(whereSeparator: \.isWhitespace).map(String.init)
    var chunks: [String] = []

    while !pending.isEmpty {
        let room = chunks.isEmpty ? firstLimit : limit
        let head = fitting(pending, limit: room)
        guard !head.isEmpty else {
            let word = pending.removeFirst()
            chunks.append(contentsOf: split(word, every: room))
            continue
        }
        chunks.append(head.joined(separator: " "))
        pending.removeFirst(head.count)
    }
    return chunks
}

private func fitting(_ words: [String], limit: Int) -> [String] {
    var length = 0
    var taken: [String] = []

    for word in words {
        let next = taken.isEmpty ? word.count : length + 1 + word.count
        guard next <= limit else { break }
        length = next
        taken.append(word)
    }
    return taken
}

private func split(_ word: String, every limit: Int) -> [String] {
    guard limit > 0 else { return [word] }

    var pieces: [String] = []
    var rest = Substring(word)
    while !rest.isEmpty {
        pieces.append(String(rest.prefix(limit)))
        rest = rest.dropFirst(limit)
    }
    return pieces
}
