import Foundation
import Synchronization

@testable import EscribaOpenAI

struct FalloDeRed: Error {}

final class ServidorFalso: Sendable {
    private let recibidas = Mutex<[RemoteRequest]>([])
    private let pendientes: Mutex<[Result<RemoteResponse, FalloDeRed>]>

    init(_ respuestas: [Result<RemoteResponse, FalloDeRed>]) {
        pendientes = Mutex(respuestas)
    }

    convenience init(json: String...) {
        self.init(json.map { .success(RemoteResponse(status: 200, body: Data($0.utf8))) })
    }

    var peticiones: [RemoteRequest] { recibidas.withLock { $0 } }

    var transporte: RemoteTransport {
        { peticion in
            self.recibidas.withLock { $0.append(peticion) }
            let siguiente = self.pendientes.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let siguiente else { return RemoteResponse(status: 500, body: Data()) }
            return try siguiente.get()
        }
    }
}

func respuesta(_ status: Int, _ cuerpo: String) -> Result<RemoteResponse, FalloDeRed> {
    .success(RemoteResponse(status: status, body: Data(cuerpo.utf8)))
}

func errorDeAPI(_ mensaje: String) -> String {
    #"{"error":{"message":"\#(mensaje)","type":"invalid_request_error"}}"#
}

func chat(_ contenido: String) -> String {
    let escapado = String(data: try! JSONEncoder().encode(contenido), encoding: .utf8)!
    return #"{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":\#(escapado)}}]}"#
}

func json(_ datos: Data?) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: datos ?? Data())) as? [String: Any] ?? [:]
}

func texto(_ datos: Data?) -> String {
    String(decoding: datos ?? Data(), as: UTF8.self)
}
