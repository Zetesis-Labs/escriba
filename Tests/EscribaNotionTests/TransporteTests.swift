import Foundation
import Synchronization
import Testing

@testable import EscribaNotion

private final class Falso: Sendable {
    private let visto = Mutex<[NotionHTTPRequest]>([])
    private let responder: @Sendable (NotionHTTPRequest) -> (Int, String)

    init(_ responder: @escaping @Sendable (NotionHTTPRequest) -> (Int, String)) {
        self.responder = responder
    }

    var peticiones: [NotionHTTPRequest] { visto.withLock { $0 } }

    var transport: NotionTransport {
        { request in
            self.visto.withLock { $0.append(request) }
            let (status, body) = self.responder(request)
            return NotionHTTPResponse(status: status, body: Data(body.utf8))
        }
    }
}

@Suite("Transporte con la API de Notion")
struct TransporteTests {
    @Test("cada peticion lleva el token y la version de la API")
    func cabeceras() async throws {
        let falso = Falso { _ in (200, #"{"object":"page","id":"pg-1"}"#) }
        _ = try await makeNotionClient(token: "secreto", transport: falso.transport)
            .createPage(.object([:]))

        let peticion = try #require(falso.peticiones.first)
        #expect(peticion.headers["Authorization"] == "Bearer secreto")
        #expect(peticion.headers["Notion-Version"] == notionAPIVersion)
        #expect(peticion.headers["Content-Type"] == "application/json")
        #expect(peticion.url == "https://api.notion.com/v1/pages")
        #expect(peticion.method == "POST")
    }

    @Test("un token invalido se cuenta como tal, no como fallo generico")
    func tokenInvalido() async {
        let falso = Falso { _ in (401, #"{"object":"error","message":"API token is invalid."}"#) }
        let client = makeNotionClient(token: "malo", transport: falso.transport)

        await #expect(throws: NotionError.unauthorized) { try await client.dataSources() }
    }

    @Test("una base no compartida con la integracion se explica sola")
    func sinPermiso() async throws {
        let falso = Falso { _ in (403, #"{"object":"error","message":"insufficient permissions"}"#) }
        let client = makeNotionClient(token: "t", transport: falso.transport)

        let error = await #expect(throws: NotionError.self) {
            try await client.createPage(.object([:]))
        }
        #expect(error == .forbidden("insufficient permissions"))
        #expect(error?.message.contains("Comparte la base con la integración") == true)
    }

    @Test("la busqueda de bases recorre todas las paginas de resultados")
    func paginacion() async throws {
        let falso = Falso { request in
            let cuerpo = String(decoding: request.body ?? Data(), as: UTF8.self)
            return cuerpo.contains("start_cursor")
                ? (200, #"{"results":[{"object":"data_source","id":"ds-2","name":"B","properties":{}}],"has_more":false}"#)
                : (200, #"{"results":[{"object":"data_source","id":"ds-1","name":"A","properties":{}}],"has_more":true,"next_cursor":"c-2"}"#)
        }
        let bases = try await makeNotionClient(token: "t", transport: falso.transport).dataSources()

        #expect(bases.map(\.id) == ["ds-1", "ds-2"])
        #expect(falso.peticiones.count == 2)
    }

    @Test("los hijos de una pagina se leen enteros aunque pasen de cien")
    func hijosPaginados() async throws {
        let falso = Falso { request in
            request.query?.contains("start_cursor") == true
                ? (200, #"{"results":[{"id":"b-101"}],"has_more":false}"#)
                : (200, #"{"results":[{"id":"b-1"},{"id":"b-2"}],"has_more":true,"next_cursor":"c-2"}"#)
        }
        let hijos = try await makeNotionClient(token: "t", transport: falso.transport)
            .childBlocks("pg-1")

        #expect(hijos == ["b-1", "b-2", "b-101"])
        #expect(falso.peticiones.count == 2)
    }

    @Test("si Notion pide esperar, se espera lo que diga y se reintenta")
    func reintentoTrasLimite() async throws {
        let intentos = Mutex(0)
        let pausas = Mutex<[Duration]>([])
        let transporte: NotionTransport = { _ in
            let n = intentos.withLock { $0 += 1; return $0 }
            let status = n < 3 ? 429 : 200
            return NotionHTTPResponse(
                status: status, headers: status == 429 ? ["retry-after": "2"] : [:],
                body: Data(#"{"object":"page","id":"pg-1"}"#.utf8))
        }
        let client = makeNotionClient(
            token: "t", transport: transporte, pause: { d in pausas.withLock { $0.append(d) } })

        let page = try await client.createPage(.object([:]))

        #expect(page.id == "pg-1")
        #expect(intentos.withLock { $0 } == 3)
        #expect(pausas.withLock { $0 } == [.seconds(2), .seconds(2)])
    }

    @Test("tras cinco limites seguidos se rinde con el error de limite")
    func seRindeTrasCinco() async {
        let pausas = Mutex(0)
        let transporte: NotionTransport = { _ in NotionHTTPResponse(status: 429, body: Data("{}".utf8)) }
        let client = makeNotionClient(
            token: "t", transport: transporte, pause: { _ in pausas.withLock { $0 += 1 } })

        await #expect(throws: NotionError.rateLimited) { try await client.createPage(.object([:])) }
        #expect(pausas.withLock { $0 } == notionRetryLimit - 1)
    }

    @Test("un corte de red en una peticion repetible se reintenta con espera creciente")
    func redCaidaRepetible() async throws {
        let intentos = Mutex(0)
        let pausas = Mutex<[Duration]>([])
        let transporte: NotionTransport = { _ in
            let n = intentos.withLock { $0 += 1; return $0 }
            guard n >= 3 else { throw URLError(.networkConnectionLost) }
            return NotionHTTPResponse(status: 200, body: Data("{}".utf8))
        }
        let client = makeNotionClient(
            token: "t", transport: transporte, pause: { d in pausas.withLock { $0.append(d) } })

        try await client.deleteBlock("b-1")

        #expect(intentos.withLock { $0 } == 3)
        #expect(pausas.withLock { $0 } == [.seconds(1), .seconds(2)])
    }

    @Test("crear una pagina nunca se repite a ciegas: un corte de red se reporta")
    func redCaidaAlCrear() async {
        let intentos = Mutex(0)
        let transporte: NotionTransport = { _ in
            intentos.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let client = makeNotionClient(token: "t", transport: transporte, pause: { _ in })

        let error = await #expect(throws: NotionError.self) { try await client.createPage(.object([:])) }
        #expect(error?.message.hasPrefix("No se pudo hablar con Notion") == true)
        #expect(intentos.withLock { $0 } == 1)
    }

    @Test("que se puede repetir y que no")
    func repetibles() {
        #expect(isReplayable(.get, "blocks/x/children"))
        #expect(isReplayable(.delete, "blocks/x"))
        #expect(isReplayable(.patch, "pages/x"))
        #expect(isReplayable(.post, "search"))
        #expect(isReplayable(.post, "data_sources/x/query"))
        #expect(isReplayable(.post, "file_uploads/x/send"))
        #expect(!isReplayable(.post, "pages"))
        #expect(!isReplayable(.post, "file_uploads"))
    }
}
