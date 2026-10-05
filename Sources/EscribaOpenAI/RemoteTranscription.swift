import Foundation
import EscribaCore
import EscribaEngine

public enum TranscriptionFormat: Sendable {
    case detailed
    case plain
}

public func transcriptionRequest(
    audio: Data, fileName: String, language: String?, endpoint: OpenAIEndpoint,
    format: TranscriptionFormat, boundary: String
) -> RemoteRequest {
    var fields = [
        ("model", endpoint.trimmedModel),
        ("response_format", format == .detailed ? "verbose_json" : "json"),
    ]
    if format == .detailed { fields.append(("timestamp_granularities[]", "segment")) }
    if let language, !language.isEmpty { fields.append(("language", language)) }

    var body = Data()
    for (name, value) in fields {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    body.append(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: \(audioMimeType(for: fileName))\r\n\r\n")
    body.append(audio)
    body.append("\r\n--\(boundary)--\r\n")

    return RemoteRequest(
        method: "POST", url: endpointURL(endpoint.baseURL, "audio/transcriptions"),
        headers: endpoint.headers(contentType: "multipart/form-data; boundary=\(boundary)"), body: body)
}

func audioMimeType(for fileName: String) -> String {
    switch (fileName as NSString).pathExtension.lowercased() {
    case "m4a", "mp4", "aac": "audio/mp4"
    case "mp3", "mpga", "mpeg": "audio/mpeg"
    case "wav": "audio/wav"
    case "ogg", "oga": "audio/ogg"
    case "flac": "audio/flac"
    case "webm": "audio/webm"
    case "caf": "audio/x-caf"
    default: "application/octet-stream"
    }
}

private struct TranscriptionResponse: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    let text: String
    let duration: Double?
    let segments: [Segment]?
}

public func transcript(fromTranscription body: Data) throws(RemoteAPIError) -> Transcript {
    guard let response = try? JSONDecoder().decode(TranscriptionResponse.self, from: body) else {
        throw .malformed("no es una transcripción")
    }
    if let segments = response.segments, !segments.isEmpty {
        return Transcript(segments: segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : TranscriptSegment(start: segment.start, end: segment.end, text: text)
        })
    }
    let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return Transcript(segments: []) }
    return Transcript(segments: [TranscriptSegment(start: 0, end: response.duration ?? 0, text: text)])
}

public func openAITranscriber(
    name: String, endpoint: OpenAIEndpoint, language: String?,
    transport: @escaping RemoteTransport,
    readAudio: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
    boundary: @escaping @Sendable () -> String = { "escriba-\(UUID().uuidString)" }
) -> TranscriptionBackend {
    TranscriptionBackend(
        name: name,
        transcribe: { source async throws(TranscriptionError) in
            if let problem = endpoint.problem { throw .backendUnavailable("\(name): \(problem)") }
            let audio = try TranscriptionError.catching { try readAudio(source) }
            do throws(RemoteAPIError) {
                return try await transcribe(
                    audio, fileName: source.lastPathComponent, language: language, endpoint: endpoint,
                    boundary: boundary(), transport: transport)
            } catch {
                throw error.blocksEveryRecording
                    ? .backendUnavailable("\(name): \(error.message)") : .failed("\(name): \(error.message)")
            }
        },
        preflight: { () throws(TranscriptionError) in
            if let problem = endpoint.problem { throw .backendUnavailable("\(name): \(problem)") }
        })
}

private func transcribe(
    _ audio: Data, fileName: String, language: String?, endpoint: OpenAIEndpoint, boundary: String,
    transport: RemoteTransport
) async throws(RemoteAPIError) -> Transcript {
    func ask(_ format: TranscriptionFormat) async throws(RemoteAPIError) -> Transcript {
        let request = transcriptionRequest(
            audio: audio, fileName: fileName, language: language, endpoint: endpoint, format: format,
            boundary: boundary)
        return try transcript(fromTranscription: try await send(request, over: transport))
    }
    do {
        return try await ask(.detailed)
    } catch where error.isAboutResponseFormat {
        return try await ask(.plain)
    }
}

public func silentWAV(seconds: Double = 1, sampleRate: Int = 16_000) -> Data {
    let samples = Int(seconds * Double(sampleRate))
    let dataSize = UInt32(samples * 2)
    var wav = Data("RIFF".utf8)
    wav.append(littleEndian: 36 + dataSize)
    wav.append(Data("WAVEfmt ".utf8))
    wav.append(littleEndian: UInt32(16))
    wav.append(littleEndian: UInt16(1))
    wav.append(littleEndian: UInt16(1))
    wav.append(littleEndian: UInt32(sampleRate))
    wav.append(littleEndian: UInt32(sampleRate * 2))
    wav.append(littleEndian: UInt16(2))
    wav.append(littleEndian: UInt16(16))
    wav.append(Data("data".utf8))
    wav.append(littleEndian: dataSize)
    wav.append(Data(count: samples * 2))
    return wav
}

extension Data {
    fileprivate mutating func append(_ text: String) {
        append(Data(text.utf8))
    }

    fileprivate mutating func append<Value: FixedWidthInteger>(littleEndian value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
