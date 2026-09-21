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
        case heading
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
    public let title: String
    public let key: String
    public let startedAt: Date
    public let speakers: [String]
    public let duration: TimeInterval?
    public let source: String
    public let summary: String?
    public let tags: [String]
    public let blocks: [NotionBlock]

    init(
        title: String, key: String, startedAt: Date, speakers: [String], duration: TimeInterval?,
        source: String, summary: String? = nil, tags: [String] = [], blocks: [NotionBlock]
    ) {
        self.title = title
        self.key = key
        self.startedAt = startedAt
        self.speakers = speakers
        self.duration = duration
        self.source = source
        self.summary = summary
        self.tags = tags
        self.blocks = blocks
    }
}

public enum NotionBodyStyle: String, CaseIterable, Sendable, Codable {
    case plain
    case speakers
    case timestamps

    public var label: String {
        switch self {
        case .plain: "Solo el texto"
        case .speakers: "Un parrafo por hablante"
        case .timestamps: "Con marca de tiempo"
        }
    }
}

extension NotionPage {
    public func replacing(blocks: [NotionBlock]) -> NotionPage {
        NotionPage(
            title: title, key: key, startedAt: startedAt, speakers: speakers, duration: duration,
            source: source, summary: summary, tags: tags, blocks: blocks)
    }
}

public func notionPage(
    for recording: Recording, transcript: Transcript, digest: Digest? = nil,
    style: NotionBodyStyle = .speakers
) -> NotionPage {
    NotionPage(
        title: pageTitle(digest: digest, key: recording.key, text: transcript.text),
        key: recording.key,
        startedAt: recording.startedAt,
        speakers: transcript.speakers,
        duration: transcript.duration,
        source: recording.url.path(percentEncoded: false),
        summary: digest?.summary,
        tags: digest?.tags ?? [],
        blocks: notionBlocks(for: transcript, style: style))
}

public func notionPage(for note: Note, style: NotionBodyStyle = .speakers) -> NotionPage {
    notionPage(for: note.recording, transcript: note.transcript, digest: note.digest, style: style)
}

func pageTitle(digest: Digest?, key: String, text: String) -> String {
    guard let title = digest?.title, !title.isEmpty else { return notionTitle(key: key, text: text) }
    return title
}

public func notionBlocks(for transcript: Transcript, style: NotionBodyStyle) -> [NotionBlock] {
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
        let head = turn.speaker.map { "\(stamp(start)) \($0)" } ?? stamp(start)
        return TranscriptTurn(speaker: head, text: turn.text, start: start)
    }
}

func stamp(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let body = String(format: "%02d:%02d", (total % 3600) / 60, total % 60)
    return hours > 0 ? "[\(hours):\(body)]" : "[\(body)]"
}

public func notionBatches(_ blocks: [NotionBlock]) -> [[NotionBlock]] {
    stride(from: 0, to: blocks.count, by: notionBatchLimit).map {
        Array(blocks[$0..<min($0 + notionBatchLimit, blocks.count)])
    }
}

func notionTitle(key: String, text: String) -> String {
    let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return key }

    let head = fitting(words, limit: notionTitleLimit)
    guard head.count < words.count else { return head.joined(separator: " ") }
    return head.joined(separator: " ") + "…"
}

private func blocks(for turn: TranscriptTurn) -> [NotionBlock] {
    let prefix = turn.speaker.map { NotionRun(text: "\($0): ", bold: true) }
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
