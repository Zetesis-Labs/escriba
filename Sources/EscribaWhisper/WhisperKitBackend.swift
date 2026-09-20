import Foundation
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import SpeakerKit
import WhisperKit

public enum WhisperKitBackend {
    public static let defaultVariant = "openai_whisper-large-v3-v20240930"
    public static let name = "WhisperKit"

    public static var defaultModelsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/escriba/models")
    }

    public static func make(
        language: String? = "es",
        variant: String = defaultVariant,
        diarize: Bool = false,
        speakerCount: Int? = nil,
        modelsRoot: URL = defaultModelsRoot,
        unloadAfter: Duration = .seconds(300)
    ) -> TranscriptionBackend {
        WhisperKitEngine(
            language: language, variant: variant, modelsRoot: modelsRoot,
            unloadAfter: unloadAfter
        ).backend(diarize: diarize, speakerCount: speakerCount)
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
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        return try await WhisperKit.download(
            variant: variant,
            downloadBase: modelsRoot,
            progressCallback: { progress in onProgress?(progress.fractionCompleted) })
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
                        start: TimeInterval($0.start), end: TimeInterval($0.end),
                        text: $0.word.trimmingCharacters(in: .whitespaces))
                })
        }

        let meaningful = segments.filter { !$0.text.isEmpty }
        guard meaningful.isEmpty else { return Transcript(segments: meaningful) }
        return Transcript(text: clean(fallbackText))
    }

    static func transcript(speakerSegments: [SpeakerSegment]) -> Transcript {
        let segments = speakerSegments.compactMap { segment -> TranscriptSegment? in
            let text = clean(spokenText(of: segment))
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: TimeInterval(segment.startTime),
                end: TimeInterval(segment.endTime),
                speaker: label(segment.speaker),
                text: text,
                words: segment.speakerWords.compactMap { timed in
                    let word = timed.wordTiming.word.trimmingCharacters(in: .whitespaces)
                    guard !word.isEmpty else { return nil }
                    return TranscriptWord(
                        start: TimeInterval(timed.wordTiming.start),
                        end: TimeInterval(timed.wordTiming.end),
                        text: word)
                })
        }
        return Transcript(segments: segments)
    }

    static func spokenText(of segment: SpeakerSegment) -> String {
        let fromWords = segment.text
        guard fromWords.trimmingCharacters(in: .whitespaces).isEmpty else { return fromWords }
        return segment.transcription?.text ?? ""
    }

    static func label(_ speaker: SpeakerInfo) -> String? {
        switch speaker {
        case .speakerId(let id): "Speaker \(id + 1)"
        case .multiple(let ids): ids.map { "Speaker \($0 + 1)" }.joined(separator: " + ")
        case .noMatch: nil
        @unknown default: nil
        }
    }

    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class WhisperKitEngine: Sendable {
    private let engine: Engine

    public init(
        language: String? = "es",
        variant: String = WhisperKitBackend.defaultVariant,
        modelsRoot: URL = WhisperKitBackend.defaultModelsRoot,
        unloadAfter: Duration = .seconds(300)
    ) {
        engine = Engine(
            language: language, variant: variant, modelsRoot: modelsRoot,
            unloadAfter: unloadAfter)
    }

    public func backend(diarize: Bool = false, speakerCount: Int? = nil) -> TranscriptionBackend {
        let engine = engine
        return TranscriptionBackend(
            name: WhisperKitBackend.name,
            transcribe: { source async throws(TranscriptionError) in
                try await TranscriptionError.catching {
                    try engine.preflight()
                    return try await engine.transcript(
                        for: source.path(percentEncoded: false),
                        diarize: diarize, speakerCount: speakerCount)
                }
            },
            preflight: { () throws(TranscriptionError) in
                try TranscriptionError.catching { try engine.preflight() }
            })
    }
}

private actor Engine {
    private let language: String?
    private let variant: String
    private let modelsRoot: URL
    private let unloadAfter: Duration
    private var loaded: WhisperKit?
    private var speaker: SpeakerKit?
    private var unloader: IdleUnloader?

    init(language: String?, variant: String, modelsRoot: URL, unloadAfter: Duration) {
        self.language = language
        self.variant = variant
        self.modelsRoot = modelsRoot
        self.unloadAfter = unloadAfter
    }

    nonisolated func preflight() throws {
        guard WhisperKitBackend.installedModelFolder(variant: variant, modelsRoot: modelsRoot) != nil
        else { throw TranscriptionError.modelMissing(model: variant, installed: []) }
    }

    func transcript(for path: String, diarize: Bool, speakerCount: Int?) async throws -> Transcript {
        let unloader = idleUnloader()
        await unloader.cancel()
        do {
            let transcript = try await perform(path, diarize: diarize, speakerCount: speakerCount)
            await unloader.touch()
            return transcript
        } catch {
            await unloader.touch()
            throw error
        }
    }

    private func perform(
        _ path: String, diarize: Bool, speakerCount: Int?
    ) async throws -> Transcript {
        let kit = try await loadedKit()
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            wordTimestamps: true)

        guard diarize else {
            let batches = await kit.transcribe(audioPaths: [path], decodeOptions: options)
            return WhisperKitBackend.transcript(from: try unwrap(batches, path: path))
        }

        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        let batches = await kit.transcribe(audioArrays: [audio], decodeOptions: options)
        let transcriptions = try unwrap(batches, path: path)

        let diarizationOptions = speakerCount.map {
            PyannoteDiarizationOptions(numberOfSpeakers: $0)
        }
        let diarization = try await loadedSpeakerKit().diarize(
            audioArray: audio, options: diarizationOptions)
        logCentroidDistances(diarization)
        let labelled = diarization.addSpeakerInfo(to: transcriptions).flatMap { $0 }

        return WhisperKitBackend.transcript(speakerSegments: labelled)
    }

    private func unwrap(
        _ batches: [[TranscriptionResult]?], path: String
    ) throws -> [TranscriptionResult] {
        guard let first = batches.first, let transcriptions = first else {
            throw TranscriptionError.failed("WhisperKit no devolvio resultado para \(path)")
        }
        return transcriptions
    }

    private func logCentroidDistances(_ result: DiarizationResult) {
        let ids = result.speakerCentroidEmbeddings.keys.sorted()
        guard ids.count > 1 else {
            Log.info("diarizacion: 1 hablante")
            return
        }

        var pairs: [String] = []
        for (index, a) in ids.enumerated() {
            for b in ids.dropFirst(index + 1) {
                guard let distance = result.centroidCosineDistance(between: a, and: b) else {
                    continue
                }
                pairs.append(String(format: "%d-%d: %.3f", a + 1, b + 1, distance))
            }
        }
        Log.info("diarizacion: \(ids.count) hablantes; distancias \(pairs.joined(separator: ", "))")
    }

    private func idleUnloader() -> IdleUnloader {
        if let unloader { return unloader }
        let created = IdleUnloader(after: unloadAfter) { [weak self] in
            await self?.releaseModels()
        }
        unloader = created
        return created
    }

    private func releaseModels() {
        guard loaded != nil || speaker != nil else { return }
        loaded = nil
        speaker = nil
        Log.info("modelo fuera de memoria tras \(Int(unloadAfter.components.seconds))s sin trabajo")
    }

    private func loadedSpeakerKit() async throws -> SpeakerKit {
        if let speaker { return speaker }
        let created = try await SpeakerKit(PyannoteConfig(download: true, load: true))
        speaker = created
        return created
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

