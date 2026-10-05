import Foundation
import Synchronization
import Testing
import EscribaCore

@testable import EscribaNotion

private func cuerpo(_ plantilla: String, _ nota: Note = notaDe(), audio: String? = nil) -> [NotionBlock] {
    notionBody(plantilla, values: valoresDe(nota), audio: audio)
}

@Suite("Cuerpo de la pagina de Notion")
struct CuerpoTests {
    @Test("la plantilla de partida es la transcripcion, un parrafo por hablante con su nombre en negrita")
    func basica() {
        let bloques = cuerpo(NotionExport.standardBody)

        #expect(bloques.map(\.plainText) == ["Ruben: Hola.", "Aritz: Dime."])
        #expect(bloques[0].runs == [NotionRun(text: "Ruben: ", bold: true), NotionRun(text: "Hola.", bold: false)])
    }

    @Test("las lineas con # son encabezados de Notion con su nivel, hasta el tercero")
    func encabezados() {
        let bloques = cuerpo("# Uno\nuno\n## Dos\ndos\n### Tres\ntres\n#### Cuatro\ncuatro")

        #expect(bloques.map(\.kind) == [
            .heading(1), .paragraph, .heading(2), .paragraph, .heading(3), .paragraph, .heading(3), .paragraph,
        ])
        #expect(bloques[0].plainText == "Uno")
    }

    @Test("una linea con datos es un parrafo, y la **negrita** de Markdown se respeta")
    func parrafoConDatos() {
        let bloques = cuerpo("**Hablantes:** {{hablantes}} · {{duracion}}")

        #expect(bloques == [NotionBlock(runs: [
            NotionRun(text: "Hablantes:", bold: true), NotionRun(text: " Ruben, Aritz · 03:07", bold: false),
        ])])
    }

    @Test("las lineas con - son viñetas")
    func vinetas() {
        let bloques = cuerpo("- uno\n- {{clave}}")

        #expect(bloques.map(\.kind) == [.bullet, .bullet])
        #expect(bloques.map(\.plainText) == ["uno", "llamada"])
    }

    @Test("el dato Audio pone el fichero subido; sin subida no deja nada")
    func audio() {
        #expect(cuerpo("{{audio}}", audio: "up-1").map(\.kind) == [.audio(uploadId: "up-1")])
        #expect(cuerpo("Antes\n{{audio}}\nDespues").map(\.plainText) == ["Antes", "Despues"])
    }

    @Test("las lineas en blanco separan; no crean parrafos vacios")
    func blancos() {
        #expect(cuerpo("uno\n\n\ndos").map(\.plainText) == ["uno", "dos"])
    }

    @Test("una linea cuyos datos salen vacios no se escribe, y un encabezado sin nada debajo tampoco")
    func huecos() {
        let plana = notaDe(Transcript(text: "Solo texto"))

        let bloques = cuerpo("# Resumen\n{{resumen}}\n{{etiquetas}}\n# Texto\n{{transcripcion}}", plana)

        #expect(bloques.map(\.kind) == [.heading(1), .paragraph])
        #expect(bloques.map(\.plainText) == ["Texto", "Solo texto"])
    }

    @Test("el resumen en su linea da un parrafo por cada linea del resumen")
    func resumen() {
        let bloques = cuerpo("{{resumen}}", notaDe(digest: resumenDeCharla))

        #expect(bloques.map(\.plainText) == ["Se revisa el restore.", "Y se habla de MinIO."])
    }

    @Test("la transcripcion sale en el estilo de su dato")
    func estilos() {
        #expect(cuerpo("{{transcripcion-tiempos}}").map(\.plainText) == ["[00:00] Ruben: Hola.", "[00:12] Aritz: Dime."])
        #expect(cuerpo("{{transcripcion-texto}}").map(\.plainText) == ["Hola.", "Dime."])
    }

    @Test("un parrafo larguisimo se parte sin pasar del limite de Notion")
    func largo() {
        let largo = String(repeating: "palabra ", count: 600)

        let bloques = cuerpo(largo)

        #expect(bloques.count > 1)
        #expect(bloques.allSatisfy { $0.plainText.count <= notionTextLimit })
    }

    @Test("un enlace a otro documento no tiene sentido en Notion y no deja rastro")
    func enlace() {
        #expect(cuerpo("Ver {{enlace:otro}}\n{{enlace:otro}}").map(\.plainText) == ["Ver "])
    }

    @Test("los bloques viajan como parrafo, encabezado, viñeta o audio")
    func json() {
        let cuerpo = appendChildrenBody([
            NotionBlock(kind: .audio(uploadId: "up-9"), runs: []),
            NotionBlock(kind: .heading(1), runs: [NotionRun(text: "H", bold: false)]),
            NotionBlock(kind: .heading(3), runs: [NotionRun(text: "H", bold: false)]),
            NotionBlock(kind: .bullet, runs: [NotionRun(text: "v", bold: false)]),
        ])

        #expect(cuerpo["children"]?[0]?["audio"]?["file_upload"]?["id"] == .string("up-9"))
        #expect(cuerpo["children"]?[1]?["type"] == .string("heading_1"))
        #expect(cuerpo["children"]?[2]?["type"] == .string("heading_3"))
        #expect(cuerpo["children"]?[3]?["bulleted_list_item"]?["rich_text"]?[0]?["text"]?["content"] == .string("v"))
    }

    @Test("publicar con el dato Audio sube el fichero antes de crear la pagina")
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

        _ = try await publish(notaDe(), as: exportDe(cuerpo: "{{audio}}\n{{transcripcion}}"), using: client)

        #expect(registro.withLock { $0 } == ["subir:llamada.m4a", "crear:audio"])
    }

    @Test("sin el dato Audio no se sube nada")
    func sinAudio() {
        #expect(!exportDe(cuerpo: "{{transcripcion}}").needsAudio)
        #expect(exportDe(cuerpo: "Escucha: {{audio}}").needsAudio)
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
