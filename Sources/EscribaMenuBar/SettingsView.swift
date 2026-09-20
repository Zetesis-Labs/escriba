import EscribaModel
import EscribaNotion
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
                block("Modelo", "internaldrive") { ModelTab() }
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
            Text("Detectar hablantes cuesta unos segundos mas por nota.")
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
                if settings.watchedFolders.isEmpty {
                    Text("Ninguna carpeta extra. Solo se vigila Just Press Record.")
                        .foregroundStyle(.secondary)
                }
                ForEach($settings.watchedFolders) { $folder in
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
                            settings.watchedFolders.removeAll { $0.path == folder.path }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Carpetas vigiladas")
            } footer: {
                Text("Cualquier audio que caiga en ellas se transcribe solo. Las claves llevan el nombre de la carpeta como prefijo.")
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

private struct ModelTab: View {
    @State private var installed = WhisperKitBackend.installedModelFolder()
    @State private var sizeOnDisk: String?
    @State private var progress: Double?
    @State private var failure: String?

    var body: some View {
        Form {
            LabeledContent("Modelo", value: WhisperKitBackend.defaultVariant)

            if installed != nil {
                LabeledContent("Estado", value: "descargado\(sizeOnDisk.map { " · \($0)" } ?? "")")
                Button("Borrar del disco", role: .destructive) { delete() }
                Text("Sin el modelo no se transcribe nada hasta volver a descargarlo.")
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
        .formStyle(.grouped)
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

private func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path(percentEncoded: false)
}

private func abbreviated(_ path: String) -> String {
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

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(connectors.connectors, selection: $selected) { connector in
                    HStack {
                        Image(systemName: connector.isLive ? "circle.fill" : "circle")
                            .foregroundStyle(connector.isLive ? .green : .secondary)
                            .font(.caption2)
                        VStack(alignment: .leading) {
                            Text(connector.name)
                            Text(connector.notion?.source.label ?? "Sin base elegida")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(connector.id)
                }
                .listStyle(.inset)
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
                        if let selected { connectors.remove(selected) }
                        selected = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)

            if let selected, connectors.connectors.contains(where: { $0.id == selected }) {
                NotionEditor(notion: connectors.editor(for: selected))
                    .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(
                    "Sin conector elegido",
                    systemImage: "square.and.arrow.up",
                    description: Text("Añade uno con + o elige uno de la lista."))
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Conectores")
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
                    ForEach(NotionField.allCases, id: \.self) { field in
                        HStack {
                            Picker(field.label, selection: binding(for: field)) {
                                Text("No exportar").tag(String?.none)
                                ForEach(notion.options(for: field), id: \.name) { property in
                                    Text(property.name).tag(String?.some(property.name))
                                }
                            }
                            .disabled(notion.options(for: field).isEmpty)
                            Toggle("En el cuerpo", isOn: inBody(field))
                                .toggleStyle(.checkbox)
                                .fixedSize()
                        }
                    }
                } header: {
                    Text("Columnas")
                } footer: {
                    Text("Cada dato puede ir a una columna de la base, al cuerpo de la página (como bloque), a los dos sitios o a ninguno.")
                }

                Section {
                    TemplateEditor(notion: notion)
                } header: {
                    Text("Cuerpo de la página")
                } footer: {
                    Text("Escribe texto libre, o «/» para insertar un bloque: /transcripcion, /audio, /fecha, /hablantes, /duracion, /origen, /titulo, /encabezado.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var chosen: Binding<String?> {
        Binding(
            get: { notion.selected?.id },
            set: { id in
                guard let source = notion.sources.first(where: { $0.id == id }) else { return }
                notion.choose(source)
            })
    }

    private func binding(for field: NotionField) -> Binding<String?> {
        Binding(
            get: { notion.property(for: field) },
            set: { notion.assign(field, to: $0) })
    }

    private func inBody(_ field: NotionField) -> Binding<Bool> {
        Binding(
            get: { notion.template.blocks.contains(.field(field)) },
            set: { wanted in
                let blocks = notion.template.blocks
                if wanted, !blocks.contains(.field(field)) {
                    notion.insert(.field(field), at: blocks.firstIndex { !$0.isText } ?? blocks.count)
                } else if !wanted, let index = blocks.firstIndex(of: .field(field)) {
                    notion.removeBlock(at: index)
                }
            })
    }
}

private struct TemplateEditor: View {
    @Bindable var notion: NotionModel
    @State private var slashRow: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            List {
                ForEach(Array(notion.template.blocks.enumerated()), id: \.offset) { index, block in
                    row(index, block)
                        .listRowSeparator(.hidden)
                }
                .onMove { notion.moveBlocks(from: $0, to: $1) }
                .onDelete { $0.forEach(notion.removeBlock(at:)) }
            }
            .listStyle(.plain)
            .frame(minHeight: CGFloat(max(notion.template.blocks.count, 3)) * 34 + 8)
            .scrollDisabled(true)
            HStack {
                Button("Añadir texto") { notion.insert(.text(""), at: notion.template.blocks.count) }
                Menu("Insertar bloque") {
                    ForEach(slashCommands) { command in
                        Button("\(command.command) — \(command.help)") {
                            notion.insert(command.block, at: notion.template.blocks.count)
                        }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Volver a la plantilla básica") { notion.template = .standard }
                    .disabled(notion.template == .standard)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private func row(_ index: Int, _ block: TemplateBlock) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.caption)
            switch block {
            case .text(let text):
                TextField("Texto, o / para un bloque", text: textBinding(index, text), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !notion.apply(command: text, replacing: index) else { return }
                        notion.insert(.text(""), at: index + 1)
                    }
                    .popover(isPresented: slashPresented(index), arrowEdge: .bottom) {
                        SlashMenu(typed: text) { command in
                            _ = notion.apply(command: command.command, replacing: index)
                            slashRow = nil
                        }
                    }
            default:
                Label(block.label, systemImage: symbol(for: block))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Spacer()
            }
            Button { notion.removeBlock(at: index) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private func textBinding(_ index: Int, _ current: String) -> Binding<String> {
        Binding(
            get: { current },
            set: { text in
                notion.setText(text, at: index)
                slashRow = text.hasPrefix("/") ? index : (slashRow == index ? nil : slashRow)
            })
    }

    private func slashPresented(_ index: Int) -> Binding<Bool> {
        Binding(get: { slashRow == index }, set: { if !$0, slashRow == index { slashRow = nil } })
    }

    private func symbol(for block: TemplateBlock) -> String {
        switch block {
        case .text: "text.alignleft"
        case .heading: "textformat.size"
        case .transcript: "text.quote"
        case .audio: "waveform"
        case .field: "tag"
        }
    }
}

private struct SlashMenu: View {
    let typed: String
    let choose: (SlashCommand) -> Void

    var body: some View {
        let matches = slashCommands(matching: typed)
        VStack(alignment: .leading, spacing: 2) {
            if matches.isEmpty {
                Text("Ningún bloque se llama así").foregroundStyle(.secondary).padding(8)
            }
            ForEach(matches) { command in
                Button {
                    choose(command)
                } label: {
                    HStack {
                        Text(command.command).font(.body.monospaced())
                        Spacer()
                        Text(command.help).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 360)
    }
}
