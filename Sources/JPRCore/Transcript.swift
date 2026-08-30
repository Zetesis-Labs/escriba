import Foundation

public struct TranscriptWord: Sendable, Equatable, Codable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptSegment: Sendable, Equatable, Codable {
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

    public func merging(_ speakers: Set<String>, into target: String) -> Transcript {
        guard isSegmented else { return self }

        return Transcript(segments: segments.map { segment in
            guard let speaker = segment.speaker, speakers.contains(speaker) else { return segment }
            return TranscriptSegment(
                start: segment.start,
                end: segment.end,
                speaker: target,
                text: segment.text,
                words: segment.words)
        })
    }

    public func renaming(_ speaker: String, to name: String) -> Transcript {
        merging([speaker], into: name)
    }

    public var rendered: String {
        guard !speakers.isEmpty else { return text }

        var turns: [String] = []
        var speaker: String??
        var buffer: [String] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            let body = buffer.joined(separator: " ")
            turns.append((speaker ?? nil).map { "\($0): \(body)" } ?? body)
            buffer = []
        }

        for segment in segments {
            if speaker == nil || speaker! != segment.speaker {
                flush()
                speaker = segment.speaker
            }
            buffer.append(segment.text)
        }
        flush()

        return turns.joined(separator: "\n")
    }

    public var speakers: [String] {
        var seen: Set<String> = []
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }
}
