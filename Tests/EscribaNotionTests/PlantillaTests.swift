import Foundation
import Synchronization
import Testing
import EscribaCore

@testable import EscribaNotion

private let madrid = TimeZone(identifier: "Europe/Madrid")!

private func pagina(_ transcript: Transcript) -> NotionPage {
    notionPage(
        for: Recording(
            url: URL(fileURLWithPath: "/Notas/llamada.m4a"),
            startedAt: Date(timeIntervalSince1970: 1_758_013_200), key: "llamada"),
        transcript: transcript)
}

private let diarizada = Transcript(segments: [
    TranscriptSegment(start: 0, end: 12, speaker: "Ruben", text: "Hola."),
    TranscriptSegment(start: 12, end: 187, speaker: "Aritz", text: "Dime."),
])

@Suite("Plantilla del cuerpo")
struct PlantillaTests {
    @Test("la plantilla basica es solo la transcripcion por hablantes")
    func basica() {
        let bloques = render(.standard, for: pagina(diarizada), transcript: diarizada, audio: nil)

        #expect(bloques.map(\.plainText) == ["Ruben: Hola.", "Aritz: Dime."])
    }

    @Test("los bloques salen en el orden de la plantilla, cada uno con su forma")
    func orden() {
        let plantilla = BodyTemplate([
            .heading("Datos"), .field(.date), .field(.speakers), .field(.duration),
            .text("Notas:\nrevisar"), .audio, .transcript(.plain),
        ])
        let bloques = render(plantilla, for: pagina(diarizada), transcript: diarizada, audio: "up-1", timeZone: madrid)

        #expect(bloques[0].kind == .heading)
        #expect(bloques[0].plainText == "Datos")
        #expect(bloques[1].plainText.hasPrefix("Fecha de la grabación: "))
        #expect(bloques[1].plainText.contains("2025"))
        #expect(bloques[1].runs.first?.bold == true)
        #expect(bloques[2].plainText == "Hablantes: Ruben, Aritz")
        #expect(bloques[3].plainText == "Duración (segundos): 03:07")
        #expect(bloques[4].plainText == "Notas:")
        #expect(bloques[5].plainText == "revisar")
        #expect(bloques[6].kind == .audio(uploadId: "up-1"))
        #expect(bloques[7...].map(\.plainText) == ["Hola.", "Dime."])
    }

    @Test("un encabezado sin texto no se manda a Notion")
    func encabezadoSinTexto() {
        let bloques = render(BodyTemplate([.heading(""), .transcript(.plain)]), for: pagina(diarizada), transcript: diarizada, audio: nil)

        #expect(bloques.map(\.plainText) == ["Hola.", "Dime."])
    }

    @Test("sin audio subido el bloque de audio no se pone, y un dato vacio tampoco")
    func huecos() {
        let plana = Transcript(text: "Solo texto")
        let bloques = render(
            BodyTemplate([.audio, .field(.speakers), .text(""), .transcript(.speakers)]),
            for: pagina(plana), transcript: plana, audio: nil)

        #expect(bloques.map(\.plainText) == ["Solo texto"])
    }

    @Test("un bloque de audio viaja como fichero subido")
    func audioJSON() {
        let cuerpo = appendChildrenBody([NotionBlock(kind: .audio(uploadId: "up-9"), runs: [])])

        #expect(cuerpo["children"]?[0]?["type"] == .string("audio"))
        #expect(cuerpo["children"]?[0]?["audio"]?["file_upload"]?["id"] == .string("up-9"))
        #expect(appendChildrenBody([NotionBlock(kind: .heading, runs: [])])["children"]?[0]?["type"] == .string("heading_2"))
    }

    @Test("escribir / propone bloques y admite tildes y mayusculas")
    func comandos() {
        #expect(slashCommands(matching: "/").count == slashCommands.count)
        #expect(slashCommands(matching: "/trans").map(\.command) == [
            "/transcripcion", "/transcripcion-tiempos", "/transcripcion-texto",
        ])
        #expect(templateBlock(forCommand: "/Transcripción") == .transcript(.speakers))
        #expect(templateBlock(forCommand: "/duración ") == .field(.duration))
        #expect(templateBlock(forCommand: "/nada") == nil)
        #expect(slashCommands(matching: "hola").isEmpty)
    }

    @Test("la plantilla se guarda con la exportacion y una vieja sin plantilla usa la basica")
    func persistencia() throws {
        let fuente = NotionDataSource(
            id: "ds", databaseTitle: "D", title: "D",
            properties: [NotionProperty(name: "Nombre", type: "title")])
        let export = NotionExport(
            source: fuente, mapping: suggestedMapping(for: fuente),
            template: BodyTemplate([.audio, .transcript(.timestamps)]))
        let vuelta = try JSONDecoder().decode(NotionExport.self, from: JSONEncoder().encode(export))

        #expect(vuelta == export)
        #expect(NotionExport(source: fuente, mapping: NotionMapping(), style: .plain).template == BodyTemplate([.transcript(.plain)]))
    }

    @Test("publicar con /audio sube el fichero antes de crear la pagina")
    func publicaConAudio() async throws {
        let registro = Mutex<[String]>([])
        let client = NotionClient(
            dataSources: { [] },
            createPage: { body in
                registro.withLock { $0.append("crear:\(body["children"]?[0]?["type"]?.text ?? "?")") }
                return NotionPageRef(id: "pg", url: nil)
            },
            updatePage: { _, _ in }, appendBlocks: { _, _ in }, childBlocks: { _ in [] },
            deleteBlock: { _ in }, findPage: { _, _ in nil },
            uploadFile: { url in
                registro.withLock { $0.append("subir:\(url.lastPathComponent)") }
                return "up-1"
            })
        let fuente = NotionDataSource(
            id: "ds", databaseTitle: "D", title: "D",
            properties: [NotionProperty(name: "Nombre", type: "title")])
        let export = NotionExport(
            source: fuente, mapping: suggestedMapping(for: fuente),
            template: BodyTemplate([.audio, .transcript(.speakers)]))
        let grabacion = Recording(url: URL(fileURLWithPath: "/Notas/a.m4a"), startedAt: .now, key: "a")

        _ = try await publish(
            Note(recording: grabacion, transcript: diarizada), as: export, using: client)

        #expect(registro.withLock { $0 } == ["subir:a.m4a", "crear:audio"])
    }

    @Test("al refrescar, las columnas nuevas se sugieren sin pisar lo ya elegido")
    func rellenoTrasRefrescar() {
        let antes = NotionDataSource(
            id: "ds", databaseTitle: "D", title: "D",
            properties: [
                NotionProperty(name: "Nombre", type: "title"),
                NotionProperty(name: "Cuando", type: "date"),
            ])
        var mapeo = suggestedMapping(for: antes)
        mapeo[.date] = "Cuando"
        let ahora = NotionDataSource(
            id: "ds", databaseTitle: "D", title: "D",
            properties: antes.properties + [
                NotionProperty(name: "Fecha", type: "date"),
                NotionProperty(name: "Hablantes", type: "multi_select"),
                NotionProperty(name: "Clave", type: "rich_text"),
            ])

        let relleno = mapeo.pruned(to: ahora).fillingGaps(from: ahora)

        #expect(relleno[.date] == "Cuando")
        #expect(relleno[.speakers] == "Hablantes")
        #expect(relleno[.key] == "Clave")
    }
}

@Suite("Subida de ficheros a Notion")
struct SubidaTests {
    private final class Grabador: Sendable {
        let peticiones = Mutex<[(String, String, Data)]>([])

        var transport: NotionTransport {
            { request in
                let path = request.path
                let type = request.headers["Content-Type"] ?? ""
                self.peticiones.withLock { $0.append((path, type, request.body ?? Data())) }
                let body = path.hasSuffix("file_uploads") ? #"{"object":"file_upload","id":"up-1"}"# : "{}"
                return NotionHTTPResponse(status: 200, body: Data(body.utf8))
            }
        }
    }

    private func fichero(bytes: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-\(UUID().uuidString).m4a")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    @Test("un fichero pequeño va en una sola parte como multipart/form-data")
    func unaParte() async throws {
        let grabador = Grabador()
        let client = makeNotionClient(token: "t", transport: grabador.transport, singlePartLimit: 100, partSize: 40)

        let id = try await client.uploadFile(try fichero(bytes: 50))

        let peticiones = grabador.peticiones.withLock { $0 }
        #expect(id == "up-1")
        #expect(peticiones.map(\.0) == ["/v1/file_uploads", "/v1/file_uploads/up-1/send"])
        #expect(String(decoding: peticiones[0].2, as: UTF8.self).contains("\"single_part\""))
        #expect(String(decoding: peticiones[0].2, as: UTF8.self).contains("\"audio/mp4\""))
        #expect(peticiones[1].1.hasPrefix("multipart/form-data; boundary="))
        let cuerpo = String(decoding: peticiones[1].2, as: UTF8.self)
        #expect(cuerpo.contains("name=\"file\"; filename=\""))
        #expect(!cuerpo.contains("part_number"))
    }

    @Test("un fichero grande va por partes numeradas y se cierra al final")
    func variasPartes() async throws {
        let grabador = Grabador()
        let client = makeNotionClient(token: "t", transport: grabador.transport, singlePartLimit: 100, partSize: 40)

        _ = try await client.uploadFile(try fichero(bytes: 101))

        let peticiones = grabador.peticiones.withLock { $0 }
        #expect(peticiones.map(\.0) == [
            "/v1/file_uploads", "/v1/file_uploads/up-1/send", "/v1/file_uploads/up-1/send",
            "/v1/file_uploads/up-1/send", "/v1/file_uploads/up-1/complete",
        ])
        #expect(String(decoding: peticiones[0].2, as: UTF8.self).contains("\"number_of_parts\":3"))
        #expect(String(decoding: peticiones[1].2, as: UTF8.self).contains("name=\"part_number\"\r\n\r\n1\r\n"))
        #expect(String(decoding: peticiones[3].2, as: UTF8.self).contains("name=\"part_number\"\r\n\r\n3\r\n"))
    }

    @Test("el troceo respeta el limite de una parte y el tamaño de parte")
    func troceo() {
        #expect(uploadParts(size: 10, singlePartLimit: 20, partSize: 5) == [0..<10])
        #expect(uploadParts(size: 21, singlePartLimit: 20, partSize: 10) == [0..<10, 10..<20, 20..<21])
        #expect(uploadParts(size: 0, singlePartLimit: 20, partSize: 10) == [0..<0])
    }
}
