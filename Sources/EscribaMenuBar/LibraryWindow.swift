import EscribaModel
import EscribaCore
import EscribaStore
import SwiftUI

enum RowAction: Identifiable {
    case removeAudio(StoredRecording)
    case discard(StoredRecording)

    var id: String {
        switch self {
        case .removeAudio(let recording): "quitar-\(recording.key)"
        case .discard(let recording): "borrar-\(recording.key)"
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

    @State private var selected: String?
    @State private var pendingAction: RowAction?
    @State private var actionError: String?

    var body: some View {
        if let model {
            ListDetailLayout {
                List(model.recordings, selection: $selected) { recording in
                    RecordingRowView(recording: recording, origin: origin(recording))
                        .contextMenu {
                            PublishMenu(model: model, recording: recording, connectors: connectors) {
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
                        description: Text(librarySummary(of: model.recordings.map(\.status))))
                }
            }
            .navigationTitle("Biblioteca")
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
        }
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
    let onError: (String) -> Void

    var body: some View {
        let live = connectors.filter { model.canPublish(to: $0.key) }
        if !live.isEmpty {
            ForEach(live) { connector in
                let publication = recording.publication(in: connector.key)
                Button(
                    publication?.isPublished == true
                        ? "Actualizar en \(connector.name)" : "Publicar en \(connector.name)"
                ) {
                    Task {
                        do {
                            try await model.publish(recording, to: connector.key)
                        } catch {
                            onError("\(error)")
                        }
                    }
                }
                .disabled(model.isPublishing(recording.key, to: connector.key))
                if let page = publication?.url {
                    Button("Abrir en \(connector.name)") { NSWorkspace.shared.open(page) }
                }
            }
            Divider()
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
    let recording: StoredRecording
    let origin: WatchedFolder?
    let connectors: [Connector]
    let txtFolder: URL?
    let defaultOptions: TranscriptionOptions
    let onAction: (RowAction) -> Void

    @State private var transcript: Transcript?
    @State private var versions: [TranscriptVersion] = []
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
        .navigationTitle(recording.title)
        .navigationSubtitle(subtitle)
        .task(id: recording.key) {
            await reload()
            if recording.audio != .missing { player.load(recording.audioURL) }
        }
        .onChange(of: recording.status) { Task { await reload() } }
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
                onRun: { options in
                    reprocessOptions = nil
                    reprocess(options)
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
            Button("Copiar el JSON") { copyJSON() }
                .disabled(transcript == nil)
            Divider()
            PublishMenu(model: model, recording: recording, connectors: connectors) {
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

    private func reprocess(_ options: TranscriptionOptions) {
        Task {
            do {
                try await model.reprocess(recording, options: options)
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
            KaraokeView(
                transcript: transcript,
                position: transcript.position(at: player.currentTime),
                onSeek: { player.seek(to: $0) })
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
            }
        case .done, .discarded:
            Text("Sin transcripcion").foregroundStyle(.secondary)
        }
    }
}
