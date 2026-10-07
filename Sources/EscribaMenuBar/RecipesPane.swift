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
            Section("Integradas") {
                RecipeStatusRow(status: RecipeStatus(
                    key: RecipePackage.defaultRecipe.key, name: "Por defecto",
                    active: RecipePackage.defaultRecipe.fingerprint, activeSince: nil, issues: []))
                Text("Viene con Escriba y hace lo de siempre: transcribe, resume, guarda y publica en los conectores activos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
