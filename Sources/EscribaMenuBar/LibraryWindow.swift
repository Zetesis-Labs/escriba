import EscribaModel
import EscribaCore
import EscribaStore
import SwiftUI
import UniformTypeIdentifiers

enum RowAction: Identifiable {
    case removeAudio(StoredRecording)
    case discard(StoredRecording)
    case unpublish(StoredRecording, Connector)

    var id: String {
        switch self {
        case .removeAudio(let recording): "quitar-\(recording.key)"
        case .discard(let recording): "borrar-\(recording.key)"
        case .unpublish(let recording, let connector): "despublicar-\(recording.key)-\(connector.key)"
        }
    }
}

struct LibraryWindow: View {
    let model: LibraryModel?
    let problem: String?
    let folders: [WatchedFolder]
    let connectors: [Connector]
    let recipeListing: [RecipeListing]
    let recorder: RecorderModel
    let inbox: InboxModel
    let settings: AppSettings

    @State private var selected: String?
    @State private var pendingAction: RowAction?
    @State private var actionError: String?
    @State private var dropTargeted = false

    var body: some View {
        if let model {
            ListDetailLayout {
                List(model.recordings, selection: $selected) { recording in
                    RecordingRowView(
                        recording: recording, originName: originName(recording),
                        connectorNames: Dictionary(connectors.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first }))
                        .contextMenu {
                            PublishMenu(
                                model: model, recording: recording, connectors: connectors,
                                onAction: { pendingAction = $0 }
                            ) {
                                actionError = $0
                            }
                            Button("Quitar la copia de audio…") {
                                pendingAction = .removeAudio(recording)
                            }
                            .disabled(recording.audio != .libraryCopy)
                            Button("Borrar de la biblioteca…", role: .destructive) {
                                pendingAction = .discard(recording)
                            }
                        }
                }
                .listStyle(.inset)
                .onChange(of: model.recordings.isEmpty, initial: true) {
                    if MainSection.selectsFirstItem, selected == nil {
                        selected = model.recordings.first?.key
                    }
                }
            } detail: {
                if let selected,
                    let recording = model.recordings.first(where: { $0.key == selected }) {
                    TranscriptDetail(
                        model: model,
                        settings: settings,
                        recording: recording,
                        originName: originName(recording),
                        connectors: connectors,
                        recipeListing: recipeListing,
                        onAction: { pendingAction = $0 })
                } else {
                    ContentUnavailableView(
                        "Elige una grabacion",
                        systemImage: "waveform",
                        description: Text(
                            librarySummary(of: model.recordings.map(\.status))
                                + "\nArrastra aquí un audio o pulsa Grabar."))
                }
            }
            .navigationTitle("Biblioteca")
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        recipeChoices { chooseAudio(recipe: $0) }
                    } label: {
                        Label("Añadir audio…", systemImage: "plus.rectangle.on.folder")
                    } primaryAction: {
                        chooseAudio(recipe: nil)
                    }
                    .help("Añadir audios con la receta por defecto; en la flecha, con otra")
                    if recorder.isRecording {
                        Button {
                            recorder.stop()
                        } label: {
                            Label("Detener", systemImage: "stop.circle.fill")
                        }
                        .help("Detener y transcribir")
                    } else {
                        Menu {
                            recipeChoices { recipe in Task { await recorder.start(recipe: recipe) } }
                        } label: {
                            Label("Grabar", systemImage: "mic.circle")
                        } primaryAction: {
                            Task { await recorder.start() }
                        }
                        .help("Grabar una nota de voz con la receta por defecto; en la flecha, con otra")
                        .disabled(recorder.state == .asking)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let notice = inbox.notice {
                    NoticeBar(text: notice) { inbox.dismissNotice() }
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(8))
                            inbox.dismissNotice()
                        }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                inbox.add(urls)
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted { DropHint() }
            }
            .alert(
                "Grabadora",
                isPresented: Binding(
                    get: { recorder.problem != nil },
                    set: { if !$0 { recorder.dismissProblem() } })
            ) {
                if recorder.state == .denied {
                    Button("Abrir Ajustes del Sistema") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                        recorder.dismissProblem()
                    }
                }
                Button("Vale") { recorder.dismissProblem() }
            } message: {
                Text(recorder.problem ?? "")
            }
            .confirmationDialog(
                dialogTitle,
                isPresented: Binding(
                    get: { pendingAction != nil },
                    set: { if !$0 { pendingAction = nil } }),
                titleVisibility: .visible,
                presenting: pendingAction
            ) { action in
                dialogButtons(action, model: model)
            } message: { action in
                Text(dialogMessage(action))
            }
            .alert(
                "No se pudo",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } })
            ) {
                Button("Vale") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        } else {
            ContentUnavailableView(
                "La biblioteca no esta disponible",
                systemImage: "waveform.badge.exclamationmark",
                description: Text(problem ?? "la app no pudo arrancar"))
        }
    }

    private var dialogTitle: String {
        switch pendingAction {
        case .removeAudio(let recording): "¿Quitar el audio de \(recording.key)?"
        case .discard(let recording): "¿Borrar \(recording.key) de la biblioteca?"
        case .unpublish(let recording, let connector): "¿Borrar \(recording.key) de \(connector.name)?"
        case nil: ""
        }
    }

    @ViewBuilder
    private func dialogButtons(_ action: RowAction, model: LibraryModel) -> some View {
        switch action {
        case .removeAudio(let recording):
            Button("Quitar la copia de audio", role: .destructive) {
                perform { try await model.removeAudio(recording.key) }
            }
        case .discard(let recording):
            Button("Borrar grabacion y transcripciones", role: .destructive) {
                perform { try await model.discard(recording.key) }
                if selected == recording.key { selected = nil }
            }
        case .unpublish(let recording, let connector):
            Button("Borrar de \(connector.name)", role: .destructive) {
                perform { try await model.unpublish(recording.key, from: connector.key) }
            }
        }
        Button("Cancelar", role: .cancel) {}
    }

    private func dialogMessage(_ action: RowAction) -> String {
        switch action {
        case .removeAudio(let recording):
            RowActionText.removeAudio(
                originalExists: FileManager.default.fileExists(
                    atPath: recording.sourceURL.path(percentEncoded: false)))
        case .discard:
            RowActionText.discard
        case .unpublish(_, let connector):
            RowActionText.unpublish(from: connector.provider)
        }
    }

    private func chooseAudio(recipe: String?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = audioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Añadir"
        guard panel.runModal() == .OK else { return }
        inbox.add(panel.urls, recipe: recipe)
    }

    private func recipeChoices(_ choose: @escaping (String?) -> Void) -> some View {
        Section("Con la receta") {
            ForEach(recipeListing) { recipe in
                Button(recipe.isDefault ? "\(recipe.name) (por defecto)" : recipe.name) {
                    choose(recipe.isDefault ? nil : recipe.key)
                }
            }
        }
    }


    private func originName(_ recording: StoredRecording) -> String? {
        recipeOrigin(
            forSource: recording.sourceURL.path(percentEncoded: false), inbox: Paths.inbox.path(percentEncoded: false),
            folders: folders)?.name
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                actionError = "\(error)"
            }
        }
    }
}

struct PublishMenu: View {
    let model: LibraryModel
    let recording: StoredRecording
    let connectors: [Connector]
    let onAction: (RowAction) -> Void
    let onError: (String) -> Void

    var body: some View {
        let live = connectors.filter { model.canPublish(to: $0.key) }
        if !live.isEmpty {
            ForEach(live) { connector in
                let kind = connector.name
                if let publication = recording.publication(in: connector.key), publication.isPublished {
                    Menu(connector.name) {
                        if let page = publication.url {
                            Button("Abrir publicación") { NSWorkspace.shared.open(page) }
                            if page.isFileURL {
                                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([page]) }
                            }
                        }
                        Button("Actualizar en \(kind)") { publish(to: connector) }
                            .disabled(model.isPublishing(recording.key, to: connector.key))
                        Divider()
                        Button("Borrar de \(kind)…", role: .destructive) {
                            onAction(.unpublish(recording, connector))
                        }
                    }
                } else {
                    Button("Publicar en \(connector.name)") { publish(to: connector) }
                        .disabled(model.isPublishing(recording.key, to: connector.key))
                }
            }
            Divider()
        }
    }

    private func publish(to connector: Connector) {
        Task {
            do {
                try await model.publish(recording, to: connector.key)
            } catch {
                onError("\(error)")
            }
        }
    }
}

struct RecordingRowView: View {
    let recording: StoredRecording
    let originName: String?
    let connectorNames: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recording.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let duration = recording.transcript?.duration {
                    Text(clockStamp(duration))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let excerpt = recordingExcerpt(digest: recording.digest, preview: recording.transcript?.preview) {
                Text(excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let tags = recording.digest?.tags, !tags.isEmpty {
                TagChips(tags: tags, limit: 3)
            }
            HStack(spacing: 6) {
                StatusChip(status: recording.status)
                Text(footer)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                if let problem = recording.publications.first(where: { $0.error != nil })?.error {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("No se publicó: \(problem)")
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }

    private var footer: String {
        let published = recording.publications.filter(\.isPublished).map { connectorNames[$0.connector] ?? "conector" }
        let parts = [
            originName,
            recordingWhen(recording.startedAt, now: Date(), timeZone: .current),
            published.isEmpty ? nil : "en " + published.joined(separator: " y "),
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

struct TagChips: View {
    let tags: [String]
    var limit = Int.max

    var body: some View {
        let visible = visibleTags(tags, limit: limit)
        HStack(spacing: 4) {
            ForEach(visible.shown, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            if visible.hidden > 0 {
                Text("+\(visible.hidden)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension StoredRecording {
    var displayTitle: String {
        recordingTitle(digest: digest, preview: transcript?.preview, startedAt: startedAt, timeZone: .current)
    }
}

struct StatusChip: View {
    let status: RecordingStatus

    var body: some View {
        if let (label, color) = descriptor {
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var descriptor: (String, Color)? {
        switch status {
        case .pending: ("En cola", .gray)
        case .processing: ("Transcribiendo", .blue)
        case .failed: ("Error", .orange)
        case .done, .discarded: nil
        }
    }
}

struct TranscriptDetail: View {
    let model: LibraryModel
    let settings: AppSettings
    let recording: StoredRecording
    let originName: String?
    let connectors: [Connector]
    let recipeListing: [RecipeListing]
    let onAction: (RowAction) -> Void

    @State private var transcript: Transcript?
    @State private var versions: [TranscriptVersion] = []
    @State private var trace: RecipeTrace?
    @State private var choosingRecipe = false
    @State private var failure: String?
    @State private var player = PlayerModel()
    @State private var renameTarget: String?
    @State private var learningNotice: String?
    @State private var newName = ""
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            if recording.audio == .missing {
                Label(
                    "Solo queda la transcripcion: el audio ya no existe",
                    systemImage: "speaker.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
            } else {
                PlayerBar(player: player)
            }
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
            }
        }
        .navigationTitle(recording.displayTitle)
        .task(id: recording.key) {
            await reload()
            if recording.audio != .missing { player.load(recording.audioURL) }
        }
        .onChange(of: recording.status) { Task { await reload() } }
        .onChange(of: model.traceRevision(for: recording.key)) { Task { await reload() } }
        .toolbar {
            if model.reprocessing.contains(recording.key) {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
            ToolbarItem { versionsMenu }
            ToolbarItem { speakersMenu }
            ToolbarItem { actionsMenu }
        }
        .sheet(isPresented: $choosingRecipe) {
            ReprocessSheet(
                settings: settings,
                listing: recipeListing,
                onRun: { choice in
                    choosingRecipe = false
                    reprocess(choice)
                },
                onCancel: { choosingRecipe = false })
        }
        .alert(
            "Renombrar hablante",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
        ) {
            TextField("Nombre", text: $newName)
            Button("Renombrar") { renameCurrent() }
            Button("Cancelar", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Si la grabación tiene huellas de voz, Escriba recordará a esta persona y la reconocerá en las siguientes.")
        }
        .alert(
            "Renombrado, pero sin aprender su voz",
            isPresented: Binding(get: { learningNotice != nil }, set: { if !$0 { learningNotice = nil } })
        ) {
            Button("Vale") { learningNotice = nil }
        } message: {
            Text(
                "Esta versión no tiene huellas de voz: se transcribió antes de Personas o sin detectar hablantes. Para que Escriba reconozca a \(learningNotice ?? "") en otras grabaciones, reprocesa esta con «Detectar hablantes» y vuelve a renombrar, o registra su voz en Personas.")
        }
        .alert(
            "No se pudo",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } })
        ) {
            Button("Vale") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Copiar la transcripcion") { copyToPasteboard(transcript?.rendered) }
                .disabled(transcript == nil)
            Button(recording.digest == nil ? "Resumir con el modelo del sistema" : "Rehacer el resumen") {
                summarize()
            }
            .disabled(!model.canSummarize || transcript == nil || model.isSummarizing(recording.key))
            Button("Quitar el resumen") { forgetSummary() }
                .disabled(recording.digest == nil)
            Button("Copiar el JSON") { copyJSON() }
                .disabled(transcript == nil)
            Divider()
            PublishMenu(
                model: model, recording: recording, connectors: connectors, onAction: onAction
            ) {
                actionError = $0
            }
            Button("Quitar la copia de audio…") { onAction(.removeAudio(recording)) }
                .disabled(recording.audio != .libraryCopy)
            Divider()
            Button("Borrar de la biblioteca…", role: .destructive) {
                onAction(.discard(recording))
            }
        } label: {
            Label("Acciones", systemImage: "ellipsis.circle")
        }
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyJSON() {
        guard let transcript else { return }
        copyToPasteboard(
            transcriptExport(
                key: recording.key,
                startedAt: recording.startedAt,
                source: recording.sourceURL,
                backend: recording.transcript?.backend,
                transcript: transcript
            ).json())
    }

    private var speakersMenu: some View {
        Menu {
            if let transcript, !transcript.speakers.isEmpty {
                Section("Hablantes") {
                    ForEach(transcript.speakers, id: \.self) { speaker in
                        Menu(speakerTitle(speaker, in: transcript)) {
                            if transcript.recognition(of: speaker) != nil {
                                Button("No es \(speaker)") {
                                    correct { try await model.forgetRecognition(of: speaker, in: recording.key) }
                                }
                                Divider()
                            }
                            Button("Renombrar…") {
                                newName = speaker
                                renameTarget = speaker
                            }
                            ForEach(
                                transcript.speakers.filter { $0 != speaker }, id: \.self
                            ) { other in
                                Button("Fusionar con \(other)") {
                                    correct { try await model.merge(speaker, into: other, in: recording.key).transcript }
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Hablantes", systemImage: "person.2")
        }
        .disabled((transcript?.speakers.isEmpty ?? true) || model.reprocessing.contains(recording.key))
    }

    private var versionsMenu: some View {
        Menu {
            ForEach(versions) { version in
                Button {
                    choose(version)
                } label: {
                    if version.isCurrent {
                        Label(versionTitle(version), systemImage: "checkmark")
                    } else {
                        Text(versionTitle(version))
                    }
                }
            }
            if !versions.isEmpty { Divider() }
            Button("Reprocesar con una receta…") { choosingRecipe = true }
                .disabled(recording.audio == .missing)
        } label: {
            Label(currentVersionLabel, systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .disabled(model.reprocessing.contains(recording.key))
    }

    private var currentVersionLabel: String {
        guard let current = versions.first(where: \.isCurrent) else { return "Versiones" }
        return "v\(current.number) de \(versions.count)"
    }

    private func versionTitle(_ version: TranscriptVersion) -> String {
        "\(version.label) · \(version.backend) · \(version.createdAt.formatted(.dateTime.day().month().hour().minute()))"
    }

    private func choose(_ version: TranscriptVersion) {
        guard !version.isCurrent else { return }
        Task {
            do {
                try await model.choose(version: version.id, for: recording.key)
                await reload()
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func reload() async {
        do {
            transcript = try await model.transcript(for: recording.key)
            versions = try await model.versions(for: recording.key)
            trace = try await model.latestTrace(for: recording.key)
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    private func correct(_ change: @escaping () async throws -> Transcript) {
        Task {
            do {
                transcript = try await change()
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func renameCurrent() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let speaker = renameTarget, !name.isEmpty, name != speaker {
            correct {
                let baptism = try await model.baptize(speaker, as: name, in: recording.key)
                if baptism.learnedVoices == 0 { learningNotice = name }
                return baptism.transcript
            }
        }
        renameTarget = nil
    }

    private func speakerTitle(_ speaker: String, in transcript: Transcript) -> String {
        guard let recognition = transcript.recognition(of: speaker) else { return speaker }
        return "\(speaker) · reconocido (\(recognition.distance.formatted(.number.precision(.fractionLength(2)))))"
    }

    private func summarize() {
        Task {
            do {
                try await model.summarize(recording)
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func forgetSummary() {
        Task {
            do {
                try await model.forgetSummary(recording.key)
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func reprocess(_ choice: RecipeChoice = RecipeChoice()) {
        Task {
            do {
                try await model.reprocess(recording, with: choice)
                await reload()
            } catch {
                actionError = "\(error)"
            }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let failure {
                Text("No se pudo leer: \(failure)")
            } else if let transcript {
                summarySection
                NoteDataSection(data: recording.transcript?.data, schema: recording.transcript?.dataSchema)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcripción").font(.headline)
                    KaraokeView(
                        transcript: transcript,
                        position: transcript.position(at: player.currentTime),
                        onSeek: { player.seek(to: $0) })
                }
                if let trace { TraceCard(trace: trace) }
            } else {
                statusPlaceholder
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recording.displayTitle)
                .font(.title)
                .fontWeight(.semibold)
                .textSelection(.enabled)
            Text(details)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let tags = recording.digest?.tags, !tags.isEmpty {
                TagChips(tags: tags)
                    .padding(.top, 2)
            }
        }
    }

    private var details: String {
        let summary = recording.transcript
        let parts: [String?] = [
            longDate(recording.startedAt, timeZone: .current),
            originName,
            summary?.duration.map(clockStamp),
            summary.flatMap { $0.speakerCount > 1 ? "\($0.speakerCount) hablantes" : nil },
            summary.flatMap { $0.versionCount > 1 ? "versión \($0.version) de \($0.versionCount)" : nil },
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var summarySection: some View {
        if model.isSummarizing(recording.key) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Resumiendo…").foregroundStyle(.secondary)
            }
        } else if let digest = recording.digest {
            VStack(alignment: .leading, spacing: 8) {
                Text("Resumen").font(.headline)
                Text(digest.summary)
                    .textSelection(.enabled)
            }
        } else if model.canSummarize {
            Button("Resumir", systemImage: "sparkles", action: summarize)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var statusPlaceholder: some View {
        switch recording.status {
        case .pending:
            VStack(alignment: .leading, spacing: 12) {
                Label("En cola", systemImage: "clock")
                Text("Se transcribira automaticamente en la proxima pasada.")
                    .foregroundStyle(.secondary)
                Button("Transcribir ahora") { reprocess() }
                    .disabled(
                        model.reprocessing.contains(recording.key)
                            || recording.audio == .missing)
            }
        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribiendo…").foregroundStyle(.secondary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 12) {
                Label("Fallo la transcripcion", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if let error = recording.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Reintentar") { reprocess() }
                    .disabled(
                        model.reprocessing.contains(recording.key)
                            || recording.audio == .missing)
                if let trace { TraceCard(trace: trace) }
            }
        case .done, .discarded:
            Text("Sin transcripcion").foregroundStyle(.secondary)
        }
    }
}


private struct NoticeBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

private struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                Label("Suelta para transcribir", systemImage: "waveform.badge.plus")
                    .font(.title2)
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}
