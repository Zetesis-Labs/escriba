import Foundation
import Synchronization
import EscribaCore
import EscribaEngine
import EscribaNotion
import EscribaPluginKit

let manifest = PluginManifest(
    id: "notion", name: "Notion (plugin)", version: "0.1.0", secrets: ["token"], hosts: ["api.notion.com"])

func hostTransport() -> NotionTransport {
    { request in
        let response = try hostCall(HostRequest(
            op: .http, method: request.method, url: request.url, headers: request.headers, body: request.body))
        return NotionHTTPResponse(status: response.status ?? 0, headers: response.headers ?? [:], body: response.body ?? Data())
    }
}

func client() -> NotionClient {
    makeNotionClient(token: secretMarker("token"), over: hostTransport())
}

struct Draft {
    var export: NotionExport?
    var sources: [NotionDataSource]
    var problem: String?

    init(config: PluginJSON, state: PluginJSON) {
        export = try? config["export"].decode(NotionExport.self)
        sources = (try? state["sources"].decode([NotionDataSource].self)) ?? []
        problem = state["problem"].string
    }

    var hasToken: Bool { true }

    func config(hasToken: Bool) throws -> PluginJSON {
        var config = PluginJSON.object([:])
        if let export { config["export"] = try PluginJSON(encoding: export) }
        config["sourceID"] = .string(export?.source.id ?? "")
        return config
    }

    func state() throws -> PluginJSON {
        var state = PluginJSON.object([:])
        state["sources"] = try PluginJSON(encoding: sources)
        if let problem { state["problem"] = .string(problem) }
        return state
    }
}

func form(_ draft: Draft, hasToken: Bool, timeZone: TimeZone) -> PluginForm {
    var items: [FormItem] = [
        .section(
            "Conexión con Notion",
            [
                .secret("token", label: "Token de la integración"),
                .row([
                    .button(draft.sources.isEmpty ? "Conectar" : "Actualizar bases y columnas", action: "connect", enabled: hasToken),
                    .button("Desconectar", action: "disconnect", destructive: true, enabled: hasToken),
                ]),
            ] + (draft.problem.map { [FormItem.note($0, style: .warning)] } ?? []) + [
                .note("En Notion: Ajustes → Conexiones → nueva conexión con «Token de acceso», dale acceso a las bases que quieras y pega aquí el token. Si añades columnas a la base, pulsa «Actualizar»."),
            ]),
    ]
    if !draft.sources.isEmpty {
        items.append(.section("Base de datos", [
            .choice("sourceID", label: "Guardar en", options: draft.sources.map { FormOption(id: $0.id, label: $0.label) }),
        ]))
    }
    if let export = draft.export {
        let columns = writableProperties(of: export.source).map { column in
            FormItem.row([
                .label(column.name, help: columnTypeLabel(column.type), width: 150),
                .template("export/columns/\(column.name)", context: .property, placeholder: "No se exporta"),
            ])
        }
        let preview = notionPreview(export, timeZone: timeZone)
        let properties = preview.properties.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        items += [
            .section(
                "Propiedades",
                footer: "Una fila por columna de tu base: escribe qué va en ella, con texto y datos. Vacía, Escriba no la toca. Las columnas de casilla, persona, archivo o relación no aparecen porque Escriba no escribe en ellas.",
                columns),
            .section(
                "Cuerpo de la página",
                footer: "Escribe como en una página: # para títulos, - para viñetas, **negrita**. Pulsa / para insertar un dato; el dato Audio sube el fichero a Notion. Una línea cuyos datos salen vacíos no se escribe.",
                [.template("export/body", context: .body, placeholder: "Escribe aquí. Pulsa / para insertar un dato.", multiline: true)]),
            .section(
                "Así queda",
                footer: "Con una grabación de ejemplo. Se actualiza mientras escribes, antes de guardar.",
                [.preview(properties + "\n\n" + preview.text)]),
        ]
    }
    let problem: String? = !hasToken
        ? "Pega el token de tu integración de Notion."
        : draft.export.map(notionProblem) ?? "Elige la base donde guardar."
    return PluginForm(items: items, problem: problem)
}

func reconciled(_ config: PluginJSON, state: PluginJSON) -> Draft {
    var draft = Draft(config: config, state: state)
    let chosen = config.text("sourceID")
    if chosen.isEmpty {
        draft.export = nil
    } else if draft.export?.source.id != chosen, let source = draft.sources.first(where: { $0.id == chosen }) {
        draft.export = NotionExport(source: source, columns: suggestedColumns(for: source), body: draft.export?.body ?? NotionExport.standardBody)
    } else if let export = draft.export, let source = draft.sources.first(where: { $0.id == export.source.id }), source != export.source {
        draft.export = NotionExport(source: source, columns: refreshedColumns(export.columns, for: source), body: export.body)
    }
    return draft
}

func respond(_ draft: Draft, hasToken: Bool, timeZone: TimeZone) throws -> PluginResponse {
    PluginResponse(form: form(draft, hasToken: hasToken, timeZone: timeZone), config: try draft.config(hasToken: hasToken), state: try draft.state())
}

final class Box<Value: Sendable>: Sendable {
    let value = Mutex<Value?>(nil)
}

func serve(_ request: PluginRequest) async throws -> PluginResponse {
    let timeZone = TimeZone(identifier: request.timeZone) ?? .current
    let hasToken = request.config["token"].string == secretMarker("token")
    switch request.command {
    case .describe:
        return PluginResponse(manifest: manifest)
    case .form:
        return try respond(reconciled(request.config, state: request.state), hasToken: hasToken, timeZone: timeZone)
    case .action:
        var draft = reconciled(request.config, state: request.state)
        switch request.action {
        case "connect":
            do {
                draft.sources = try await client().dataSources()
                draft.problem = draft.sources.isEmpty ? "La integración no tiene acceso a ninguna base. Compártele una desde Notion." : nil
            } catch {
                draft.sources = []
                draft.problem = error.message
            }
            if let export = draft.export, let source = draft.sources.first(where: { $0.id == export.source.id }) {
                draft.export = NotionExport(source: source, columns: refreshedColumns(export.columns, for: source), body: export.body)
            }
        case "disconnect":
            draft.sources = []
            draft.problem = nil
        default:
            throw HostError("acción desconocida: \(request.action ?? "")")
        }
        return try respond(draft, hasToken: hasToken, timeZone: timeZone)
    case .publish:
        guard let note = request.note?.note else { return PluginResponse(error: "falta la nota") }
        guard let export = Draft(config: request.config, state: request.state).export else {
            return PluginResponse(error: "la base ya no está disponible")
        }
        let known = request.known
        let published = Box<PluginRef>()
        let journal = NotionJournal(
            known: { _ in known.map { NotionPageRef(id: $0.id, url: $0.url.flatMap(URL.init(string:))) } },
            published: { _, page, _ in published.value.withLock { $0 = PluginRef(id: page.id, url: page.url?.absoluteString) } },
            failed: { _, _ in })
        let url = try await notionSink(export: export, client: client(), journal: journal, timeZone: timeZone)(note)
        return PluginResponse(ref: published.value.withLock { $0 } ?? PluginRef(id: url.lastPathComponent, url: url.absoluteString))
    case .unpublish:
        guard let ref = request.ref else { return PluginResponse(error: "falta la referencia") }
        try await unpublish(pageId: ref, using: client())
        return PluginResponse()
    }
}
