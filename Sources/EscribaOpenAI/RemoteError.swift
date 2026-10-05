import Foundation

public enum RemoteAPIError: Error, Equatable, Sendable, CustomStringConvertible {
    case unauthorized(String)
    case notFound(String)
    case tooLarge
    case rateLimited(String)
    case rejected(status: Int, message: String)
    case server(status: Int, message: String)
    case transport(String)
    case malformed(String)

    public var message: String {
        switch self {
        case .unauthorized(let detail):
            "El servicio rechaza la clave\(suffix(detail))."
        case .notFound(let detail):
            "El servicio no encuentra el modelo o la URL no es la de su API\(suffix(detail))."
        case .tooLarge:
            "El audio es demasiado grande para este servicio."
        case .rateLimited(let detail):
            "El servicio está limitando las peticiones o la cuenta no tiene saldo\(suffix(detail))."
        case .rejected(let status, let detail):
            "El servicio rechazó la petición (\(status))\(suffix(detail))."
        case .server(let status, let detail):
            "El servicio falló (\(status))\(suffix(detail))."
        case .transport(let detail):
            "No se pudo hablar con el servicio: \(detail)."
        case .malformed(let detail):
            "Respuesta ilegible del servicio: \(detail)."
        }
    }

    public var description: String { message }

    public var blocksEveryRecording: Bool {
        switch self {
        case .unauthorized, .notFound, .rateLimited, .server, .transport: true
        case .tooLarge, .rejected, .malformed: false
        }
    }

    var isAboutResponseFormat: Bool {
        guard case .rejected(400, let detail) = self else { return false }
        let lowered = detail.lowercased()
        return ["response_format", "json_schema", "verbose_json", "timestamp_granularities"]
            .contains { lowered.contains($0) }
    }

    private func suffix(_ detail: String) -> String {
        detail.isEmpty ? "" : ": \(detail)"
    }
}

public func remoteError(status: Int, body: Data) -> RemoteAPIError {
    let detail = apiMessage(in: body)
    switch status {
    case 401, 403: return .unauthorized(detail)
    case 404: return .notFound(detail)
    case 413: return .tooLarge
    case 429: return .rateLimited(detail)
    case 500...: return .server(status: status, message: detail)
    default: return .rejected(status: status, message: detail)
    }
}

private struct ErrorEnvelope: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let error: Detail?
    let message: String?
}

private func apiMessage(in body: Data) -> String {
    if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
        let message = envelope.error?.message ?? envelope.message
    {
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
