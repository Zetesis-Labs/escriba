import EscribaCore
import EscribaEngine
import EscribaModel
import EscribaNotion
import EscribaOKF
import EscribaWhisper
import ServiceManagement
import SwiftUI

struct SettingsPane: View {
    let settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                block("General", "gearshape") { GeneralTab(settings: settings) }
                block("Transcripción", "waveform") { TranscriptionTab(settings: settings) }
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

private struct TranscriptionTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Idioma", selection: $settings.language) {
                Text("Espanol").tag("es")
                Text("English").tag("en")
                Text("Detectar en cada nota").tag("auto")
            }

            Picker("Detectar hablantes", selection: diarization) {
                Text("No").tag(-1)
                Text("Automatico").tag(0)
                ForEach(2...4, id: \.self) { count in
                    Text("\(count) hablantes").tag(count)
                }
            }
            Text("Detectar hablantes cuesta unos segundos mas por nota y solo funciona con Whisper en este Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Copia en texto plano") {
                Toggle("Escribir tambien un .txt", isOn: $settings.writeTxt)
                if settings.writeTxt {
                    LabeledContent("Carpeta") {
                        HStack {
                            Text(abbreviated(settings.txtFolderPath))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Cambiar…") {
                                if let path = chooseFolder() { settings.txtFolderPath = path }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var diarization: Binding<Int> {
        Binding(
            get: { settings.diarization.storageValue },
            set: { settings.diarization = Diarization(storageValue: $0) })
    }
}

private struct FoldersTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bandeja de Escriba")
                        Text("Lo que grabas en la app y los audios que arrastras")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ResolverPickers(choice: $settings.inboxResolvers, settings: settings)
                }
            }

            Section {
                if settings.watchedFolders.isEmpty {
                    Text("Ninguna carpeta extra. Solo se vigila Just Press Record.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.watchedFolders) { $folder in
                    VStack(alignment: .leading, spacing: 6) {
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
                        Picker("", selection: $folder.speakers) {
                            Text("Segun ajuste global").tag(Int?.none)
                            ForEach(2...4, id: \.self) { count in
                                Text("\(count) hablantes").tag(Int?.some(count))
                            }
                        }
                        .frame(width: 170)
                        Button(role: .destructive) {
                            settings.removeWatchedFolder(path: folder.path)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    ResolverPickers(choice: $folder.resolvers, settings: settings)
                    }
                }
            } header: {
                Text("Carpetas vigiladas")
            } footer: {
                Text("Cualquier audio que caiga en ellas se transcribe solo. Las claves llevan el nombre de la carpeta como prefijo. Los servicios para transcribir y resumir se configuran en STT y LLMs.")
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
    @State private var selected: UUID?
    @State private var removing: Connector?

    var body: some View {
        ListDetailLayout(listWidth: 230) {
            VStack(spacing: 0) {
                List(connectors.connectors, selection: $selected) { connector in
                    HStack {
                        Image(systemName: connector.isLive ? "circle.fill" : "circle")
                            .foregroundStyle(connector.isLive ? .green : .secondary)
                            .font(.caption2)
                        VStack(alignment: .leading) {
                            Text(connector.name)
                            Text(subtitle(of: connector))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(connector.id)
                }
                .listStyle(.inset)
                .onAppear {
                    if let name = MainSection.connectorToSelect, selected == nil {
                        selected = connectors.connectors.first { $0.name == name }?.id
                    }
                    if MainSection.selectsFirstItem, selected == nil {
                        selected = connectors.connectors.first?.id
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Menu {
                        ForEach(Connector.Kind.allCases, id: \.self) { kind in
                            Button(kind.label) { selected = connectors.add(kind).id }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Button {
                        removing = connectors.connectors.first { $0.id == selected }
                    } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
        } detail: {
            if let connector = connectors.connectors.first(where: { $0.id == selected }) {
                switch connector.kind {
                case .notion: NotionEditor(notion: connectors.editor(for: connector.id))
                case .okf: OKFEditor(okf: connectors.okfEditor(for: connector.id))
                }
            } else {
                ContentUnavailableView(
                    "Sin conector elegido",
                    systemImage: "square.and.arrow.up",
                    description: Text("Añade uno con + o elige uno de la lista."))
            }
        }
        .navigationTitle("Conectores")
        .confirmationDialog(
            "¿Quitar «\(removing?.name ?? "")»?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Quitar", role: .destructive) {
                if let removing { connectors.remove(removing.id) }
                selected = nil
                removing = nil
            }
        } message: {
            Text(removing.map { ConnectorText.removal(of: $0.kind) } ?? "")
        }
    }

    private func subtitle(of connector: Connector) -> String {
        switch connector.kind {
        case .notion:
            connector.notion?.source.label ?? "Sin base elegida"
        case .okf:
            connector.okf.flatMap { $0.isUsable ? abbreviated($0.folder) : nil } ?? "Sin carpeta elegida"
        }
    }
}

private struct NotionEditor: View {
    @Bindable var notion: NotionModel

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $notion.name)
                Toggle("Publicar cada transcripción nueva", isOn: $notion.publishes)
                    .disabled(notion.readiness != nil)
                if let pending = notion.readiness {
                    Text(pending).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Corregir hablantes o reprocesar regenera la página ya publicada.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Conexión con Notion") {
                SecureField("Token de la integración", text: $notion.token)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(notion.sources.isEmpty ? "Conectar" : "Actualizar bases y columnas") {
                        Task { await notion.connect() }
                    }
                    .disabled(notion.token.isEmpty || notion.phase.isWorking)
                    if notion.phase.isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                    if !notion.token.isEmpty {
                        Button("Desconectar", role: .destructive) { notion.disconnect() }
                    }
                }
                if let problem = notion.phase.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Text("En Notion: Ajustes → Conexiones → nueva conexión con «Token de acceso», dale acceso a las bases que quieras y pega aquí el token. Si añades columnas a la base, pulsa «Actualizar».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !notion.sources.isEmpty {
                Section("Base de datos") {
                    Picker("Guardar en", selection: chosen) {
                        Text("Sin elegir").tag(String?.none)
                        ForEach(notion.sources) { source in
                            Text(source.label).tag(String?.some(source.id))
                        }
                    }
                }
            }

            if notion.selected != nil {
                Section {
                    ForEach(notion.columns, id: \.name) { column in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(column.name)
                                Text(columnTypeLabel(column.type)).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: 150, alignment: .leading)
                            .padding(.top, 2)
                            TokenEditor(
                                source: columnBinding(column.name), context: .property, placeholder: "No se exporta")
                        }
                    }
                } header: {
                    Text("Propiedades")
                } footer: {
                    Text("Una fila por columna de tu base: escribe qué va en ella, con texto y datos. Vacía, Escriba no la toca. Las columnas de casilla, persona, archivo o relación no aparecen porque Escriba no escribe en ellas.")
                }

                Section {
                    TokenEditor(
                        source: $notion.body, context: .body,
                        placeholder: "Escribe aquí. Pulsa / para insertar un dato.", multiline: true)
                } header: {
                    Text("Cuerpo de la página")
                } footer: {
                    Text("Escribe como en una página: # para títulos, - para viñetas, **negrita**. Pulsa / para insertar un dato; el dato Audio sube el fichero a Notion. Una línea cuyos datos salen vacíos no se escribe.")
                }

                if let preview = notion.preview {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                ForEach(preview.properties) { property in
                                    GridRow {
                                        Text(property.name).foregroundStyle(.secondary)
                                        Text(property.value).lineLimit(2)
                                    }
                                }
                            }
                            Divider()
                            Text(preview.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                    } header: {
                        Text("Así queda")
                    } footer: {
                        Text("Con una grabación de ejemplo. Se actualiza mientras escribes, antes de guardar.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if notion.isDirty {
                    Text("Cambios sin guardar").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Descartar") { notion.discard() }
                    .disabled(!notion.isDirty)
                Button("Guardar") { notion.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!notion.isDirty)
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var chosen: Binding<String?> {
        Binding(
            get: { notion.selected?.id },
            set: { id in
                guard let source = notion.sources.first(where: { $0.id == id }) else { return }
                notion.choose(source)
            })
    }

    private func columnBinding(_ name: String) -> Binding<String> {
        Binding(get: { notion.value(forColumn: name) }, set: { notion.setValue($0, forColumn: name) })
    }
}
