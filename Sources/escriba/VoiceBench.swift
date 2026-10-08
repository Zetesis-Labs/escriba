import Foundation
import EscribaCore
import EscribaStore
import EscribaWhisper

struct BenchVoice: Codable {
    let recording: String
    let cluster: String
    let stored: String?
    let seconds: Double
    let embedding: [Float]
}

func runVoiceBench(library: URL, output: URL) async throws {
    let copy = try libraryCopy(of: library)
    defer { try? FileManager.default.removeItem(at: copy) }
    let store = try Store(root: copy)
    let engine = WhisperKitEngine(language: nil)
    var voices: [BenchVoice] = []

    for recording in try store.recordings() where recording.audio == .libraryCopy {
        let versions = try await store.versions(for: recording.key)
        guard let diarized = versions.filter({ $0.options?.diarize == true }).max(by: { $0.number < $1.number }),
            let current = try await store.transcript(for: recording.key), !current.speakers.isEmpty
        else { continue }
        let started = Date()
        let result = try await engine.diarizedVoices(
            of: recording.audioURL, speakerCount: diarized.options?.speakerCount)
        let stored = storedSpeakers(of: result.spans, in: current)
        let seconds = Dictionary(result.spans.map { ($0.speaker, $0.end - $0.start) }, uniquingKeysWith: +)
        let found = result.voices.map {
            BenchVoice(
                recording: recording.key, cluster: $0.speaker, stored: stored[$0.speaker],
                seconds: seconds[$0.speaker] ?? 0, embedding: $0.embedding)
        }
        voices += found
        print(
            "\(recording.key) (\(Int(Date().timeIntervalSince(started))) s): "
                + found.map { "\($0.cluster)→\($0.stored ?? "-") \(Int($0.seconds)) s" }.joined(separator: ", "))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(voices).write(to: output)
    print("\n\(voices.count) huellas en \(output.path(percentEncoded: false))")
    printDistances(voices)
}

private func libraryCopy(of library: URL) throws -> URL {
    let copy = FileManager.default.temporaryDirectory.appending(path: "escriba-banco-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    for name in ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"] {
        let file = library.appending(path: name)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
        try FileManager.default.copyItem(at: file, to: copy.appending(path: name))
    }
    try FileManager.default.createSymbolicLink(at: copy.appending(path: "audio"), withDestinationURL: library.appending(path: "audio"))
    return copy
}

private func printDistances(_ voices: [BenchVoice]) {
    let named = voices.filter { voice in voice.stored.map { !$0.hasPrefix("Speaker ") } ?? false }
    print("\nentre hablantes de la misma grabación (personas distintas):")
    for (key, group) in Dictionary(grouping: voices, by: \.recording).sorted(by: { $0.key < $1.key }) {
        var pairs: [String] = []
        for (index, a) in group.enumerated() {
            for b in group.dropFirst(index + 1) {
                guard let distance = cosineDistance(a.embedding, b.embedding) else { continue }
                pairs.append("\(a.cluster)-\(b.cluster) \(String(format: "%.3f", distance))")
            }
        }
        print("  \(key): \(pairs.joined(separator: ", "))")
    }
    for reference in named {
        print("\na «\(reference.stored ?? "")» de \(reference.recording):")
        let rows = voices.filter { $0.recording != reference.recording }.compactMap { voice -> (BenchVoice, Float)? in
            cosineDistance(voice.embedding, reference.embedding).map { (voice, $0) }
        }
        for (voice, distance) in rows.sorted(by: { $0.1 < $1.1 }) {
            print("  \(String(format: "%.3f", distance))  \(voice.recording) \(voice.cluster) (\(Int(voice.seconds)) s)")
        }
    }
}

func printVoiceSample(_ audio: URL) async throws {
    let result = try await WhisperKitEngine(language: nil).diarizedVoices(of: audio)
    guard let voice = dominantVoice(result.voices, spans: result.spans, minimumSpeech: 0) else {
        fail("no se oye a nadie en \(audio.lastPathComponent)")
    }
    let speech = result.spans.filter { $0.speaker == voice.speaker }.map { $0.end - $0.start }.reduce(0, +)
    let encoded = try JSONEncoder().encode(BenchVoice(
        recording: audio.lastPathComponent, cluster: voice.speaker, stored: nil, seconds: speech, embedding: voice.embedding))
    print(String(decoding: encoded, as: UTF8.self))
}
