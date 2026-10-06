import Foundation
import EscribaCore
import EscribaEngine
import EscribaOKF
import EscribaPluginKit

let manifest = PluginManifest(id: "okf", name: "OKF (plugin)", version: "0.1.0", folder: "folder")

func export(from config: PluginJSON) -> OKFExport {
    if let export = try? config.decode(OKFExport.self) { return export }
    return OKFExport(folder: config.text("folder"))
}

func hostFolder(_ root: String) -> OKFFolder {
    OKFFolder(
        root: URL(fileURLWithPath: root),
        read: { try hostCall(HostRequest(op: .read, path: $0)).contents },
        list: { try hostCall(HostRequest(op: .list)).paths ?? [] },
        write: { path, contents in _ = try hostCall(HostRequest(op: .write, path: path, contents: contents)) },
        remove: { _ = try hostCall(HostRequest(op: .remove, path: $0)) })
}

func isType(_ property: OKFProperty, in document: OKFDocument) -> Bool {
    property.key.trimmingCharacters(in: .whitespaces) == "type"
        && document.properties.first { $0.key.trimmingCharacters(in: .whitespaces) == "type" }?.id == property.id
}

func documentItems(_ document: OKFDocument, index: Int, export: OKFExport) -> [FormItem] {
    let base = "documents/\(index)"
    let links = export.documents.map { FormLink(id: $0.id, name: $0.name) }
    let properties = document.properties.enumerated().map { offset, property in
        FormItem.row([
            isType(property, in: document)
                ? .label("type", width: 130, monospaced: true)
                : .text("\(base)/properties/\(offset)/key", placeholder: "clave", monospaced: true, width: 130),
            .template("\(base)/properties/\(offset)/value", context: .property, placeholder: "valor", links: links, current: document.id),
            .button("Quitar", action: "removeProperty/\(document.id)/\(property.id)", symbol: "xmark.circle", enabled: !isType(property, in: document)),
        ])
    }
    return [
        .section(
            "Documento",
            footer: "La ruta dentro del bundle. Escribe // para insertar un dato en ella; el título se pone sin tildes ni signos.",
            [
                .text("\(base)/name", label: "Nombre"),
                .template("\(base)/path", label: "Ruta", context: .path, placeholder: "carpeta/[Día]-[Título].md"),
            ]),
        .section(
            "Propiedades",
            footer: "Son el frontmatter del fichero: clave y valor, con texto y datos mezclados. type es obligatorio en OKF. Escriba añade siempre escriba_key y generated para reconocer sus ficheros.",
            properties + [.button("Añadir propiedad", action: "addProperty/\(document.id)")]),
        .section(
            "Cuerpo",
            footer: "Escribe como en una página: Markdown, con # para los títulos. Pulsa / donde quieras para insertar un dato, o usa +. Una línea cuyos datos salen vacíos no se escribe.",
            [.template("\(base)/body", context: .body, placeholder: "Escribe aquí. Pulsa / para insertar un dato.", multiline: true, links: links, current: document.id)]),
        .section(
            "Así queda",
            footer: "Con una grabación de ejemplo. Se actualiza mientras escribes, antes de guardar.",
            [.preview(key: document.id)]),
    ]
}

func form(for config: PluginJSON, timeZone: TimeZone) -> PluginForm {
    let export = export(from: config)
    let tabs = export.documents.enumerated().map { index, document in
        FormTab(
            id: document.id, label: document.name.isEmpty ? "Sin nombre" : document.name,
            items: documentItems(document, index: index, export: export))
    }
    return PluginForm(
        items: [
            .section(
                "Carpeta del bundle",
                footer: "Escriba gestiona esta carpeta como un bundle OKF: escribe los documentos, un index.md en cada carpeta y log.md. Si va dentro de un bundle más grande, elige una subcarpeta propia.",
                [.folder("folder")]),
            .section(
                "Documentos",
                footer: "Cada grabación escribe un fichero por documento. Para enlazarlos entre sí, inserta el dato «Enlace a…».",
                [.tabs(tabs, addAction: "addDocument", removeAction: "removeDocument")]),
        ],
        problem: export.folder.isEmpty ? "Elige la carpeta del bundle." : okfProblem(export))
}

func apply(_ action: String, to config: PluginJSON) throws -> PluginJSON {
    var export = export(from: config)
    let parts = action.split(separator: "/").map(String.init)
    switch parts.first {
    case "addDocument":
        export.documents.append(OKFExport.newDocument(number: export.documents.count + 1))
    case "removeDocument":
        guard parts.count == 2 else { break }
        export.documents.removeAll { $0.id == parts[1] }
    case "addProperty":
        guard parts.count == 2, let index = export.documents.firstIndex(where: { $0.id == parts[1] }) else { break }
        export.documents[index].properties.append(OKFProperty(key: "", value: ""))
    case "removeProperty":
        guard parts.count == 3, let index = export.documents.firstIndex(where: { $0.id == parts[1] }) else { break }
        let document = export.documents[index]
        export.documents[index].properties.removeAll { $0.id == parts[2] && !isType($0, in: document) }
    default:
        throw HostError("acción desconocida: \(action)")
    }
    return try PluginJSON(encoding: export)
}

func serve(_ request: PluginRequest) async throws -> PluginResponse {
    let timeZone = TimeZone(identifier: request.timeZone) ?? .current
    switch request.command {
    case .describe:
        return PluginResponse(manifest: manifest)
    case .form:
        let config = try PluginJSON(encoding: export(from: request.config))
        return PluginResponse(form: form(for: config, timeZone: timeZone), config: config)
    case .preview:
        let files = okfPreview(export(from: request.config), timeZone: timeZone)
        return PluginResponse(previews: Dictionary(uniqueKeysWithValues: files.map { ($0.documentID, "── \($0.path)\n\($0.contents)") }))
    case .action:
        let config = try apply(request.action ?? "", to: request.config)
        return PluginResponse(form: form(for: config, timeZone: timeZone), config: config)
    case .publish:
        guard let note = request.note?.note else { return PluginResponse(error: "falta la nota") }
        let export = export(from: request.config)
        let sink = okfSink(export: export, folder: hostFolder(export.folder), producer: "escriba/plugin-okf", timeZone: timeZone)
        let url = try await sink(note)
        let notePath = String(url.path(percentEncoded: false).dropFirst(export.folder.count)).drop { $0 == "/" }
        return PluginResponse(ref: PluginRef(id: String(notePath), url: url.absoluteString))
    case .unpublish:
        guard let ref = request.ref else { return PluginResponse(error: "falta la referencia") }
        let export = export(from: request.config)
        try okfUnpublish(ref, from: hostFolder(export.folder), documents: export.documents, timeZone: timeZone)
        return PluginResponse()
    }
}
