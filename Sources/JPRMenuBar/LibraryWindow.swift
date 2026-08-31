import JPRApp
import JPRCore
import JPRStore
import SwiftUI

struct LibraryWindow: View {
    let model: LibraryModel?
    let problem: String?

    @State private var selected: String?

    var body: some View {
        if let model {
            NavigationSplitView {
                List(model.recordings, selection: $selected) { recording in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.startedAt, format: .dateTime.day().month(.wide).hour().minute())
                        Text(recording.key)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        description: Text("\(model.recordings.count) en la biblioteca"))
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
            do {
                transcript = try model.transcript(for: recording.key)
                failure = nil
            } catch {
                failure = "\(error)"
            }
            player.load(recording.audioURL)
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
            Text("Sin transcripcion").foregroundStyle(.secondary)
        }
    }
}
