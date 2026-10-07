import AppKit
import EscribaCore
import EscribaEngine
import EscribaModel
import EscribaStore
import SwiftUI

struct LogPane: View {
    let library: LibraryModel?
    let recipes: [RecipeListing]
    @State private var tab = Tab.runs

    enum Tab: Hashable {
        case runs
        case app
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Ver", selection: $tab) {
                Text("Ejecuciones de recetas").tag(Tab.runs)
                Text("Log de la app").tag(Tab.app)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            switch tab {
            case .runs:
                if let library {
                    RunsLog(library: library, recipes: recipes)
                } else {
                    ContentUnavailableView("La biblioteca no ha arrancado", systemImage: "exclamationmark.triangle")
                }
            case .app:
                AppLog()
            }
        }
        .navigationTitle("Registro")
    }
}

private struct RunsLog: View {
    let library: LibraryModel
    let recipes: [RecipeListing]
    @State private var runs: RecipeRunsModel?
    @State private var recipe: String?
    @State private var outcome: RecipeRunOutcome?
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Receta", selection: $recipe) {
                    Text("Todas").tag(String?.none)
                    ForEach(recipes) { recipe in
                        Text(recipe.name).tag(String?.some(recipe.key))
                    }
                }
                .frame(maxWidth: 220)
                OutcomePicker(outcome: $outcome)
                    .frame(maxWidth: 320)
                TextField("Buscar en la nota o en el log", text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(12)
            List {
                if let problem = runs?.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                ForEach(runs?.runs ?? []) { run in
                    RecipeRunRow(run: run, title: library.title(of: run.recordingKey), showsRecipe: true)
                }
            }
            .overlay {
                if runs?.runs.isEmpty == true {
                    ContentUnavailableView(
                        "Sin ejecuciones", systemImage: "list.bullet.rectangle",
                        description: Text("Aquí sale cada vez que una receta procesa una nota, de los últimos 30 días."))
                }
            }
        }
        .onAppear {
            let model = library.runs(filter)
            model.start()
            runs = model
        }
        .onDisappear { runs?.stop() }
        .onChange(of: filter) { _, value in runs?.filter = value }
    }

    private var filter: RecipeRunFilter {
        RecipeRunFilter(recipe: recipe, outcome: outcome, text: text, limit: 300)
    }
}

private struct AppLog: View {
    @State private var model = AppLogModel(url: Paths.logFile)
    @State private var text = ""
    @State private var onlyErrors = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filtrar", text: $text)
                    .textFieldStyle(.roundedBorder)
                Toggle("Solo errores", isOn: $onlyErrors)
                Button("Abrir el fichero") { NSWorkspace.shared.open(Paths.logFile) }
            }
            .padding(12)
            if let problem = model.problem {
                Text(problem).foregroundStyle(.orange).padding(.horizontal, 12)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
                            AppLogRow(line: line).id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: visible.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var visible: [LogEntry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        return model.lines.filter { line in
            (!onlyErrors || line.level == .error)
                && (query.isEmpty || line.message.localizedCaseInsensitiveContains(query))
        }
    }
}

private struct AppLogRow: View {
    let line: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let time = line.time {
                Text(time).foregroundStyle(.tertiary)
            }
            Text(line.message)
                .foregroundStyle(line.level == .error ? Color.red : line.level == .debug ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .font(.caption.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
