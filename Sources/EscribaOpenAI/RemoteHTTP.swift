import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RemoteRequest: Sendable, Equatable {
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
}

public struct RemoteResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

public typealias RemoteTransport = @Sendable (RemoteRequest) async throws -> RemoteResponse

public struct OpenAIEndpoint: Sendable {
    public var baseURL: String
    public var model: String
    public var apiKey: @Sendable () -> String?

    public init(baseURL: String, model: String, apiKey: @escaping @Sendable () -> String? = { nil }) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    func headers(contentType: String? = nil) -> [String: String] {
        var headers = ["Accept": "application/json"]
        if let contentType { headers["Content-Type"] = contentType }
        if let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }
        return headers
    }

    var problem: String? {
        if let problem = remoteURLProblem(baseURL) { return problem }
        return trimmedModel.isEmpty ? "Elige el modelo." : nil
    }
}

public func endpointURL(_ base: String, _ path: String) -> String {
    var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while root.hasSuffix("/") { root.removeLast() }
    return root + "/" + path.drop { $0 == "/" }
}

func send(_ request: RemoteRequest, over transport: RemoteTransport) async throws(RemoteAPIError) -> Data {
    let response: RemoteResponse
    do {
        response = try await transport(request)
    } catch {
        throw .transport("\(host(of: request.url)): \(error.localizedDescription)")
    }
    guard (200..<300).contains(response.status) else {
        throw remoteError(status: response.status, body: response.body)
    }
    return response.body
}

private func host(of url: String) -> String {
    URL(string: url)?.host() ?? url
}

#if !os(WASI)
public func urlSessionRemoteTransport(
    session: URLSession = .shared, timeout: TimeInterval = 300
) -> RemoteTransport {
    { request in
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var native = URLRequest(url: url, timeoutInterval: timeout)
        native.httpMethod = request.method
        native.httpBody = request.body
        for (name, value) in request.headers { native.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: native)
        return RemoteResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
#endif
