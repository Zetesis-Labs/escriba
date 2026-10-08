import EscribaCore
import EscribaEngine
import EscribaModel
import EscribaWhisper
import ServiceManagement
import SwiftUI

struct SettingsPane: View {
    let settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                block("General", "gearshape") { GeneralTab(settings: settings) }
                block("Carpetas vigiladas", "folder.badge.plus") { FoldersTab(settings: settings) }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Ajustes")
    }

    private func block<Content: View>(
        _ title: String, _ symbol: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 12)
            content()
        }
    }
}

private struct GeneralTab: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Arrancar al iniciar sesion", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle("Notificar cada transcripcion", isOn: $settings.notifyEveryNote)
            Text("Los problemas se notifican siempre.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct FoldersTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bandeja de Escriba")
                    Text("Lo que grabas en la app y los audios que arrastras")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if settings.watchedFolders.isEmpty {
                    Text("Ninguna carpeta extra. Solo se vigila Just Press Record.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.watchedFolders) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.displayName)
                            Text(abbreviated(folder.path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.removeWatchedFolder(path: folder.path)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Carpetas vigiladas")
            } footer: {
                Text("Cualquier audio que caiga en ellas lo procesa la receta por defecto, que se configura en Recetas. Las claves llevan el nombre de la carpeta como prefijo.")
            }

            Button("Anadir carpeta…") {
                guard let path = chooseFolder(),
                    !settings.watchedFolders.contains(where: { $0.path == path })
                else { return }
                settings.watchedFolders.append(WatchedFolder(path: path))
            }

            Button("Anadir Notas de Voz") {
                settings.watchedFolders.append(
                    WatchedFolder(path: voiceMemosPath, style: .voiceMemos))
            }
            .disabled(settings.watchedFolders.contains { $0.path == voiceMemosPath })
        }
        .formStyle(.grouped)
    }

    private var voiceMemosPath: String {
        voiceMemosRoot().path(percentEncoded: false)
    }
}

struct WhisperModelSection: View {
    @State private var installed = WhisperKitBackend.installedModelFolder()
    @State private var sizeOnDisk: String?
    @State private var progress: Double?
    @State private var failure: String?

    var body: some View {
        Section("Modelo") {
            LabeledContent("Modelo", value: WhisperKitBackend.defaultVariant)

            if installed != nil {
                LabeledContent("Estado", value: "descargado\(sizeOnDisk.map { " · \($0)" } ?? "")")
                Button("Borrar del disco", role: .destructive) { delete() }
                Text("Sin el modelo no se transcribe nada en este Mac hasta volver a descargarlo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let progress {
                ProgressView("Descargando…", value: progress)
            } else {
                LabeledContent("Estado", value: "no descargado")
                Button("Descargar (unos 3 GB)") { download() }
            }

            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
        .task { await measure() }
    }

    private func refresh() {
        installed = WhisperKitBackend.installedModelFolder()
        Task { await measure() }
    }

    private func measure() async {
        guard let installed else { return }
        sizeOnDisk = await Task.detached { directorySize(installed) }.value
    }

    private func download() {
        progress = 0
        failure = nil
        Task {
            do {
                try await WhisperKitBackend.downloadModel { fraction in
                    Task { @MainActor in progress = fraction }
                }
            } catch {
                failure = "\(error)"
            }
            progress = nil
            refresh()
        }
    }

    private func delete() {
        try? FileManager.default.removeItem(at: WhisperKitBackend.defaultModelsRoot)
        sizeOnDisk = nil
        refresh()
    }
}

func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path(percentEncoded: false)
}

func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

private nonisolated func directorySize(_ folder: URL) -> String {
    let walker = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.fileSizeKey])
    var total = 0
    while case let url as URL = walker?.nextObject() {
        total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
}


struct ConnectorsPane: View {
    let connectors: ConnectorsModel
    var openProject: () -> Void = {}
    @State private var selected: String?
    @State private var problem: String?

    var body: some View {
        ListDetailLayout(listWidth: 230) {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    Section("Cuentas") {
                        ForEach(connectors.accounts) { account in
                            Label(account.name, systemImage: account.enabled ? "key" : "key.slash")
                                .tag("account:" + account.id.uuidString)
                        }
                    }
                    Section("Destinos") {
                        ForEach(connectors.connectors) { connector in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(connector.name)
                                Text(connector.sourceMissing ? "Fuera del proyecto" : connector.provider)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag("destination:" + connector.id.uuidString)
                        }
                    }
                }
                .listStyle(.inset)
                Divider()
                HStack {
                    Menu {
                        ForEach(connectors.providers) { provider in
                            Button(provider.name) {
                                do { selected = "account:" + (try connectors.addAccount(provider: provider.id)).id.uuidString }
                                catch { problem = error.localizedDescription }
                            }
                        }
                    } label: { ListBarIcon(systemName: "plus") }
                    .menuIndicator(.hidden)
                    .disabled(connectors.providers.isEmpty)
                    Spacer()
                    Button("Abrir proyecto", action: openProject)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let account = connectors.accounts.first(where: { "account:" + $0.id.uuidString == selected }) {
                ConnectorAccountEditor(account: account, connectors: connectors).id(account.id)
            } else if let connector = connectors.connectors.first(where: { "destination:" + $0.id.uuidString == selected }) {
                ConnectorDestinationDetail(connector: connector, accounts: connectors.accounts, openProject: openProject)
            } else {
                ContentUnavailableView("Cuentas y destinos", systemImage: "square.and.arrow.up",
                    description: Text("Añade una cuenta con + y define sus destinos en el proyecto."))
            }
        }
        .navigationTitle("Conectores")
        .onAppear {
            if let name = MainSection.connectorToSelect, selected == nil {
                selected = connectors.connectors.first { $0.name == name }.map { "destination:" + $0.id.uuidString }
            }
            if MainSection.selectsFirstItem, selected == nil {
                selected = connectors.connectors.first.map { "destination:" + $0.id.uuidString } ?? connectors.accounts.first.map { "account:" + $0.id.uuidString }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = problem ?? connectors.problem {
                Text(message).font(.callout).foregroundStyle(.red).padding().background(.regularMaterial)
            }
        }
    }
}

private struct ConnectorAccountEditor: View {
    @State var account: ConnectorAccount
    let connectors: ConnectorsModel
    @State private var token = ""
    @State private var tokenSaved = false
    @State private var credentialProblem: String?
    @State private var revoking = false

    var body: some View {
        Form {
            Section("Cuenta") {
                TextField("Nombre", text: $account.name)
                LabeledContent("Proveedor", value: account.provider)
                LabeledContent("Identificador", value: account.id.uuidString)
                    .textSelection(.enabled)
                Toggle("Permitir acceso", isOn: $account.enabled)
            }
            Section("Permisos") {
                if account.capability == "folder" {
                    LabeledContent("Carpeta", value: account.folder ?? "Sin elegir")
                    Button("Elegir carpeta…") {
                        if let path = chooseFolder() { account.folder = path }
                    }
                } else if account.capability == "http" {
                    LabeledContent("Servidor autorizado", value: account.origin ?? "Sin servidor")
                    SecureField("Nuevo token", text: $token)
                    HStack {
                        Button("Guardar token") {
                            do {
                                try connectors.saveToken(token, account: account.id)
                                token = ""
                                tokenSaved = true
                                credentialProblem = nil
                            } catch {
                                tokenSaved = false
                                credentialProblem = error.localizedDescription
                            }
                        }
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Borrar token", role: .destructive) {
                            do {
                                try connectors.saveToken(nil, account: account.id)
                                token = ""
                                tokenSaved = false
                                credentialProblem = nil
                            } catch { credentialProblem = error.localizedDescription }
                        }
                    }
                    if let credentialProblem { Text(credentialProblem).foregroundStyle(.red) }
                    if tokenSaved { Text("Token guardado").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                Button("Guardar cuenta") { connectors.updateAccount(account) }
                    .keyboardShortcut(.defaultAction)
                Button("Revocar acceso", role: .destructive) { revoking = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("¿Revocar el acceso de esta cuenta?", isPresented: $revoking) {
            Button("Revocar", role: .destructive) {
                account.enabled = false
                tokenSaved = false
                do {
                    try connectors.removeAccount(account.id)
                    token = ""
                    credentialProblem = nil
                } catch { credentialProblem = error.localizedDescription }
            }
        } message: {
            Text("Se borra su credencial y se impiden nuevas operaciones. Sus destinos y el rastro de publicaciones se conservan.")
        }
    }
}

private struct ConnectorDestinationDetail: View {
    let connector: Connector
    let accounts: [ConnectorAccount]
    let openProject: () -> Void

    var body: some View {
        Form {
            Section(connector.name) {
                LabeledContent("Proveedor", value: connector.provider)
                LabeledContent("Cuenta", value: accounts.first { $0.id == connector.accountID }?.name ?? "No disponible")
                LabeledContent("Identificador", value: connector.key).textSelection(.enabled)
                LabeledContent("Estado", value: status)
                if let description = connector.description { Text(description) }
                if let problem = connector.migrationProblem { Text(problem).foregroundStyle(.red) }
                Button("Editar en el proyecto", action: openProject)
            }
            if let schema = connector.inputSchemaJSON {
                Section("Datos de entrada") {
                    ForEach(fields(schema)) { field in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(field.name).fontWeight(.medium)
                                Spacer()
                                Text(field.type).foregroundStyle(.secondary)
                                if field.required { Text("Obligatorio").font(.caption).foregroundStyle(.secondary) }
                            }
                            if let description = field.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    DisclosureGroup("Ver esquema JSON") {
                        Text(pretty(schema)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            Section("Configuración") {
                DisclosureGroup("Ver configuración JSON") {
                    Text(pretty(connector.configurationJSON)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        if connector.legacy { return "Pendiente de migración" }
        if connector.sourceMissing { return "Fuera del proyecto; disponible para mantener publicaciones" }
        if accounts.first(where: { $0.id == connector.accountID })?.enabled != true { return "Cuenta sin acceso" }
        return connector.isLive ? "Disponible" : "Inactivo"
    }
    private struct InputField: Identifiable {
        let name: String
        let type: String
        let required: Bool
        let description: String?
        var id: String { name }
    }

    private func fields(_ schema: String) -> [InputField] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any],
              let properties = object["properties"] as? [String: [String: Any]] else { return [] }
        let required = Set(object["required"] as? [String] ?? [])
        let labels = ["string": "Texto", "number": "Número", "integer": "Entero", "boolean": "Sí / no", "array": "Lista", "object": "Objeto", "null": "Vacío"]
        return properties.keys.sorted().map { name in
            let property = properties[name] ?? [:]
            let types = property["type"] as? [String] ?? [property["type"] as? String ?? "Personalizado"]
            return InputField(name: name, type: types.map { labels[$0] ?? $0 }.joined(separator: " / "),
                required: required.contains(name), description: property["description"] as? String)
        }
    }

    private func pretty(_ text: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return text }
        return String(decoding: data, as: UTF8.self)
    }
}
