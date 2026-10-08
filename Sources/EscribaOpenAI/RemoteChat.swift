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
    try digest(fromContent: try chatContent(from: body))
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

let answerFormatInstruction = "Devuelve solo un objeto JSON que cumpla este esquema: "

public func answerRequest(_ request: AnswerRequest, endpoint: OpenAIEndpoint, format: DigestFormat) -> RemoteRequest {
    var system = request.instructions ?? ""
    if let schema = request.schema, format == .object {
        system += (system.isEmpty ? "" : "\n\n") + answerFormatInstruction + dataText(jsonSchema(schema))
    }
    var messages: [DataValue] = []
    if !system.isEmpty {
        messages.append(.object([
            DataField(name: "role", value: .string("system")), DataField(name: "content", value: .string(system)),
        ]))
    }
    messages.append(.object([
        DataField(name: "role", value: .string("user")), DataField(name: "content", value: .string(request.input)),
    ]))
    var body = [
        DataField(name: "model", value: .string(endpoint.trimmedModel)),
        DataField(name: "messages", value: .array(messages)),
    ]
    if let schema = request.schema {
        body.append(DataField(name: "response_format", value: answerFormat(schema, format)))
    }
    return RemoteRequest(
        method: "POST", url: endpointURL(endpoint.baseURL, "chat/completions"),
        headers: endpoint.headers(contentType: "application/json"), body: Data(dataText(.object(body)).utf8))
}

private func answerFormat(_ schema: AnswerSchema, _ format: DigestFormat) -> DataValue {
    switch format {
    case .object:
        return .object([DataField(name: "type", value: .string("json_object"))])
    case .schema:
        return .object([
            DataField(name: "type", value: .string("json_schema")),
            DataField(name: "json_schema", value: .object([
                DataField(name: "name", value: .string("respuesta")),
                DataField(name: "strict", value: .bool(isStrict(schema))),
                DataField(name: "schema", value: jsonSchema(schema)),
            ])),
        ])
    }
}

public func chatContent(from body: Data) throws(RemoteAPIError) -> String {
    guard let response = try? JSONDecoder().decode(ChatResponse.self, from: body) else {
        throw .malformed("no es una respuesta de chat")
    }
    guard let content = response.choices.first?.message.content, !content.isEmpty else {
        throw .malformed("el modelo no devolvió texto")
    }
    return content
}

public func openAIAsker(
    name: String, endpoint: OpenAIEndpoint, capacity: Int = openAICapacity, transport: @escaping RemoteTransport
) -> Asker {
    Asker(
        name: name, capacity: capacity,
        availability: { endpoint.problem.map(SummaryAvailability.unavailable) ?? .ready }
    ) { request throws(AnswerError) in
        do throws(RemoteAPIError) {
            return try await askForAnswer(request, endpoint: endpoint, transport: transport)
        } catch {
            throw error.blocksEveryRecording ? .unavailable(error.message) : .failed(error.message)
        }
    }
}

private func askForAnswer(
    _ request: AnswerRequest, endpoint: OpenAIEndpoint, transport: RemoteTransport
) async throws(RemoteAPIError) -> String {
    do {
        return try chatContent(from: try await send(answerRequest(request, endpoint: endpoint, format: .schema), over: transport))
    } catch where request.schema != nil && error.isAboutResponseFormat {
        return try chatContent(from: try await send(answerRequest(request, endpoint: endpoint, format: .object), over: transport))
    }
}
