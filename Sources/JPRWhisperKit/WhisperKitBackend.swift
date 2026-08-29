import Foundation
import JPRCore
import JPRKit
import WhisperKit

public enum WhisperKitBackend {
    public static let defaultVariant = "openai_whisper-large-v3-v20240930"
    public static let name = "WhisperKit"

    public static var defaultModelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/jpr-transcribe/models")
    }

    public static func make(
        language: String = "es",
        variant: String = defaultVariant,
        modelsRoot: URL = defaultModelsRoot
    ) -> TranscriptionBackend {
        let engine = Engine(language: language, variant: variant, modelsRoot: modelsRoot)
        return TranscriptionBackend(
            name: name,
            transcribe: { source in
                try engine.preflight()
                let path = source.path(percentEncoded: false)
                let results = try runBlocking { try await engine.results(for: path) }
                return transcript(from: results)
            },
            preflight: { try engine.preflight() })
    }

    static let modelComponents = [
        "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
    ]

    public static func installedModelFolder(
        variant: String = defaultVariant, modelsRoot: URL = defaultModelsRoot
    ) -> URL? {
        guard let walker = FileManager.default.enumerator(
            at: modelsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        for case let url as URL in walker
        where url.lastPathComponent == variant && isModelComplete(url) {
            return url
        }
        return nil
    }

    static func isModelComplete(_ folder: URL) -> Bool {
        modelComponents.allSatisfy { component in
            FileManager.default.fileExists(
                atPath: folder.appending(path: component)
                    .appending(path: "coremldata.bin").path(percentEncoded: false))
        }
    }

    @discardableResult
    public static func downloadModel(
        variant: String = defaultVariant,
        modelsRoot: URL = defaultModelsRoot,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        return try runBlocking {
            try await WhisperKit.download(
                variant: variant,
                downloadBase: modelsRoot,
                progressCallback: { progress in onProgress?(progress.fractionCompleted) })
        }
    }

    static func transcript(from results: [TranscriptionResult]) -> Transcript {
        transcript(
            segments: results.flatMap(\.segments),
            fallbackText: results.map(\.text).joined())
    }

    static func transcript(
        segments rawSegments: [TranscriptionSegment], fallbackText: String
    ) -> Transcript {
        let segments = rawSegments.map { segment in
            TranscriptSegment(
                start: TimeInterval(segment.start),
                end: TimeInterval(segment.end),
                text: clean(segment.text),
                words: (segment.words ?? []).map {
                    TranscriptWord(
                        start: TimeInterval($0.start), end: TimeInterval($0.end), text: $0.word)
                })
        }

        let meaningful = segments.filter { !$0.text.isEmpty }
        guard meaningful.isEmpty else { return Transcript(segments: meaningful) }
        return Transcript(text: clean(fallbackText))
    }

    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor Engine {
    private let language: String
    private let variant: String
    private let modelsRoot: URL
    private var loaded: WhisperKit?

    init(language: String, variant: String, modelsRoot: URL) {
        self.language = language
        self.variant = variant
        self.modelsRoot = modelsRoot
    }

    nonisolated func preflight() throws {
        guard WhisperKitBackend.installedModelFolder(variant: variant, modelsRoot: modelsRoot) != nil
        else { throw TranscriptionError.modelMissing(model: variant, installed: []) }
    }

    func results(for path: String) async throws -> [TranscriptionResult] {
        let kit = try await loadedKit()
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            wordTimestamps: true)

        let batches = await kit.transcribe(audioPaths: [path], decodeOptions: options)

        guard let first = batches.first, let transcriptions = first else {
            throw TranscriptionError.failed("WhisperKit no devolvio resultado para \(path)")
        }
        return transcriptions
    }

    private func loadedKit() async throws -> WhisperKit {
        if let loaded { return loaded }

        guard let folder = WhisperKitBackend.installedModelFolder(
            variant: variant, modelsRoot: modelsRoot)
        else { throw TranscriptionError.modelMissing(model: variant, installed: []) }

        let config = WhisperKitConfig(
            model: variant,
            downloadBase: modelsRoot,
            modelFolder: folder.path(percentEncoded: false),
            download: false)

        let kit = try await WhisperKit(config)
        loaded = kit
        return kit
    }
}

func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = OutcomeBox<T>()

    Task {
        do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
        semaphore.signal()
    }

    semaphore.wait()
    return try box.take()
}

private final class OutcomeBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<T, Error>?

    func set(_ value: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        outcome = value
    }

    func take() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let outcome else {
            throw TranscriptionError.failed("la tarea asincrona no devolvio resultado")
        }
        return try outcome.get()
    }
}
