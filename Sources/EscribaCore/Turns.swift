import Foundation

public struct TranscriptTurn: Sendable, Equatable {
    public let speaker: String?
    public let text: String
    public let start: TimeInterval?

    public init(speaker: String?, text: String, start: TimeInterval? = nil) {
        self.speaker = speaker
        self.text = text
        self.start = start
    }
}

extension Transcript {
    public var turns: [TranscriptTurn] {
        guard !speakers.isEmpty else {
            return text.isEmpty ? [] : [TranscriptTurn(speaker: nil, text: text)]
        }

        var result: [TranscriptTurn] = []
        var current: String??
        var start: TimeInterval = 0
        var buffer: [String] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(
                TranscriptTurn(
                    speaker: current ?? nil, text: buffer.joined(separator: " "), start: start))
            buffer = []
        }

        for segment in segments {
            if current == nil || current! != segment.speaker {
                flush()
                current = segment.speaker
                start = segment.start
            }
            buffer.append(segment.text)
        }
        flush()

        return result
    }
}
