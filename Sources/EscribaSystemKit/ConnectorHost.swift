import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import EscribaCore
import EscribaEngine

public struct ConnectorGrant: Sendable {
    public var httpOrigin: String?
    public var folder: URL?
    public var audio: URL?
    public var allowLoopbackHTTP: Bool
    public var allowedHeaders: Set<String>
    public var secret: @Sendable () throws -> String?
    public var checkpoint: @Sendable (String) async throws -> Void
    public init(httpOrigin: String? = nil, folder: URL? = nil, audio: URL? = nil,
                allowLoopbackHTTP: Bool = false,
                allowedHeaders: Set<String> = ["content-type", "accept"],
                secret: @escaping @Sendable () throws -> String? = { nil },
                checkpoint: @escaping @Sendable (String) async throws -> Void = { _ in }) {
        self.httpOrigin = httpOrigin; self.folder = folder.map(connectorCanonicalFolder); self.audio = audio
        self.allowLoopbackHTTP = allowLoopbackHTTP; self.allowedHeaders = allowedHeaders
        self.secret = secret; self.checkpoint = checkpoint
    }
}

public enum ConnectorHostError: Error, LocalizedError {
    case denied, invalidRequest, limit, transport, conflict
    public var errorDescription: String? {
        switch self {
        case .denied: "El conector no tiene permiso para esta operación."
        case .invalidRequest: "La solicitud del conector no es válida."
        case .limit: "El conector supera el límite de datos permitido."
        case .transport: "No se pudo completar la petición del conector."
        case .conflict: "Los archivos cambiaron durante la publicación."
        }
    }
}

public func makeConnectorBridge(grant: ConnectorGrant) -> ConnectorBridge {
    let host = ConnectorHost(grant: grant)
    return ConnectorBridge { try await host.call($0) }
}

private actor ConnectorHost {
    let grant: ConnectorGrant
    let maxBytes = 16 * 1024 * 1024
    init(grant: ConnectorGrant) { self.grant = grant }

    func call(_ input: String) async throws -> String {
        guard input.utf8.count <= maxBytes,
              let object = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
              let op = object["op"] as? String else { throw ConnectorHostError.invalidRequest }
        switch op {
        case "files.snapshot": return try encode(snapshot())
        case "files.apply": return try apply(object)
        case "audio":
            guard let audio = grant.audio else { throw ConnectorHostError.denied }
            let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return try encode(["id": "audio", "filename": audio.lastPathComponent,
                               "contentType": audioType(audio), "size": size])
        case "checkpoint":
            guard let receipt = object["receipt"] else { throw ConnectorHostError.invalidRequest }
            try await grant.checkpoint(encode(receipt))
            return "null"
        case "http": return try await http(object)
        default: throw ConnectorHostError.denied
        }
    }

    func encode(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }

    func root() throws -> URL {
        guard let root = grant.folder else { throw ConnectorHostError.denied }
        guard connectorCanonicalFolder(root).path == root.path else { throw ConnectorHostError.denied }
        return root
    }

    func target(_ path: String) throws -> URL {
        guard validConnectorRelativePath(path) else { throw ConnectorHostError.denied }
        var target = try root()
        for component in path.split(separator: "/") {
            target.append(path: String(component))
            if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw ConnectorHostError.denied
            }
        }
        return target
    }

    func snapshot() throws -> [String: String] {
        let root = try root()
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else {
            throw ConnectorHostError.denied
        }
        var files: [String: String] = [:]
        var total = 0
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            guard size <= maxBytes, total + size <= maxBytes, files.count < 10_000 else { throw ConnectorHostError.limit }
            let relative = String(connectorCanonicalFolder(url).path.dropFirst(root.path.count + 1))
            guard let content = try ConnectorFiles(root: root).read(relative, limit: maxBytes - total) else { continue }
            total += content.utf8.count
            files[relative] = content
        }
        return files
    }

    func apply(_ object: [String: Any]) throws -> String {
        guard let changes = object["changes"] as? [[String: Any]], changes.count <= 10_000 else {
            throw ConnectorHostError.invalidRequest
        }
        var writes: [(String, String?)] = []
        var seen: Set<String> = []
        var total = 0
        for change in changes {
            guard let path = change["path"] as? String, seen.insert(path).inserted,
                  change["contents"] is String || change["contents"] is NSNull else { throw ConnectorHostError.invalidRequest }
            let url = try target(path)
            if FileManager.default.fileExists(atPath: url.path) {
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw ConnectorHostError.denied }
            }
            if seen.contains(where: { $0 != path && ($0.hasPrefix(path + "/") || path.hasPrefix($0 + "/")) }) {
                throw ConnectorHostError.denied
            }
            if let expected = change["expectedContents"] {
                let current = FileManager.default.fileExists(atPath: url.path) ? try ConnectorFiles(root: root()).read(path, limit: maxBytes) : nil
                guard (expected is NSNull && current == nil) || (expected as? String == current && current != nil) else {
                    throw ConnectorHostError.conflict
                }
            }
            let content = change["contents"] as? String
            total += content?.utf8.count ?? 0
            guard total <= maxBytes else { throw ConnectorHostError.limit }
            writes.append((path, content))
        }
        let files = ConnectorFiles(root: try root())
        for (path, content) in writes {
            let url = try target(path)
            if content == nil && !FileManager.default.fileExists(atPath: url.path) { continue }
            try files.write(path, content: content)
        }
        return "null"
    }

    func audioType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "ogg": "audio/ogg"
        default: "audio/mp4"
        }
    }

    func http(_ object: [String: Any]) async throws -> String {
        guard let raw = object["url"] as? String, let url = URL(string: raw),
              let origin = grant.httpOrigin.flatMap(URL.init(string:)),
              permitted(url, origin: origin) else { throw ConnectorHostError.denied }
        var request = URLRequest(url: url)
        let method = (object["method"] as? String ?? "GET").uppercased()
        guard ["GET", "POST", "PATCH", "PUT", "DELETE", "HEAD"].contains(method) else { throw ConnectorHostError.denied }
        request.httpMethod = method
        let forbidden: Set<String> = ["authorization", "host", "cookie", "proxy-authorization", "proxy-connection", "connection", "content-length", "transfer-encoding"]
        for (name, value) in object["headers"] as? [String: String] ?? [:] {
            let lower = name.lowercased()
            guard !forbidden.contains(lower), grant.allowedHeaders.contains(lower),
                  !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
                throw ConnectorHostError.denied
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = object["body"] as? String { request.httpBody = Data(body.utf8) }
        if let parts = object["multipart"] as? [[String: Any]] {
            let boundary = UUID().uuidString
            request.httpBody = try multipart(parts, boundary: boundary)
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        guard (request.httpBody?.count ?? 0) <= 128 * 1024 * 1024 else { throw ConnectorHostError.limit }
        let secret = try grant.secret()
        if let secret {
            guard !secret.contains("\r"), !secret.contains("\n") else { throw ConnectorHostError.denied }
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await ConnectorHTTP(limit: maxBytes).perform(request)
            var headers: [String: String] = [:]
            for name in ["content-type", "retry-after", "request-id"] {
                headers[name] = response.value(forHTTPHeaderField: name).map { redacted($0, secret: secret) }
            }
            return try encode(["status": response.statusCode, "headers": headers,
                               "body": redacted(String(decoding: data, as: UTF8.self), secret: secret)])
        } catch is CancellationError { throw CancellationError() }
        catch let error as ConnectorHostError { throw error }
        catch { throw ConnectorHostError.transport }
    }

    func redacted(_ text: String, secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[redacted]")
    }

    func permitted(_ url: URL, origin: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              origin.user == nil, origin.password == nil,
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              scheme == origin.scheme?.lowercased(), host == origin.host?.lowercased(),
              (url.port ?? (scheme == "https" ? 443 : 80)) == (origin.port ?? (scheme == "https" ? 443 : 80)) else { return false }
        return scheme == "https" || (scheme == "http" && grant.allowLoopbackHTTP && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
    }

    func multipart(_ parts: [[String: Any]], boundary: String) throws -> Data {
        var data = Data()
        for part in parts {
            guard let name = part["name"] as? String,
                  !name.contains("\r"), !name.contains("\n"), !name.contains("\"") else { throw ConnectorHostError.invalidRequest }
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"".utf8))
            if part["attachment"] as? String == "audio" {
                guard let url = grant.audio else { throw ConnectorHostError.denied }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 * 1024 else { throw ConnectorHostError.limit }
                data.append(Data("; filename=\"audio.\(url.pathExtension.filter { $0.isLetter || $0.isNumber })\"\r\nContent-Type: \(audioType(url))\r\n\r\n".utf8))
                let audio = try Data(contentsOf: url)
                let offset = part["offset"] as? Int ?? 0
                let length = part["length"] as? Int ?? audio.count
                guard offset >= 0, length >= 0, offset <= audio.count, length <= audio.count - offset else { throw ConnectorHostError.denied }
                data.append(audio.subdata(in: offset..<(offset + length)))
            } else if let value = part["value"] as? String {
                data.append(Data("\r\n\r\n\(value)".utf8))
            } else { throw ConnectorHostError.invalidRequest }
            guard data.count <= 128 * 1024 * 1024 else { throw ConnectorHostError.limit }
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}
