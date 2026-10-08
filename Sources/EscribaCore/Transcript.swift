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
    public let voices: [SpeakerVoice]
    public let recognitions: [Recognition]

    public init(text: String) {
        self.text = text
        self.segments = []
        self.voices = []
        self.recognitions = []
    }

    public init(segments: [TranscriptSegment], voices: [SpeakerVoice] = [], recognitions: [Recognition] = []) {
        self.segments = segments
        self.text = segments.map(\.text).joined(separator: "\n")
        self.voices = voices
        self.recognitions = recognitions
    }

    public var isSegmented: Bool { !segments.isEmpty }

    public var duration: TimeInterval? { segments.last?.end }

    public func merging(_ speakers: Set<String>, into target: String) -> Transcript {
        guard isSegmented else { return self }

        return relabelling(speakers, as: target).withRecognitions(
            recognitions.filter { !speakers.contains($0.person) && $0.person != target })
    }

    public func recognizing(_ found: [Recognition]) -> Transcript {
        guard isSegmented else { return self }
        return found.reduce(self) { transcript, recognition in
            guard !transcript.speakers.contains(recognition.person) else { return transcript }
            return transcript.relabelling([recognition.speaker], as: recognition.person)
                .withRecognitions(transcript.recognitions + [recognition])
        }
    }

    public func recognition(of speaker: String) -> Recognition? {
        recognitions.first { $0.person == speaker }
    }

    public func forgettingRecognition(of person: String) -> Transcript {
        guard let recognition = recognition(of: person) else { return self }
        return relabelling([person], as: recognition.speaker)
            .withRecognitions(recognitions.filter { $0.person != person })
    }

    private func relabelling(_ speakers: Set<String>, as target: String) -> Transcript {
        Transcript(
            segments: segments.map { segment in
                guard let speaker = segment.speaker, speakers.contains(speaker) else { return segment }
                return TranscriptSegment(
                    start: segment.start,
                    end: segment.end,
                    speaker: target,
                    text: segment.text,
                    words: segment.words)
            },
            voices: voices.map { speakers.contains($0.speaker) ? $0.relabelled(target) : $0 },
            recognitions: recognitions)
    }

    private func withRecognitions(_ recognitions: [Recognition]) -> Transcript {
        Transcript(segments: segments, voices: voices, recognitions: recognitions)
    }

    public func renaming(_ speaker: String, to name: String) -> Transcript {
        merging([speaker], into: name)
    }

    public var rendered: String {
        turns
            .map { turn in turn.speaker.map { "\($0): \(turn.text)" } ?? turn.text }
            .joined(separator: "\n")
    }

    public var speakers: [String] {
        var seen: Set<String> = []
        return segments.compactMap(\.speaker).filter { seen.insert($0).inserted }
    }
}

public struct PlaybackPosition: Sendable, Equatable {
    public let segment: Int
    public let word: Int?

    public init(segment: Int, word: Int?) {
        self.segment = segment
        self.word = word
    }
}

extension Transcript {
    public func position(at time: TimeInterval) -> PlaybackPosition? {
        guard let segment = segments.lastIndex(where: { $0.start <= time }) else { return nil }
        return PlaybackPosition(
            segment: segment,
            word: segments[segment].words.lastIndex(where: { $0.start <= time }))
    }
}
