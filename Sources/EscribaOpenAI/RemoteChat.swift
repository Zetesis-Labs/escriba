import Foundation
import EscribaCore
import EscribaEngine

public enum DigestFormat: Sendable {
    case schema
    case object
}

public let openAICapacity = 48_000

let digestFormatInstruction =
    "Devuelve solo un objeto JSON con las claves title (texto), summary (texto) y tags (lista de textos)."

public func chatRequest(_ request: DigestRequest, endpoint: OpenAIEndpoint, format: DigestFormat) -> RemoteRequest {
    let body: Body = .object([
        "model": .string(endpoint.trimmedModel),
        "messages": .array([
            .object(["role": .string("system"), "content": .string(request.instructions + "\n\n" + digestFormatInstruction)]),
            .object(["role": .string("user"), "content": .string(request.prompt)]),
        ]),
        "response_format": responseFormat(format),
    ])
    return RemoteRequest(
        method: "POST", url: endpointURL(endpoint.baseURL, "chat/completions"),
        headers: endpoint.headers(contentType: "application/json"), body: body.encoded)
}

private func responseFormat(_ format: DigestFormat) -> Body {
    switch format {
    case .object:
        return .object(["type": .string("json_object")])
    case .schema:
        let text: Body = .object(["type": .string("string")])
        return .object([
            "type": .string("json_schema"),
            "json_schema": .object([
                "name": .string("digest"),
                "strict": .bool(true),
                "schema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": text,
                        "summary": text,
                        "tags": .object(["type": .string("array"), "items": text]),
                    ]),
                    "required": .array([.string("title"), .string("summary"), .string("tags")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ])
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message
    }

    let choices: [Choice]
}

public func digest(fromChat body: Data) throws(RemoteAPIError) -> Digest {
    guard let response = try? JSONDecoder().decode(ChatResponse.self, from: body) else {
        throw .malformed("no es una respuesta de chat")
    }
    guard let content = response.choices.first?.message.content, !content.isEmpty else {
        throw .malformed("el modelo no devolvió texto")
    }
    return try digest(fromContent: content)
}

private func digest(fromContent content: String) throws(RemoteAPIError) -> Digest {
    guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
        let object = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any]
    else { throw .malformed("el modelo no devolvió un objeto JSON") }

    let title = object["title"] as? String ?? ""
    let summary = object["summary"] as? String ?? ""
    guard !(title + summary).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw .malformed("el JSON no trae ni título ni resumen")
    }
    let tags = (object["tags"] as? [String])
        ?? (object["tags"] as? String).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        ?? []
    return Digest(title: title, summary: summary, tags: tags)
}

public func openAISummarizer(
    name: String, endpoint: OpenAIEndpoint, capacity: Int = openAICapacity,
    transport: @escaping RemoteTransport
) -> Summarizer {
    Summarizer(
        name: name, capacity: capacity,
        availability: { endpoint.problem.map(SummaryAvailability.unavailable) ?? .ready }
    ) { request throws(SummaryError) in
        do throws(RemoteAPIError) {
            return try await askForDigest(request, endpoint: endpoint, transport: transport)
        } catch {
            throw error.blocksEveryRecording ? .unavailable(error.message) : .failed(error.message)
        }
    }
}

private func askForDigest(
    _ request: DigestRequest, endpoint: OpenAIEndpoint, transport: RemoteTransport
) async throws(RemoteAPIError) -> Digest {
    do {
        return try digest(fromChat: try await send(chatRequest(request, endpoint: endpoint, format: .schema), over: transport))
    } catch where error.isAboutResponseFormat {
        return try digest(fromChat: try await send(chatRequest(request, endpoint: endpoint, format: .object), over: transport))
    }
}

public func modelsRequest(endpoint: OpenAIEndpoint) -> RemoteRequest {
    RemoteRequest(method: "GET", url: endpointURL(endpoint.baseURL, "models"), headers: endpoint.headers())
}

private struct ModelList: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

public func modelIDs(from body: Data) throws(RemoteAPIError) -> [String] {
    guard let list = try? JSONDecoder().decode(ModelList.self, from: body) else {
        throw .malformed("la lista de modelos no tiene el formato de OpenAI")
    }
    return list.data.map(\.id).sorted()
}

public func remoteModels(
    endpoint: OpenAIEndpoint, transport: @escaping RemoteTransport
) async throws(RemoteAPIError) -> [String] {
    try modelIDs(from: try await send(modelsRequest(endpoint: endpoint), over: transport))
}
