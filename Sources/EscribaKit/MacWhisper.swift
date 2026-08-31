import Foundation
import EscribaCore

public enum MacWhisperBackend {
    public static let executable = "/usr/local/bin/mw"
    public static let appName = "MacWhisper"
    public static let defaultModel = "whisperkit:openai_whisper-large-v3-v20240930"

    public static func make(
        language: String = "es",
        model: String? = defaultModel,
        diarize: Bool = false,
        timeout: TimeInterval = 3600
    ) -> TranscriptionBackend {
        TranscriptionBackend(
            name: appName,
            transcribe: { source throws(TranscriptionError) in
                try TranscriptionError.catching {
                    try transcribe(
                        source, language: language, model: model, diarize: diarize,
                        timeout: timeout)
                }
            },
            preflight: { () throws(TranscriptionError) in
                try TranscriptionError.catching { try verifyModelAvailable(model) }
            })
    }

    private static func transcribe(
        _ source: URL, language: String, model: String?, diarize: Bool, timeout: TimeInterval
    ) throws -> Transcript {
        try ensureRunning()

        var arguments = [
            "transcribe", source.path(percentEncoded: false),
            "--language", language,
            "--format", "json",
        ]
        if let model { arguments += ["--model", model] }
        if diarize { arguments.append("--speakers") }

        let result = try Shell.run(executable, arguments: arguments, timeout: timeout)

        guard result.status == 0 else {
            let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
            if detail.contains("refused") || detail.lowercased().contains("sandbox") {
                throw TranscriptionError.backendUnavailable("\(appName): \(detail)")
            }
            throw TranscriptionError.failed("mw codigo \(result.status): \(detail)")
        }

        return try decode(Data(result.output.utf8))
    }

    public static func decode(_ data: Data) throws -> Transcript {
        let raw = String(decoding: data, as: UTF8.self)
        guard let opening = raw.firstIndex(of: "{") else {
            throw TranscriptionError.failed("mw no devolvio JSON: \(raw.prefix(200))")
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(raw[opening...].utf8))
        } catch {
            throw TranscriptionError.failed("no entiendo la salida de mw: \(error)")
        }

        guard !payload.segments.isEmpty else { return Transcript(text: payload.text) }

        return Transcript(segments: payload.segments.map { segment in
            TranscriptSegment(
                start: seconds(segment.start),
                end: seconds(segment.end),
                speaker: segment.speaker,
                text: segment.text,
                words: (segment.words ?? []).map {
                    TranscriptWord(start: seconds($0.start), end: seconds($0.end), text: $0.text)
                })
        })
    }

    private static func seconds(_ milliseconds: Double) -> TimeInterval { milliseconds / 1000 }

    private struct Payload: Decodable {
        struct Segment: Decodable {
            struct Word: Decodable {
                let start: Double
                let end: Double
                let text: String
            }

            let start: Double
            let end: Double
            let text: String
            let speaker: String?
            let words: [Word]?
        }

        let text: String
        let segments: [Segment]
    }

    public static func installedModels() -> ModelListing {
        guard let result = try? Shell.run(executable, arguments: ["models"], timeout: 30),
              result.status == 0
        else { return ModelListing(identifiers: [], selected: nil) }

        return parseModelListing(result.output)
    }

    public static func verifyModelAvailable(_ model: String?) throws {
        guard let model else { return }

        let installed = installedModels()
        guard installed.isEmpty || installed.identifiers.contains(model) else {
            throw TranscriptionError.modelMissing(model: model, installed: installed.identifiers)
        }
    }

    public static func isRunning() -> Bool {
        (try? Shell.run("/usr/bin/pgrep", arguments: ["-x", appName], timeout: 10).status) == 0
    }

    public static func ensureRunning(timeout: TimeInterval = 60) throws {
        if isRunning() { return }

        _ = try? Shell.run("/usr/bin/open", arguments: ["-gj", "-a", appName], timeout: 30)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() {
                Thread.sleep(forTimeInterval: 3)
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }

        throw TranscriptionError.backendUnavailable("\(appName) no arranco en \(Int(timeout))s")
    }
}
