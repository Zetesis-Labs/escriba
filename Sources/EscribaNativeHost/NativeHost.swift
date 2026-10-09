import AVFoundation
import Foundation
import EscribaCore
import EscribaEngine
import EscribaIntelligence
import EscribaWhisper

struct HostFailure: Error {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// The native seam exposed to the Tauri host. One instance lives for the entire child process.
@MainActor
final class NativeHost {
    private var transcriptionEngines: [String: WhisperKitEngine] = [:]
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingPaused = false

    func handle(_ line: String) async -> String {
        let id: DataValue
        let method: String
        let params: DataValue
        do {
            let request = try parseData(line)
            guard case .object = request else { throw HostFailure("invalid_request", "la petición debe ser un objeto") }
            id = request["id"] ?? .null
            guard let value = request["id"]?.text, !value.isEmpty else {
                throw HostFailure("invalid_request", "id debe ser un texto no vacío")
            }
            guard let name = request["method"]?.text else {
                throw HostFailure("invalid_request", "method debe ser un texto")
            }
            method = name
            guard let input = request["params"], case .object = input else {
                throw HostFailure("invalid_request", "params debe ser un objeto")
            }
            params = input
        } catch {
            let recoveredID = (try? parseData(line))?["id"] ?? .null
            return reply(id: recoveredID, error: failure(error))
        }

        do {
            return reply(id: id, result: try await perform(method, params: params))
        } catch {
            return reply(id: id, error: failure(error))
        }
    }

    private func perform(_ method: String, params: DataValue) async throws -> DataValue {
        switch method {
        case "status": return try status(params)
        case "transcribe": return try await transcribe(params)
        case "summarize": return try await summarize(params)
        case "ask": return try await ask(params)
        case "audioInfo": return try audioInfo(params)
        case "fileStatus": return try fileStatus(params)
        case "materialize": return try await materialize(params)
        case "downloadModel": return try await downloadModel(params)
        case "recordingStatus": return recordingStatus()
        case "recordingStart": return try await recordingStart(params)
        case "recordingPause": return try recordingPause()
        case "recordingResume": return try recordingResume()
        case "recordingStop": return try recordingStop()
        default: throw HostFailure("unknown_method", "método desconocido: \(method)")
        }
    }

    private func status(_ params: DataValue) throws -> DataValue {
        let model = try modelName(params)
        let availability = AppleIntelligence.availability()
        return .object([
            field("protocolVersion", .number(1)),
            field("whisper", .object([
                field("available", .bool(WhisperKitBackend.installedModelFolder(variant: model) != nil)),
                field("model", .string(model)),
                field("modelsPath", .string(WhisperKitBackend.defaultModelsRoot.path(percentEncoded: false))),
            ])),
            field("llm", .object([
                field("available", .bool(availability.isReady)),
                field("reason", availability.problem.map(DataValue.string) ?? .null),
                field("capacity", .number(Double(AppleIntelligence.capacity))),
            ])),
        ])
    }

    private func transcribe(_ params: DataValue) async throws -> DataValue {
        let url = try audioURL(params)
        let variant = try modelName(params)
        let language = try transcriptionLanguage(params)
        let diarize = try optionalBool(params, "diarize") ?? false
        let speakers: Int?
        if params["speakers"] == .null {
            speakers = nil
        } else {
            speakers = try optionalPositiveInt(params, "speakers")
        }
        let key = variant + "\u{0}" + (language ?? "auto")
        let engine: WhisperKitEngine
        if let existing = transcriptionEngines[key] {
            engine = existing
        } else {
            let created = WhisperKitEngine(language: language, variant: variant)
            transcriptionEngines[key] = created
            engine = created
        }
        let transcript = try await engine.backend(diarize: diarize, speakerCount: speakers).transcribe(url)
        let duration = try audioDuration(url)
        return .object([
            field("text", .string(transcript.text)),
            field("segments", .array(transcript.segments.map(segmentValue))),
            field("language", .string(language ?? "auto")),
            field("duration", .number(duration)),
        ])
    }

    private func summarize(_ params: DataValue) async throws -> DataValue {
        if case .unavailable(let reason) = AppleIntelligence.availability() {
            throw HostFailure("backend_unavailable", "Apple Intelligence no está disponible: \(reason)")
        }
        let digest = try await AppleIntelligence.summarizer().run(DigestRequest(
            instructions: try requiredString(params, "instructions"),
            prompt: try requiredString(params, "prompt")))
        return .object([
            field("title", .string(digest.title)),
            field("summary", .string(digest.summary)),
            field("tags", .array(digest.tags.map(DataValue.string))),
        ])
    }

    private func ask(_ params: DataValue) async throws -> DataValue {
        let instructions = try requiredString(params, "instructions")
        let prompt = try requiredString(params, "prompt")
        let schema: AnswerSchema?
        if let value = params["schema"], value != .null {
            schema = try answerSchema(from: value)
        } else {
            schema = nil
        }
        return try await AppleIntelligence.asker().answer(AnswerRequest(
            instructions: instructions, input: prompt, schema: schema))
    }

    private func audioInfo(_ params: DataValue) throws -> DataValue {
        .object([field("duration", .number(try audioDuration(audioURL(params))))])
    }

    private func fileStatus(_ params: DataValue) throws -> DataValue {
        let path = try requiredString(params, "path")
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw HostFailure("audio_missing", "no existe el fichero de audio: \(path)")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw HostFailure("invalid_audio", "la ruta no es un archivo de audio regular")
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return .object([
            field("size", .number(Double(info.st_size))),
            field("blocks", .number(Double(info.st_blocks))),
            field("flags", .number(Double(info.st_flags))),
            field("dataless", .bool(UInt32(info.st_flags) & SF_DATALESS != 0)),
            field("modifiedAt", .string(ISO8601DateFormatter().string(from: modified))),
        ])
    }

    private func materialize(_ params: DataValue) async throws -> DataValue {
        let folder = try materializationFolder(params)
        let started = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if started { folder?.stopAccessingSecurityScopedResource() } }
        let path = try requiredString(params, "path")
        let url = URL(fileURLWithPath: path)
        if let folder {
            let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                throw HostFailure("invalid_params", "El audio no pertenece a la carpeta autorizada")
            }
        }
        _ = try fileStatus(params)
        let timeout = try optionalPositiveInt(params, "timeoutSeconds") ?? 300
        guard timeout <= 300 else {
            throw HostFailure("invalid_params", "timeoutSeconds no puede superar 300")
        }
        let completed = await Task.detached(priority: .utility) {
            requestMaterialization(url, timeout: timeout)
        }.value
        let state = try fileStatus(params)
        let size: Double
        if case .number(let value) = state["size"] { size = value } else { size = 0 }
        return .object([
            field("ready", .bool(completed && state["dataless"] == .bool(false) && size > 0)),
            field("dataless", state["dataless"] ?? .bool(false)),
            field("size", state["size"] ?? .number(0)),
        ])
    }

    private func materializationFolder(_ params: DataValue) throws -> URL? {
        guard let value = params["folderBookmark"], value != .null else { return nil }
        guard case .array(let values) = value, !values.isEmpty, values.count <= 65_536 else {
            throw HostFailure("invalid_params", "La autorización de carpeta no es válida")
        }
        let bytes = try values.map { value -> UInt8 in
            guard case .number(let number) = value, let byte = UInt8(exactly: number) else {
                throw HostFailure("invalid_params", "La autorización de carpeta no es válida")
            }
            return byte
        }
        var stale = false
        do {
            return try URL(
                resolvingBookmarkData: Data(bytes),
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw HostFailure("invalid_params", "No se pudo recuperar la autorización de carpeta: \(error.localizedDescription)")
        }
    }

    private func downloadModel(_ params: DataValue) async throws -> DataValue {
        let variant = try modelName(params)
        let folder = try await WhisperKitBackend.downloadModel(variant: variant)
        return .object([field("model", .string(variant)), field("path", .string(folder.path(percentEncoded: false)))])
    }

    private func recordingStart(_ params: DataValue) async throws -> DataValue {
        guard recorder == nil else { throw HostFailure("recording_active", "ya hay una grabación en curso") }
        let path = try requiredString(params, "outputPath")
        let url = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw HostFailure("file_exists", "el fichero de salida ya existe")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw HostFailure("microphone_denied", "sin permiso para usar el micrófono")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let created = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ])
        guard created.record() else { throw HostFailure("recording_failed", "el micrófono no empezó a grabar") }
        recorder = created
        recordingURL = url
        recordingPaused = false
        return .object([field("audioPath", .string(path))])
    }

    private func recordingStatus() -> DataValue {
        .object([
            field("active", .bool(recorder != nil)),
            field("paused", .bool(recorder != nil && recordingPaused)),
            field("audioPath", recordingURL.map { .string($0.path(percentEncoded: false)) } ?? .null),
            field("duration", .number(recorder?.currentTime ?? 0)),
        ])
    }

    private func recordingPause() throws -> DataValue {
        guard let recorder else { throw HostFailure("recording_inactive", "no hay grabación en curso") }
        recorder.pause()
        recordingPaused = true
        return .object([field("audioPath", .string(recordingURL?.path(percentEncoded: false) ?? "")),
                        field("duration", .number(recorder.currentTime))])
    }

    private func recordingResume() throws -> DataValue {
        guard let recorder else { throw HostFailure("recording_inactive", "no hay grabación en curso") }
        guard recorder.record() else { throw HostFailure("recording_failed", "no se pudo reanudar la grabación") }
        recordingPaused = false
        return .object([field("audioPath", .string(recordingURL?.path(percentEncoded: false) ?? "")),
                        field("duration", .number(recorder.currentTime))])
    }

    private func recordingStop() throws -> DataValue {
        guard let recorder, let url = recordingURL else {
            throw HostFailure("recording_inactive", "no hay grabación en curso")
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        recordingURL = nil
        recordingPaused = false
        return .object([field("audioPath", .string(url.path(percentEncoded: false))),
                        field("duration", .number(duration))])
    }

    private func audioURL(_ params: DataValue) throws -> URL {
        let path = try requiredString(params, "audioPath")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw HostFailure("audio_missing", "no existe el fichero de audio: \(path)")
        }
        return URL(fileURLWithPath: path)
    }

    private func audioDuration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { throw HostFailure("invalid_audio", "audio sin frecuencia válida") }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func modelName(_ params: DataValue) throws -> String {
        let name = try optionalString(params, "model") ?? WhisperKitBackend.defaultVariant
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw HostFailure("invalid_params", "model debe ser un nombre de variante, sin rutas")
        }
        return name
    }

    private func transcriptionLanguage(_ params: DataValue) throws -> String? {
        guard let value = params["language"] else { return "es" }
        if value == .null { return nil }
        guard case .string(let language) = value else {
            throw HostFailure("invalid_params", "language debe ser un código de idioma o auto")
        }
        if language == "auto" { return nil }
        guard language.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil else {
            throw HostFailure("invalid_params", "language debe ser un código de idioma o auto")
        }
        return language
    }

    private func requiredString(_ params: DataValue, _ name: String) throws -> String {
        guard let value = params[name]?.text, !value.isEmpty else {
            throw HostFailure("invalid_params", "\(name) debe ser un texto no vacío")
        }
        return value
    }

    private func optionalString(_ params: DataValue, _ name: String) throws -> String? {
        guard let value = params[name] else { return nil }
        guard case .string(let text) = value else { throw HostFailure("invalid_params", "\(name) debe ser un texto") }
        return text
    }

    private func optionalBool(_ params: DataValue, _ name: String) throws -> Bool? {
        guard let value = params[name] else { return nil }
        guard case .bool(let flag) = value else { throw HostFailure("invalid_params", "\(name) debe ser booleano") }
        return flag
    }

    private func optionalPositiveInt(_ params: DataValue, _ name: String) throws -> Int? {
        guard let value = params[name] else { return nil }
        guard case .number(let number) = value, number > 0, number < 100, number.rounded() == number else {
            throw HostFailure("invalid_params", "\(name) debe ser entero positivo")
        }
        return Int(number)
    }
}

nonisolated private func requestMaterialization(_ url: URL, timeout: Int) -> Bool {
    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        if let handle = try? FileHandle(forReadingFrom: url) {
            _ = try? handle.read(upToCount: 1)
            try? handle.close()
        }
        finished.signal()
    }
    return finished.wait(timeout: .now() + .seconds(timeout)) == .success
}

private func segmentValue(_ segment: TranscriptSegment) -> DataValue {
    .object([
        field("start", .number(segment.start)),
        field("end", .number(segment.end)),
        field("text", .string(segment.text)),
        field("speaker", segment.speaker.map(DataValue.string) ?? .null),
        field("words", .array(segment.words.map { word in .object([
            field("start", .number(word.start)), field("end", .number(word.end)),
            field("text", .string(word.text)),
        ]) })),
    ])
}

private func field(_ name: String, _ value: DataValue) -> DataField {
    DataField(name: name, value: value)
}

private func failure(_ error: Error) -> HostFailure {
    if let known = error as? HostFailure { return known }
    if error is DataParseError { return HostFailure("invalid_json", "JSON inválido: \(error)") }
    if error is AnswerSchemaProblem { return HostFailure("invalid_schema", "\(error)") }
    if let error = error as? TranscriptionError {
        switch error {
        case .backendUnavailable, .modelMissing:
            return HostFailure("backend_unavailable", "\(error)")
        default:
            return HostFailure("transcription_failed", "\(error)")
        }
    }
    if let error = error as? SummaryError {
        if case .unavailable = error { return HostFailure("backend_unavailable", "\(error)") }
        return HostFailure("llm_failed", "\(error)")
    }
    if let error = error as? AnswerError {
        if case .unavailable = error { return HostFailure("backend_unavailable", "\(error)") }
        return HostFailure("llm_failed", "\(error)")
    }
    return HostFailure("native_error", "\(error)")
}

private func reply(id: DataValue, result: DataValue) -> String {
    dataText(.object([field("id", id), field("result", result)]))
}

private func reply(id: DataValue, error: HostFailure) -> String {
    dataText(.object([
        field("id", id),
        field("error", .object([field("code", .string(error.code)), field("message", .string(error.message))])),
    ]))
}
