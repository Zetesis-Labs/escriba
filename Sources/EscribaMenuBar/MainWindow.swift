import EscribaCore
import EscribaModel
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case library
    case connectors
    case stt
    case llms
    case recipes
    case log
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: "Biblioteca"
        case .connectors: "Conectores"
        case .stt: "STT"
        case .llms: "LLMs"
        case .recipes: "Recetas"
        case .log: "Registro"
        case .settings: "Ajustes"
        }
    }

    static func initial(from environment: [String: String]) -> MainSection {
        environment["ESCRIBA_SECTION"].flatMap(MainSection.init(rawValue:)) ?? .library
    }

    static var selectsFirstItem: Bool {
        ProcessInfo.processInfo.environment["ESCRIBA_SELECT_FIRST"] == "1"
    }

    static var connectorToSelect: String? {
        ProcessInfo.processInfo.environment["ESCRIBA_SELECT_CONNECTOR"]
    }

    var symbol: String {
        switch self {
        case .library: "waveform"
        case .connectors: "square.and.arrow.up"
        case .stt: "waveform.badge.mic"
        case .llms: "sparkles"
        case .recipes: "curlybraces"
        case .log: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct MainWindow: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $runtime.section) { section in
                Label(section.label, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 200)
        } detail: {
            switch runtime.section {
            case .library:
                LibraryWindow(
                    model: runtime.model,
                    problem: runtime.startupProblem,
                    folders: runtime.settings.watchedFolders,
                    connectors: runtime.settings.connectors,
                    recipeListing: runtime.settings.recipeBook.listing(
                        code: (runtime.recipes.report?.recipes ?? []).filter { $0.active != nil }.map {
                            RecipeCodeEntry(key: $0.key, name: $0.name)
                        }),
                    recorder: runtime.recorder,
                    inbox: runtime.inbox,
                    settings: runtime.settings)
            case .connectors:
                ConnectorsPane(connectors: runtime.connectors)
            case .stt:
                ResolversPane(resolvers: runtime.stt, settings: runtime.settings)
            case .llms:
                ResolversPane(resolvers: runtime.llm, settings: runtime.settings)
            case .recipes:
                RecipesPane(settings: runtime.settings, recipes: runtime.recipes, library: runtime.model)
            case .log:
                LogPane(
                    library: runtime.model,
                    recipes: runtime.settings.recipeBook.listing(
                        code: (runtime.recipes.report?.recipes ?? []).map { RecipeCodeEntry(key: $0.key, name: $0.name) }))
            case .settings:
                SettingsPane(settings: runtime.settings)
            }
        }
        .environment(\.recipeForms, runtime.recipeForms)
        .frame(minWidth: 960, minHeight: 600)
    }
}
