import Foundation

public struct SpeakerVoice: Sendable, Equatable, Codable {
    public let speaker: String
    public let embedding: [Float]
    public let model: String

    public init(speaker: String, embedding: [Float], model: String) {
        self.speaker = speaker
        self.embedding = embedding
        self.model = model
    }

    func relabelled(_ speaker: String) -> SpeakerVoice {
        SpeakerVoice(speaker: speaker, embedding: embedding, model: model)
    }
}

public struct KnownVoice: Sendable, Equatable {
    public let person: String
    public let embedding: [Float]
    public let model: String

    public init(person: String, embedding: [Float], model: String) {
        self.person = person
        self.embedding = embedding
        self.model = model
    }
}

public struct Recognition: Sendable, Equatable, Codable {
    public let speaker: String
    public let person: String
    public let distance: Float

    public init(speaker: String, person: String, distance: Float) {
        self.speaker = speaker
        self.person = person
        self.distance = distance
    }
}

public struct SpeakerSpan: Sendable, Equatable {
    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public struct VoiceDiarization: Sendable, Equatable {
    public let voices: [SpeakerVoice]
    public let spans: [SpeakerSpan]

    public init(voices: [SpeakerVoice], spans: [SpeakerSpan]) {
        self.voices = voices
        self.spans = spans
    }
}

public let voiceMatchThreshold: Float = 0.3

public func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
    guard a.count == b.count, !a.isEmpty else { return nil }
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    for index in a.indices {
        dot += a[index] * b[index]
        normA += a[index] * a[index]
        normB += b[index] * b[index]
    }
    guard normA > 0, normB > 0 else { return nil }
    return min(max(1 - dot / (normA.squareRoot() * normB.squareRoot()), 0), 2)
}

public func recognize(_ voices: [SpeakerVoice], known: [KnownVoice], threshold: Float) -> [Recognition] {
    var candidates: [Recognition] = []
    for speaker in orderedUnique(voices.map(\.speaker)) {
        let own = voices.filter { $0.speaker == speaker }
        for person in orderedUnique(known.map(\.person)) {
            let distances = own.flatMap { voice in
                known.filter { $0.person == person && $0.model == voice.model }
                    .compactMap { cosineDistance(voice.embedding, $0.embedding) }
            }
            guard let nearest = distances.min(), nearest <= threshold else { continue }
            candidates.append(Recognition(speaker: speaker, person: person, distance: nearest))
        }
    }
    var speakers: Set<String> = []
    var people: Set<String> = []
    return candidates.sorted { $0.distance < $1.distance }.filter { candidate in
        guard !speakers.contains(candidate.speaker), !people.contains(candidate.person) else { return false }
        speakers.insert(candidate.speaker)
        people.insert(candidate.person)
        return true
    }
}

public func speechBySpeaker(_ spans: [SpeakerSpan]) -> [String: TimeInterval] {
    Dictionary(spans.map { ($0.speaker, $0.end - $0.start) }, uniquingKeysWith: +)
}

public func dominantVoice(
    _ voices: [SpeakerVoice], spans: [SpeakerSpan], minimumSpeech: TimeInterval
) -> SpeakerVoice? {
    let speech = speechBySpeaker(spans)
    guard let (speaker, seconds) = speech.max(by: { $0.value < $1.value }), seconds >= minimumSpeech else {
        return nil
    }
    return voices.first { $0.speaker == speaker }
}

public func storedSpeakers(of spans: [SpeakerSpan], in transcript: Transcript) -> [String: String] {
    var overlap: [String: [String: TimeInterval]] = [:]
    for span in spans {
        for segment in transcript.segments {
            guard let stored = segment.speaker else { continue }
            let shared = min(span.end, segment.end) - max(span.start, segment.start)
            if shared > 0 { overlap[span.speaker, default: [:]][stored, default: 0] += shared }
        }
    }
    return overlap.compactMapValues { $0.max { $0.value < $1.value }?.key }
}

private func orderedUnique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}
