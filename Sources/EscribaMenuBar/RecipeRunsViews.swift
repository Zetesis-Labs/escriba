import EscribaCore
import EscribaModel
import EscribaStore
import SwiftUI

struct RecipeRunsSection: View {
    let library: LibraryModel
    let recipe: String
    @State private var runs: RecipeRunsModel?
    @State private var outcome: RecipeRunOutcome?

    var body: some View {
        Section {
            OutcomePicker(outcome: $outcome)
            if let runs {
                if let problem = runs.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                } else if runs.runs.isEmpty {
                    Text(outcome == nil ? "Todavía no se ha ejecutado." : "Ninguna con ese resultado.")
                        .foregroundStyle(.secondary)
                }
                ForEach(runs.runs) { run in
                    RecipeRunRow(run: run, title: library.title(of: run.recordingKey), showsRecipe: false)
                }
            }
        } header: {
            Text("Ejecuciones")
        } footer: {
            Text("Las de los últimos 30 días, también cuando la llamó otra receta. Lo que escribe con console.log sale en cada una.")
        }
        .onAppear {
            let model = library.runs(RecipeRunFilter(recipe: recipe, outcome: outcome, limit: 30))
            model.start()
            runs = model
        }
        .onDisappear { runs?.stop() }
        .onChange(of: outcome) { _, value in runs?.filter.outcome = value }
    }
}

struct OutcomePicker: View {
    @Binding var outcome: RecipeRunOutcome?

    var body: some View {
        Picker("Resultado", selection: $outcome) {
            Text("Todas").tag(RecipeRunOutcome?.none)
            ForEach([RecipeRunOutcome.ok, .failed, .waiting], id: \.self) { value in
                Text(value.label).tag(RecipeRunOutcome?.some(value))
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

struct RecipeRunRow: View {
    let run: RecipeRunRecord
    let title: String
    let showsRecipe: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TraceDetail(trace: run.trace)
                .padding(.vertical, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: run.trace.outcome.symbol)
                    .foregroundStyle(run.trace.outcome == .ok ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let seconds = run.trace.seconds {
                    Text("\(seconds.formatted(.number.precision(.fractionLength(1)))) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var subtitle: String {
        let trigger = switch run.trigger {
        case .pipeline: "al entrar"
        case .reprocess: "reprocesada"
        case .test: "prueba"
        }
        let parts = [
            showsRecipe ? run.trace.name ?? run.trace.recipe : nil,
            trigger,
            run.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute().second()),
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

extension LibraryModel {
    func title(of key: String) -> String {
        recordings.first { $0.key == key }?.headline ?? key
    }
}

struct RecipeTestSection: View {
    let library: LibraryModel
    let recipe: String
    @State private var note: String?
    @State private var result: RecipeRunReport?

    var body: some View {
        Section {
            Picker("Nota", selection: $note) {
                Text("Elige una nota").tag(String?.none)
                ForEach(candidates) { recording in
                    Text("\(recording.headline) · \(recording.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                        .tag(String?.some(recording.key))
                }
            }
            HStack {
                Button(library.testing.contains(recipe) ? "Probando…" : "Probar") { run() }
                    .disabled(note == nil || library.testing.contains(recipe))
                if library.testing.contains(recipe) {
                    ProgressView().controlSize(.small)
                }
            }
            if let result {
                if let failure = result.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let trace = result.trace {
                    TraceDetail(trace: trace)
                }
            }
        } header: {
            Text("Probar con una nota")
        } footer: {
            Text("Ejecuta la receta sobre esa nota sin guardar versiones nuevas ni publicar: la traza dice qué habría publicado. Si la nota ya estaba transcrita con lo mismo, no vuelve a transcribir. Queda en sus ejecuciones como prueba.")
        }
    }

    private var candidates: [StoredRecording] {
        Array(library.recordings.filter { $0.audio != .missing }.prefix(50))
    }

    private func run() {
        guard let note, let recording = library.recordings.first(where: { $0.key == note }) else { return }
        result = nil
        Task { result = await library.test(recording, recipe: recipe) }
    }
}
