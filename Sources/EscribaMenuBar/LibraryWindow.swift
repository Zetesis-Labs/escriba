import EscribaModel
import EscribaCore
import EscribaStore
import SwiftUI

private func librarySummary(_ model: LibraryModel) -> String {
    let sinTranscribir = model.recordings.count(where: { $0.status != .done })
    let total = "\(model.recordings.count) en la biblioteca"
    return sinTranscribir == 0 ? total : "\(total), \(sinTranscribir) sin transcribir"
}

struct LibraryWindow: View {
    let model: LibraryModel?
    let problem: String?

    @State private var selected: String?

    var body: some View {
        if let model {
            NavigationSplitView {
                List(model.recordings, selection: $selected) { recording in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.startedAt, format: .dateTime.day().month(.wide).hour().minute())
                            Text(recording.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        StatusBadge(status: recording.status)
                    }
                    .padding(.vertical, 2)
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            } detail: {
                if let selected,
                    let recording = model.recordings.first(where: { $0.key == selected }) {
                    TranscriptDetail(model: model, recording: recording)
                } else {
                    ContentUnavailableView(
                        "Elige una grabacion",
                        systemImage: "waveform",
                        description: Text(librarySummary(model)))
                }
            }
            .navigationTitle("Biblioteca")
        } else {
            ContentUnavailableView(
                "La biblioteca no esta disponible",
                systemImage: "waveform.badge.exclamationmark",
                description: Text(problem ?? "la app no pudo arrancar"))
        }
    }
}

struct TranscriptDetail: View {
    let model: LibraryModel
    let recording: StoredRecording

    @State private var transcript: Transcript?
    @State private var failure: String?
    @State private var player = PlayerModel()
    @State private var renameTarget: String?
    @State private var newName = ""
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            PlayerBar(player: player)
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
            player.load(recording.audioURL)
        }
        .onChange(of: recording.status) { reload() }
        .toolbar {
            if model.reprocessing.contains(recording.key) {
                ToolbarItem { ProgressView().controlSize(.small) }
            }
            ToolbarItem { speakersMenu }
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
                Button("Detectar hablantes") { reprocess(nil) }
                ForEach(2...4, id: \.self) { count in
                    Button("Con \(count) hablantes") { reprocess(count) }
                }
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
                    .disabled(model.reprocessing.contains(recording.key))
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
                    .disabled(model.reprocessing.contains(recording.key))
            }
        case .done:
            Text("Sin transcripcion").foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .help("Pendiente de transcribir")
        case .processing:
            ProgressView()
                .controlSize(.small)
                .help("Transcribiendo")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help("Fallo la transcripcion")
        case .done:
            EmptyView()
        }
    }
}
