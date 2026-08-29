import Foundation

public struct TranscriptWord: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptSegment: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let speaker: String?
    public let text: String
    public let words: [TranscriptWord]

    public init(
        start: TimeInterval,
        end: TimeInterval,
        speaker: String? = nil,
        text: String,
        words: [TranscriptWord] = []
    ) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.words = words
    }
}

public struct Transcript: Sendable, Equatable {
    public let text: String
    public let segments: [TranscriptSegment]

    public init(text: String) {
        self.text = text
        self.segments = []
    }

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
        self.text = segments.map(\.text).joined(separator: "\n")
    }

    public var isSegmented: Bool { !segments.isEmpty }

    public var duration: TimeInterval? { segments.last?.end }

    public var speakers: [String] {
        var seen: Set<String> = []
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }
}
