import EscribaModel
import EscribaCore
import EscribaStore
import SwiftUI

private func librarySummary(_ model: LibraryModel) -> String {
    let sinTranscribir = model.recordings.count(where: { $0.status != .done })
    let total = "\(model.recordings.count) en la biblioteca"
    return sinTranscribir == 0 ? total : "\(total), \(sinTranscribir) sin transcribir"
}

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

    @State private var selected: String?
    @State private var pendingAction: RowAction?
    @State private var actionError: String?

    var body: some View {
        if let model {
            NavigationSplitView {
                List(model.recordings, selection: $selected) { recording in
                    RecordingRowView(recording: recording)
                        .contextMenu {
                            Button("Quitar la copia de audio…") {
                                pendingAction = .removeAudio(recording)
                            }
                            .disabled(recording.audio != .libraryCopy)
                            Button("Borrar de la biblioteca…", role: .destructive) {
                                pendingAction = .discard(recording)
                            }
                        }
                }
                .navigationSplitViewColumnWidth(min: 240, ideal: 290)
            } detail: {
                if let selected,
                    let recording = model.recordings.first(where: { $0.key == selected }) {
                    TranscriptDetail(
                        model: model,
                        recording: recording,
                        onAction: { pendingAction = $0 })
                } else {
                    ContentUnavailableView(
                        "Elige una grabacion",
                        systemImage: "waveform",
                        description: Text(librarySummary(model)))
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
                perform { try model.removeAudio(recording.key) }
            }
        case .discard(let recording):
            Button("Borrar grabacion y transcripciones", role: .destructive) {
                perform { try model.discard(recording.key) }
                if selected == recording.key { selected = nil }
            }
        }
        Button("Cancelar", role: .cancel) {}
    }

    private func dialogMessage(_ action: RowAction) -> String {
        switch action {
        case .removeAudio(let recording):
            FileManager.default.fileExists(
                atPath: recording.sourceURL.path(percentEncoded: false))
                ? "Se borra la copia de la biblioteca; el original en su carpeta se conserva y las transcripciones se quedan."
                : "El original ya no existe: sin la copia, el audio se pierde del todo. Las transcripciones se quedan."
        case .discard:
            "Desaparecen la fila, sus transcripciones y la copia de audio. El fichero original en su carpeta no se toca, pero la grabacion no volvera a aparecer en la biblioteca."
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            actionError = "\(error)"
        }
    }
}

struct RecordingRowView: View {
    let recording: StoredRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(recording.startedAt, format: .dateTime.day().month(.wide).hour().minute())
                Spacer(minLength: 4)
                StatusChip(status: recording.status)
            }
            HStack(spacing: 10) {
                transcriptTag
                audioTag
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

    private func tag(_ symbol: String, text: String? = nil, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text) }
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
    let onAction: (RowAction) -> Void

    @State private var transcript: Transcript?
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
        .navigationTitle(recording.key)
        .task(id: recording.key) {
            reload()
            if recording.audio != .missing { player.load(recording.audioURL) }
        }
        .onChange(of: recording.status) { reload() }
        .toolbar {
            if model.reprocessing.contains(recording.key) {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
            ToolbarItem { speakersMenu }
            ToolbarItem { actionsMenu }
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
            Section("Reprocesar") {
                Group {
                    Button("Detectar hablantes") { reprocess(nil) }
                    ForEach(2...4, id: \.self) { count in
                        Button("Con \(count) hablantes") { reprocess(count) }
                    }
                }
                .disabled(recording.audio == .missing)
            }
        } label: {
            Label("Hablantes", systemImage: "person.2")
        }
        .disabled(model.reprocessing.contains(recording.key))
    }

    private func reload() {
        do {
            transcript = try model.transcript(for: recording.key)
            failure = nil
        } catch {
            failure = "\(error)"
        }
    }

    private func correct(_ corrected: Transcript) {
        do {
            try model.applyCorrection(corrected, to: recording.key)
            transcript = corrected
        } catch {
            actionError = "\(error)"
        }
    }

    private func renameCurrent() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let renameTarget, let transcript, !name.isEmpty {
            correct(transcript.renaming(renameTarget, to: name))
        }
        renameTarget = nil
    }

    private func reprocess(_ speakers: Int?) {
        Task {
            do {
                try await model.reprocess(recording, speakers: speakers)
                reload()
            } catch {
                actionError = "\(error)"
            }
        }
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
                Button("Transcribir ahora") { reprocess(nil) }
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
                Button("Reintentar") { reprocess(nil) }
                    .disabled(
                        model.reprocessing.contains(recording.key)
                            || recording.audio == .missing)
            }
        case .done, .discarded:
            Text("Sin transcripcion").foregroundStyle(.secondary)
        }
    }
}
