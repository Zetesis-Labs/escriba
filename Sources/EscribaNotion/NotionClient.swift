import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public let notionAPIVersion = "2025-09-03"

public enum NotionError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case rateLimited
    case api(status: Int, message: String)
    case transport(String)
    case malformed(String)

    public var message: String {
        switch self {
        case .unauthorized:
            "Notion rechaza el token. Revísalo en Ajustes."
        case .forbidden(let detail):
            "Notion no da acceso: \(detail). Comparte la base con la integración."
        case .notFound(let detail):
            "Notion no encuentra eso: \(detail)."
        case .rateLimited:
            "Notion está limitando las peticiones. Se reintenta más tarde."
        case .api(let status, let message):
            "Notion devolvió \(status): \(message)"
        case .transport(let detail):
            "No se pudo hablar con Notion: \(detail)"
        case .malformed(let detail):
            "Respuesta de Notion ilegible: \(detail)"
        }
    }
}

public struct NotionHTTPRequest: Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public var path: String { URL(string: url)?.path() ?? url }
    public var query: String? { URL(string: url)?.query() }
}

public struct NotionHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public typealias NotionTransport = @Sendable (NotionHTTPRequest) async throws -> NotionHTTPResponse

public struct NotionClient: Sendable {
    public var dataSources: @Sendable () async throws(NotionError) -> [NotionDataSource]
    public var createPage: @Sendable (JSONValue) async throws(NotionError) -> NotionPageRef
    public var updatePage: @Sendable (String, JSONValue) async throws(NotionError) -> Void
    public var appendBlocks: @Sendable (String, JSONValue) async throws(NotionError) -> Void
    public var childBlocks: @Sendable (String) async throws(NotionError) -> [String]
    public var deleteBlock: @Sendable (String) async throws(NotionError) -> Void
    public var findPage: @Sendable (String, JSONValue) async throws(NotionError) -> NotionPageRef?
    public var uploadFile: @Sendable (URL) async throws(NotionError) -> String

    public init(
        dataSources: @escaping @Sendable () async throws(NotionError) -> [NotionDataSource],
        createPage: @escaping @Sendable (JSONValue) async throws(NotionError) -> NotionPageRef,
        updatePage: @escaping @Sendable (String, JSONValue) async throws(NotionError) -> Void,
        appendBlocks: @escaping @Sendable (String, JSONValue) async throws(NotionError) -> Void,
        childBlocks: @escaping @Sendable (String) async throws(NotionError) -> [String],
        deleteBlock: @escaping @Sendable (String) async throws(NotionError) -> Void,
        findPage: @escaping @Sendable (String, JSONValue) async throws(NotionError) -> NotionPageRef?,
        uploadFile: @escaping @Sendable (URL) async throws(NotionError) -> String = { _ throws(NotionError) in
            throw NotionError.malformed("este cliente no sube ficheros")
        }
    ) {
        self.dataSources = dataSources
        self.createPage = createPage
        self.updatePage = updatePage
        self.appendBlocks = appendBlocks
        self.childBlocks = childBlocks
        self.deleteBlock = deleteBlock
        self.findPage = findPage
        self.uploadFile = uploadFile
    }
}

public typealias NotionPause = @Sendable (Duration) async -> Void

public let notionSinglePartLimit = 20 * 1024 * 1024
public let notionPartSize = 10 * 1024 * 1024

#if !os(WASI)
public func makeNotionClient(
    token: String,
    transport: @escaping NotionTransport = urlSessionTransport(),
    pause: @escaping NotionPause = { try? await Task.sleep(for: $0) },
    singlePartLimit: Int = notionSinglePartLimit,
    partSize: Int = notionPartSize
) -> NotionClient {
    makeNotionClient(
        token: token, over: transport, pause: pause, singlePartLimit: singlePartLimit,
        partSize: partSize)
}

#endif

public func makeNotionClient(
    token: String,
    over transport: @escaping NotionTransport,
    pause: @escaping NotionPause = { try? await Task.sleep(for: $0) },
    singlePartLimit: Int = notionSinglePartLimit,
    partSize: Int = notionPartSize
) -> NotionClient {
    let call = notionCall(token: token, transport: transport, pause: pause)

    return NotionClient(
        dataSources: { () throws(NotionError) in
            var sources: [NotionDataSource] = []
            var cursor: String?

            repeat {
                let body = searchDataSourcesBody(cursor: cursor)
                let page = try await call(.post, "search", .json(body))
                sources += parseDataSources(page)
                cursor = nextCursor(page)
            } while cursor != nil

            return sources.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        },
        createPage: { body throws(NotionError) in
            let json = try await call(.post, "pages", .json(body))
            guard let page = parsePage(json) else { throw NotionError.malformed("sin página creada") }
            return page
        },
        updatePage: { id, body throws(NotionError) in _ = try await call(.patch, "pages/\(id)", .json(body)) },
        appendBlocks: { id, body throws(NotionError) in
            _ = try await call(.patch, "blocks/\(id)/children", .json(body))
        },
        childBlocks: { id throws(NotionError) in
            var ids: [String] = []
            var cursor: String?

            repeat {
                let query = cursor.map { "&start_cursor=\($0)" } ?? ""
                let json = try await call(.get, "blocks/\(id)/children?page_size=100\(query)", nil)
                if case .array(let results)? = json["results"] {
                    ids += results.compactMap { $0["id"]?.text }
                }
                cursor = nextCursor(json)
            } while cursor != nil

            return ids
        },
        deleteBlock: { id throws(NotionError) in _ = try await call(.delete, "blocks/\(id)", nil) },
        findPage: { dataSourceId, body throws(NotionError) in
            parseFirstPage(try await call(.post, "data_sources/\(dataSourceId)/query", .json(body)))
        },
        uploadFile: { file throws(NotionError) in
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                throw NotionError.transport("no se pudo leer \(file.lastPathComponent)")
            }
            let parts = uploadParts(size: data.count, singlePartLimit: singlePartLimit, partSize: partSize)
            let created = try await call(
                .post, "file_uploads",
                .json(createUploadBody(filename: file.lastPathComponent, contentType: mimeType(of: file), parts: parts.count)))
            guard let id = created["id"]?.text else { throw NotionError.malformed("sin id de subida") }

            for (index, range) in parts.enumerated() {
                let form = NotionMultipart(
                    fields: parts.count > 1 ? [("part_number", "\(index + 1)")] : [],
                    file: (name: "file", filename: file.lastPathComponent, contentType: mimeType(of: file), data: data[range]))
                _ = try await call(.post, "file_uploads/\(id)/send", .multipart(form))
            }
            if parts.count > 1 {
                _ = try await call(.post, "file_uploads/\(id)/complete", .json(.object([:])))
            }
            return id
        })
}

public struct NotionMultipart: Sendable {
    public let fields: [(String, String)]
    public let file: (name: String, filename: String, contentType: String, data: Data)
}

public enum NotionBody: Sendable {
    case json(JSONValue)
    case multipart(NotionMultipart)
}

func uploadParts(size: Int, singlePartLimit: Int, partSize: Int) -> [Range<Int>] {
    guard size > singlePartLimit else { return [0..<size] }
    return stride(from: 0, to: size, by: partSize).map { $0..<min($0 + partSize, size) }
}

func createUploadBody(filename: String, contentType: String, parts: Int) -> JSONValue {
    var body: [String: JSONValue] = [
        "mode": .string(parts > 1 ? "multi_part" : "single_part"),
        "filename": .string(filename),
        "content_type": .string(contentType),
    ]
    if parts > 1 { body["number_of_parts"] = .number(Double(parts)) }
    return .object(body)
}

func mimeType(of file: URL) -> String {
    switch file.pathExtension.lowercased() {
    case "m4a": "audio/mp4"
    case "mp3": "audio/mpeg"
    case "wav": "audio/wav"
    case "aac": "audio/aac"
    case "ogg", "oga": "audio/ogg"
    case "flac": "audio/flac"
    case "mp4", "m4v": "video/mp4"
    case "mov": "video/quicktime"
    default: "application/octet-stream"
    }
}

func multipartBody(_ form: NotionMultipart, boundary: String) -> Data {
    var body = Data()
    func line(_ text: String) { body.append(Data(text.utf8)) }

    for (name, value) in form.fields {
        line("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    line("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(form.file.name)\"; filename=\"\(form.file.filename)\"\r\n")
    line("Content-Type: \(form.file.contentType)\r\n\r\n")
    body.append(form.file.data)
    line("\r\n--\(boundary)--\r\n")
    return body
}

public func searchDataSourcesBody(cursor: String?) -> JSONValue {
    var body: [String: JSONValue] = [
        "filter": .object(["value": .string("data_source"), "property": .string("object")]),
        "page_size": .number(100),
    ]
    if let cursor { body["start_cursor"] = .string(cursor) }
    return .object(body)
}

enum NotionMethod: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

typealias NotionCall = @Sendable (NotionMethod, String, NotionBody?) async throws(NotionError) -> JSONValue

let notionRetryLimit = 5

func notionCall(
    token: String, transport: @escaping NotionTransport, pause: @escaping NotionPause
) -> NotionCall {
    { method, path, body throws(NotionError) in
        var request = NotionHTTPRequest(
            method: method.rawValue,
            url: "https://api.notion.com/v1/\(path)",
            headers: ["Authorization": "Bearer \(token)", "Notion-Version": notionAPIVersion])

        switch body {
        case .json(let json):
            request.headers["Content-Type"] = "application/json"
            request.body = try encoded(json)
        case .multipart(let form):
            let boundary = "escriba-\(UUID().uuidString)"
            request.headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
            request.body = multipartBody(form, boundary: boundary)
        case nil:
            break
        }

        let replayable = isReplayable(method, path)
        for attempt in 1...notionRetryLimit {
            let response: NotionHTTPResponse
            do {
                response = try await transport(request)
            } catch {
                guard replayable, attempt < notionRetryLimit else {
                    throw NotionError.transport("\(error)")
                }
                await pause(.seconds(Double(1 << (attempt - 1))))
                continue
            }

            let json = (try? JSONSerialization.jsonObject(with: response.body)).map(jsonValue(from:)) ?? .null
            if (200..<300).contains(response.status) { return json }

            let error = failure(status: response.status, json: json)
            guard error == .rateLimited, attempt < notionRetryLimit else { throw error }
            await pause(retryDelay(response.header("Retry-After")))
        }
        throw NotionError.rateLimited
    }
}

func isReplayable(_ method: NotionMethod, _ path: String) -> Bool {
    method != .post || path.hasPrefix("search") || path.hasSuffix("/query") || path.hasSuffix("/send")
}

func retryDelay(_ retryAfter: String?) -> Duration {
    let seconds = retryAfter.flatMap(Double.init).map { min(max($0, 0.5), 30) } ?? 1
    return .seconds(seconds)
}

private func encoded(_ body: JSONValue) throws(NotionError) -> Data {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(body)
    } catch {
        throw NotionError.malformed("no se pudo serializar la petición")
    }
}

private func failure(status: Int, json: JSONValue) -> NotionError {
    let detail = parseErrorMessage(json) ?? "sin detalle"

    return switch status {
    case 401: .unauthorized
    case 403: .forbidden(detail)
    case 404: .notFound(detail)
    case 429: .rateLimited
    default: .api(status: status, message: detail)
    }
}

#if !os(WASI)
public func urlSessionTransport(session: URLSession = .shared) -> NotionTransport {
    { request in
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var native = URLRequest(url: url)
        native.httpMethod = request.method
        native.httpBody = request.body
        for (name, value) in request.headers { native.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: native)
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { headers, pair in
            headers["\(pair.key)"] = "\(pair.value)"
        }
        return NotionHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}
#endif
