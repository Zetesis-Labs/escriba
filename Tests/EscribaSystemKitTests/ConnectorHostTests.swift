import Foundation
import Testing
import EscribaCore
import EscribaEngine
import EscribaSystemKit

@Test func conectorRechazaEscapeAntesDeEscribir() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = makeConnectorBridge(grant: ConnectorGrant(folder: root))
    await #expect(throws: (any Error).self) {
        try await bridge.call(#"{"op":"files.apply","changes":[{"path":"valid.txt","contents":"hola"},{"path":"../escape","contents":"no"}]}"#)
    }
    let snapshot = try await bridge.call(#"{"op":"files.snapshot"}"#)
    #expect(snapshot == #"{}"#)
}

@Test func conectorConservaArchivosYRechazaEnlacesSimbolicos() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = makeConnectorBridge(grant: ConnectorGrant(folder: root))
    _ = try await bridge.call(#"{"op":"files.apply","changes":[{"path":"a/text.txt","contents":"hola"}]}"#)
    #expect(try await bridge.call(#"{"op":"files.snapshot"}"#) == #"{"a\/text.txt":"hola"}"#)
    try FileManager.default.createSymbolicLink(at: root.appending(path: "fuera"), withDestinationURL: root.deletingLastPathComponent())
    await #expect(throws: (any Error).self) {
        try await bridge.call(#"{"op":"files.apply","changes":[{"path":"fuera/escape.txt","contents":"no"}]}"#)
    }
}

@Test func conectorRechazaOrigenYCabecerasSinLeerSecreto() async throws {
    let bridge = makeConnectorBridge(grant: ConnectorGrant(httpOrigin: "https://example.com", secret: {
        Issue.record("No debe leer credenciales para una petición denegada")
        return "secret"
    }))
    for request in [
        #"{"op":"http","url":"https://example.com.evil.test/"}"#,
        #"{"op":"http","url":"https://example.com:444/"}"#,
        #"{"op":"http","url":"https://user@example.com/"}"#,
        #"{"op":"http","url":"http://example.com/"}"#,
        #"{"op":"http","url":"https://example.com/","headers":{"Authorization":"evil"}}"#,
        #"{"op":"http","url":"https://example.com/","headers":{"Host":"evil"}}"#
    ] {
        await #expect(throws: (any Error).self) { try await bridge.call(request) }
    }
}

@Test func conectorDetectaEdicionConcurrenteAntesDeAplicar() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bridge = makeConnectorBridge(grant: ConnectorGrant(folder: root))
    _ = try await bridge.call(#"{"op":"files.apply","changes":[{"path":"nota","contents":"original"}]}"#)
    await #expect(throws: (any Error).self) {
        try await bridge.call(#"{"op":"files.apply","changes":[{"path":"nuevo","contents":"nuevo"},{"path":"nota","contents":"cambio","expectedContents":"antiguo"}]}"#)
    }
    #expect(try await bridge.call(#"{"op":"files.snapshot"}"#) == #"{"nota":"original"}"#)
}

@Test func conectorRecuperaPaqueteYReciboTrasReabrirArchivo() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = ConnectorArchive(directory: root)
    let program = ConnectorProgram(source: "source", fingerprint: "sha")
    let record = ConnectorPublicationRecord(programFingerprint: "sha", configJSON: "{}", receiptJSON: "{\"locator\":\"abc\"}", state: "pending")
    try await archive.retain(program)
    try await archive.save(recording: "../../recording", destination: "dest", record: record)
    let reopened = ConnectorArchive(directory: root)
    #expect(try await reopened.program(fingerprint: "sha") == program)
    #expect(try await reopened.load(recording: "../../recording", destination: "dest") == record)
    #expect(try await reopened.load(recording: "..", destination: "../recordingdest") == nil)
    await #expect(throws: (any Error).self) {
        try await reopened.retain(ConnectorProgram(source: "modified", fingerprint: "sha"))
    }
}

#if canImport(Network)
import Network

private final class ConnectorLocalServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "connector.http.test")
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> String {
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256_000) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let response: String
                if request.contains("/redirect") {
                    response = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                } else if request.contains("/huge") {
                    response = "HTTP/1.1 200 OK\r\nContent-Length: 20000000\r\nConnection: close\r\n\r\n"
                } else {
                    let body = request.contains("Bearer test-secret") ? "authorized test-secret" : "denied"
                    response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
}

@Test func conectorHTTPInyectaSecretoLoOcultaYNoSigueRedirect() async throws {
    let server = try ConnectorLocalServer()
    let origin = try await server.start()
    defer { server.listener.cancel() }
    let bridge = makeConnectorBridge(grant: ConnectorGrant(httpOrigin: origin, allowLoopbackHTTP: true, secret: { "test-secret" }))
    let result = try await bridge.call("{\"op\":\"http\",\"url\":\"\(origin)/ok\"}")
    #expect(result.contains("authorized [redacted]"))
    #expect(!result.contains("test-secret"))
    let redirect = try await bridge.call("{\"op\":\"http\",\"url\":\"\(origin)/redirect\"}")
    #expect(redirect.contains("302"))
    await #expect(throws: (any Error).self) {
        try await bridge.call("{\"op\":\"http\",\"url\":\"\(origin)/huge\"}")
    }
}
#endif
