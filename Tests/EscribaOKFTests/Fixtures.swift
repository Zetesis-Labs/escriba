import Foundation
import EscribaCore
import EscribaOKF

let madrid = TimeZone(identifier: "Europe/Madrid")!
let ahora = Date(timeIntervalSince1970: 1_791_219_600)
let productor = "escriba/1.0"

let grabacion = Recording(
    url: URL(fileURLWithPath: "/Notas/llamada.m4a"),
    startedAt: Date(timeIntervalSince1970: 1_758_013_200), key: "llamada")

let diarizada = Transcript(segments: [
    TranscriptSegment(start: 0, end: 12, speaker: "Ruben", text: "Hola."),
    TranscriptSegment(start: 12, end: 187, speaker: "Aritz", text: "Dime."),
])

let resumen = Digest(
    title: "Backups de cortes",
    summary: "Se revisa el restore. Luego se habla de MinIO.",
    tags: ["backups", "talos linux"])

let nota = Note(recording: grabacion, transcript: diarizada, digest: resumen)

let estandar = OKFExport.standardDocuments(noteID: "nota", transcriptID: "transcripcion")

func exportacion(_ documentos: [OKFDocument] = estandar) -> OKFExport {
    OKFExport(folder: "/bundle", documents: documentos)
}

func documento(
    _ nombre: String = "Doc", id: String = "doc", ruta: String = "docs/{{dia}}-{{titulo}}.md",
    propiedades: [(String, String)] = [("type", "Nota de voz")], cuerpo: String = ""
) -> OKFDocument {
    OKFDocument(
        id: id, name: nombre, path: ruta,
        properties: propiedades.enumerated().map { OKFProperty(id: "p\($0.offset)", key: $0.element.0, value: $0.element.1) },
        body: cuerpo)
}

func publicar(
    _ nota: Note = nota, como export: OKFExport = exportacion(), en ficheros: [String: String] = [:],
    cuando: Date = ahora
) -> OKFPublication {
    okfPublication(
        nota, as: export, in: bundleState(from: ficheros), producer: productor, now: cuando, timeZone: madrid)
}

func aplicar(_ cambios: [FileChange], a ficheros: [String: String]) -> [String: String] {
    var resultado = ficheros
    for cambio in cambios {
        switch cambio {
        case .write(let path, let contents): resultado[path] = contents
        case .remove(let path): resultado[path] = nil
        }
    }
    return resultado
}

func escritos(_ cambios: [FileChange]) -> [String: String] {
    aplicar(cambios, a: [:])
}

func borrados(_ cambios: [FileChange]) -> [String] {
    cambios.compactMap {
        if case .remove(let path) = $0 { return path }
        return nil
    }
}

func frontmatter(_ contenido: String) -> [String] {
    let lineas = contenido.components(separatedBy: "\n")
    guard lineas.first == "---", let cierre = lineas.dropFirst().firstIndex(of: "---") else { return [] }
    return Array(lineas[1..<cierre])
}

func cuerpo(_ contenido: String) -> String {
    let lineas = contenido.components(separatedBy: "\n")
    guard lineas.first == "---", let cierre = lineas.dropFirst().firstIndex(of: "---") else { return contenido }
    return lineas[(cierre + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
}

func fichero(_ ruta: String, de nota: Note = nota, como export: OKFExport) -> String? {
    escritos(publicar(nota, como: export).changes)[ruta]
}
