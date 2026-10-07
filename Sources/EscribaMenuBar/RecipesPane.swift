import AppKit
import EscribaCore
import EscribaEngine
import EscribaJSC
import EscribaModel
import SwiftUI

struct RecipesPane: View {
    @Bindable var settings: AppSettings
    let recipes: RecipeProjectModel

    var body: some View {
        Form {
            Section("Receta por defecto") {
                RecipeStatusRow(status: RecipeStatus(
                    key: RecipePackage.defaultRecipe.key, name: "Por defecto",
                    active: RecipePackage.defaultRecipe.fingerprint, activeSince: nil, issues: []))
                Text("Procesa todas las notas. Se configura aquí y funciona por interfaz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DefaultRecipeForm(settings: settings)
            }
            Section("Proyecto") {
                LabeledContent("Carpeta") {
                    HStack {
                        Text(settings.recipesFolderPath.map(abbreviated) ?? "Ninguno")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(settings.recipesFolderPath == nil ? "Crear o elegir…" : "Cambiar…") { choose() }
                        if let path = settings.recipesFolderPath {
                            Button("Abrir en el Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        }
                    }
                }
                Text("Una carpeta normal y tuya: puedes versionarla con git y abrirla en tu editor o con un agente. Si no tiene proyecto, Escriba crea la plantilla una sola vez; después no vuelve a escribir en ella salvo .escriba/estado.json.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                phase
            }
            if let report = recipes.report, !report.recipes.isEmpty {
                Section("Recetas del proyecto") {
                    ForEach(report.recipes, id: \.key) { status in
                        RecipeStatusRow(status: status)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recetas")
    }

    @ViewBuilder private var phase: some View {
        switch recipes.phase {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparando el compilador de recetas (14 MB, solo la primera vez)…").foregroundStyle(.secondary)
            }
        case .building:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Compilando…").foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        case .idle, .ready:
            EmptyView()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Paths.documents
        panel.prompt = "Usar esta carpeta"
        panel.message = "Elige una carpeta vacía para crear el proyecto de recetas, o una que ya lo tenga."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.recipesFolderPath = url.path(percentEncoded: false)
        Task { await recipes.open(url) }
    }
}

private struct RecipeStatusRow: View {
    let status: RecipeStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(status.issues.isEmpty ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.name ?? status.key)
                    Text(status.key).font(.caption).foregroundStyle(.secondary)
                }
                Text(recipeStatusLine(status))
                    .font(.caption)
                    .foregroundStyle(status.issues.isEmpty ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct DefaultRecipeForm: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker("Transcribe con", selection: $settings.defaultRecipe.stt) {
            ForEach(settings.sttResolvers.resolvers) { resolver in
                Text(resolver.name).tag(resolver.recipeKey(role: .stt))
            }
        }
        Picker("Idioma", selection: $settings.defaultRecipe.language) {
            Text("Español").tag(String?.some("es"))
            Text("English").tag(String?.some("en"))
            Text("Detectar en cada nota").tag(String?.none)
        }
        Picker("Hablantes", selection: speakers) {
            Text("No detectar").tag(-1)
            Text("Detectar").tag(0)
            ForEach(2...6, id: \.self) { count in
                Text("\(count) hablantes").tag(count)
            }
        }
        if let problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Toggle("Resumir", isOn: $settings.defaultRecipe.summarize)
        if settings.defaultRecipe.summarize {
            Picker("Resume con", selection: $settings.defaultRecipe.llm) {
                ForEach(settings.llmResolvers.resolvers) { resolver in
                    Text(resolver.name).tag(resolver.recipeKey(role: .llm))
                }
            }
            TextField("Prompt", text: prompt, prompt: Text("El de serie"), axis: .vertical)
                .lineLimit(3...8)
        }
        LabeledContent("Publica en") {
            VStack(alignment: .trailing, spacing: 4) {
                if settings.connectors.isEmpty {
                    Text("No hay conectores").foregroundStyle(.secondary)
                }
                ForEach(settings.connectors) { connector in
                    Toggle(connector.isLive ? connector.name : "\(connector.name) (apagado)", isOn: publishes(connector.key))
                }
            }
        }
    }

    private var speakers: Binding<Int> {
        Binding(
            get: {
                let recipe = settings.defaultRecipe
                return recipe.detectSpeakers ? recipe.speakerCount ?? 0 : -1
            },
            set: { value in
                settings.defaultRecipe.detectSpeakers = value >= 0
                settings.defaultRecipe.speakerCount = value > 0 ? value : nil
            })
    }

    private var prompt: Binding<String> {
        Binding(
            get: { settings.defaultRecipe.prompt ?? "" },
            set: { settings.defaultRecipe.prompt = $0.isEmpty ? nil : $0 })
    }

    private func publishes(_ key: String) -> Binding<Bool> {
        Binding(
            get: { settings.defaultRecipe.connectors.contains(key) },
            set: { on in
                settings.defaultRecipe.connectors.removeAll { $0 == key }
                if on { settings.defaultRecipe.connectors.append(key) }
            })
    }

    private var problem: String? {
        let recipe = settings.defaultRecipe
        let stt = settings.sttResolvers.resolvers.first { $0.recipeKey(role: .stt) == recipe.stt }
        return transcriptionProblem(
            isLocal: stt?.kind != .remote,
            options: TranscriptionOptions(language: recipe.language, diarize: recipe.detectSpeakers))
    }
}
