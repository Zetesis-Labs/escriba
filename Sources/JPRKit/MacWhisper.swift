import Foundation
import JPRCore

public enum MacWhisperBackend {
    public static let executable = "/usr/local/bin/mw"
    public static let appName = "MacWhisper"
    public static let defaultModel = "whisperkit:openai_whisper-large-v3-v20240930"

    public static func make(
        language: String = "es",
        model: String? = defaultModel,
        timeout: TimeInterval = 3600
    ) -> TranscriptionBackend {
        TranscriptionBackend(
            name: appName,
            transcribe: { source in
                try transcribe(source, language: language, model: model, timeout: timeout)
            },
            preflight: { try verifyModelAvailable(model) })
    }

    private static func transcribe(
        _ source: URL, language: String, model: String?, timeout: TimeInterval
    ) throws -> String {
        try ensureRunning()

        var arguments = [
            "transcribe", source.path(percentEncoded: false),
            "--language", language,
            "--format", "txt",
        ]
        if let model { arguments += ["--model", model] }

        let result = try Shell.run(executable, arguments: arguments, timeout: timeout)

        guard result.status == 0 else {
            let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
            if detail.contains("refused") || detail.lowercased().contains("sandbox") {
                throw TranscriptionError.backendUnavailable("\(appName): \(detail)")
            }
            throw TranscriptionError.failed("mw codigo \(result.status): \(detail)")
        }

        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
