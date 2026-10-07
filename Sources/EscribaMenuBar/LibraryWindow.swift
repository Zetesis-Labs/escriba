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
    let txtFolder: URL?
    let defaultOptions: TranscriptionOptions
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
                    RecordingRowView(recording: recording, origin: origin(recording))
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
                        origin: origin(recording),
                        connectors: connectors,
                        txtFolder: txtFolder,
                        defaultOptions: defaultOptions,
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
                    Button {
                        chooseAudio()
                    } label: {
                        Label("Añadir audio…", systemImage: "plus.rectangle.on.folder")
                    }
                    .help("Añadir ficheros de audio para transcribirlos")
                    ResolverChoiceButton(
                        choice: Bindable(inbox).choice, settings: settings, origin: settings.inboxResolvers,
                        help: "Con qué transcribir y resumir los próximos audios que añadas o arrastres")
                    if recorder.isRecording {
                        Button {
                            recorder.stop()
                        } label: {
                            Label("Detener", systemImage: "stop.circle.fill")
                        }
                        .help("Detener y transcribir")
                    } else {
                        Button {
                            Task { await recorder.start() }
                        } label: {
                            Label("Grabar", systemImage: "mic.circle")
                        }
                        .help("Grabar una nota de voz")
                        .disabled(recorder.state == .asking)
                    }
                    ResolverChoiceButton(
                        choice: Bindable(recorder).choice, settings: settings, origin: settings.inboxResolvers,
                        help: "Con qué transcribir y resumir la próxima grabación")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if recorder.isRecording { RecordingBar(recorder: recorder, settings: settings) }
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
            RowActionText.unpublish(from: connector.kind)
        }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = audioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Añadir"
        guard panel.runModal() == .OK else { return }
        inbox.add(panel.urls)
    }

    private func origin(_ recording: StoredRecording) -> WatchedFolder? {
        folder(for: recording.sourceURL.path(percentEncoded: false), among: folders)
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
                let kind = connector.kind.label
                if let publication = recording.publication(in: connector.key), publication.isPublished {
                    Menu(connector.name) {
                        if let page = publication.url {
                            switch connector.kind {
                            case .notion:
                                Button("Abrir en \(kind)") { NSWorkspace.shared.open(page) }
                            case .okf:
                                Button("Abrir el .md") { NSWorkspace.shared.open(page) }
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
    let origin: WatchedFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(recording.startedAt, format: .dateTime.day().month(.wide).hour().minute())
                Spacer(minLength: 4)
                StatusChip(status: recording.status)
            }
            summaryLine
            HStack(spacing: 10) {
                originTag
                transcriptTag
                audioTag
                notionTag
                Spacer(minLength: 4)
                Text(recording.key)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var originTag: some View {
        if let origin {
            tag(symbol(for: origin.style), text: origin.displayName, help: origin.path)
        }
    }

    private func symbol(for style: WatchedFolder.Style) -> String {
        switch style {
        case .justPressRecord: "record.circle"
        case .voiceMemos: "waveform"
        case .any: "folder"
        }
    }

    @ViewBuilder private var summaryLine: some View {
        if let digest = recording.digest {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(digest.title).lineLimit(1).truncationMode(.tail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(digest.summary)
        }
    }

    @ViewBuilder private var transcriptTag: some View {
        if let transcript = recording.transcript {
            if transcript.speakerCount > 0 {
                tag("person.2.fill", text: "\(transcript.speakerCount)",
                    help: "Diarizada con \(transcript.speakerCount) hablantes")
            } else if transcript.isSegmented {
                tag("text.word.spacing", help: "Transcrita con tiempos por palabra")
            } else {
                tag("text.alignleft", help: "Solo texto, sin tiempos (\(transcript.backend))")
            }
        }
    }

    @ViewBuilder private var audioTag: some View {
        switch recording.audio {
        case .libraryCopy:
            tag("internaldrive", help: "Audio guardado en la biblioteca")
        case .sourceOnly:
            tag("icloud", help: "Audio solo en la carpeta de origen, sin copia propia")
        case .missing:
            tag("speaker.slash", help: "Solo queda la transcripcion: no hay audio")
        }
    }

    @ViewBuilder private var notionTag: some View {
        let published = recording.publications.filter(\.isPublished)
        let failed = recording.publications.filter { $0.error != nil }
        if !published.isEmpty {
            tag(
                "square.and.arrow.up.badge.checkmark",
                text: published.count > 1 ? "\(published.count)" : nil,
                help: "Publicada en \(published.count) conector(es)")
        }
        if let problem = failed.first?.error {
            tag("square.and.arrow.up.trianglebadge.exclamationmark", help: "No se publicó: \(problem)")
        }
    }

    private func tag(_ symbol: String, text: String? = nil, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text).lineLimit(1).truncationMode(.tail) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

struct SummaryCard: View {
    let digest: Digest?
    let busy: Bool
    let canSummarize: Bool
    let onSummarize: () -> Void

    var body: some View {
        if busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Resumiendo…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let digest {
            VStack(alignment: .leading, spacing: 8) {
                Label(digest.title, systemImage: "sparkles")
                    .font(.headline)
                Text(digest.summary)
                    .textSelection(.enabled)
                if !digest.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(digest.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        } else if canSummarize {
            Button("Resumir con el modelo del sistema", systemImage: "sparkles", action: onSummarize)
                .buttonStyle(.bordered)
        }
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
    let origin: WatchedFolder?
    let connectors: [Connector]
    let txtFolder: URL?
    let defaultOptions: TranscriptionOptions
    let onAction: (RowAction) -> Void

    @State private var transcript: Transcript?
    @State private var versions: [TranscriptVersion] = []
    @State private var trace: RecipeTrace?
    @State private var reprocessOptions: TranscriptionOptions?
    @State private var failure: String?
    @State private var player = PlayerModel()
    @State private var renameTarget: String?
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
                    .padding()
            }
        }
        .navigationTitle(recording.headline)
        .navigationSubtitle(subtitle)
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
        .sheet(
            isPresented: Binding(
                get: { reprocessOptions != nil },
                set: { if !$0 { reprocessOptions = nil } })
        ) {
            ReprocessSheet(
                options: reprocessOptions ?? defaultOptions,
                resolvers: model.resolverChoice(for: recording),
                origin: settings.resolverChoice(
                    forSource: recording.sourceURL.path(percentEncoded: false),
                    inbox: Paths.inbox.path(percentEncoded: false)),
                settings: settings,
                onRun: { options, resolvers in
                    reprocessOptions = nil
                    reprocess(options, resolvers: resolvers)
                },
                onCancel: { reprocessOptions = nil })
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
            Button("Mostrar el .txt en el Finder") { reveal(txtTarget) }
                .disabled(txtTarget == .unavailable)
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

    private var txtTarget: RevealTarget {
        revealTarget(txtFolder: txtFolder, key: recording.key) {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    private func reveal(_ target: RevealTarget) {
        switch target {
        case .file(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .folder(let url): NSWorkspace.shared.open(url)
        case .unavailable: break
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
                        Menu(speaker) {
                            Button("Renombrar…") {
                                newName = speaker
                                renameTarget = speaker
                            }
                            ForEach(
                                transcript.speakers.filter { $0 != speaker }, id: \.self
                            ) { other in
                                Button("Fusionar con \(other)") {
                                    correct(transcript.merging([speaker], into: other))
                                }
                            }
                        }
                    }
                }
            }
            Button("Reprocesar con otros criterios…") { reprocessOptions = defaultOptions }
                .disabled(recording.audio == .missing)
        } label: {
            Label("Hablantes", systemImage: "person.2")
        }
        .disabled(model.reprocessing.contains(recording.key))
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
            Divider()
            Button("Reprocesar con otros criterios…") { reprocessOptions = defaultOptions }
                .disabled(recording.audio == .missing)
        } label: {
            Label(currentVersionLabel, systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .disabled(versions.isEmpty || model.reprocessing.contains(recording.key))
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

    private func correct(_ corrected: Transcript) {
        Task {
            do {
                try await model.applyCorrection(corrected, to: recording.key)
                transcript = corrected
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private func renameCurrent() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let renameTarget, let transcript, !name.isEmpty {
            correct(transcript.renaming(renameTarget, to: name))
        }
        renameTarget = nil
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

    private func reprocess(_ options: TranscriptionOptions, resolvers: ResolverChoice? = nil) {
        Task {
            do {
                try await model.reprocess(recording, options: options, resolvers: resolvers)
                await reload()
            } catch {
                actionError = "\(error)"
            }
        }
    }

    private var subtitle: String {
        let fecha = recording.startedAt.formatted(.dateTime.day().month(.wide).hour().minute())
        guard let origin else { return fecha }
        return "\(origin.displayName) · \(fecha)"
    }

    @ViewBuilder private var content: some View {
        if let failure {
            Text("No se pudo leer: \(failure)")
        } else if let transcript {
            VStack(alignment: .leading, spacing: 14) {
                SummaryCard(
                    digest: recording.digest,
                    busy: model.isSummarizing(recording.key),
                    canSummarize: model.canSummarize,
                    onSummarize: summarize)
                if let trace { TraceCard(trace: trace) }
                KaraokeView(
                    transcript: transcript,
                    position: transcript.position(at: player.currentTime),
                    onSeek: { player.seek(to: $0) })
            }
        } else {
            statusPlaceholder
        }
    }

    @ViewBuilder private var statusPlaceholder: some View {
        switch recording.status {
        case .pending:
            VStack(alignment: .leading, spacing: 12) {
                Label("En cola", systemImage: "clock")
                Text("Se transcribira automaticamente en la proxima pasada.")
                    .foregroundStyle(.secondary)
                Button("Transcribir ahora") { reprocess(defaultOptions) }
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
                Button("Reintentar") { reprocess(defaultOptions) }
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

private struct RecordingBar: View {
    @Bindable var recorder: RecorderModel
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text(recorder.clock)
                .font(.body.monospacedDigit())
            LevelMeter(level: recorder.level)
                .frame(width: 140, height: 6)
            Spacer()
            ResolverChoiceButton(
                choice: $recorder.choice, settings: settings, origin: settings.inboxResolvers,
                help: "Con qué se transcribe y se resume esta grabación")
                .labelStyle(.titleAndIcon)
                .fixedSize()
            Button("Descartar", role: .destructive) { recorder.cancel() }
            Button("Detener y transcribir") { recorder.stop() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * level)
                    .animation(.linear(duration: 0.1), value: level)
            }
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
