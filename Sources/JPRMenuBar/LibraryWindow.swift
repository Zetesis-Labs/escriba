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
                if let selected {
                    TranscriptDetail(model: model, key: selected)
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
    let key: String

    @State private var transcript: Transcript?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            Text(content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(key)
        .task(id: key) {
            do {
                transcript = try model.transcript(for: key)
                failure = nil
            } catch {
                failure = "\(error)"
            }
        }
    }

    private var content: String {
        if let failure { return "No se pudo leer: \(failure)" }
        guard let transcript else { return "Sin transcripcion" }
        return transcript.rendered
    }
}
