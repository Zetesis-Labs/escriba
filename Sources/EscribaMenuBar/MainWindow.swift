import EscribaModel
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case library
    case connectors
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: "Biblioteca"
        case .connectors: "Conectores"
        case .settings: "Ajustes"
        }
    }

    static func initial(from environment: [String: String]) -> MainSection {
        environment["ESCRIBA_SECTION"].flatMap(MainSection.init(rawValue:)) ?? .library
    }

    static var selectsFirstItem: Bool {
        ProcessInfo.processInfo.environment["ESCRIBA_SELECT_FIRST"] == "1"
    }

    var symbol: String {
        switch self {
        case .library: "waveform"
        case .connectors: "square.and.arrow.up"
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
                    txtFolder: runtime.settings.txtFolder,
                    defaultOptions: runtime.settings.transcriptionDefaults)
            case .connectors:
                ConnectorsPane(connectors: runtime.connectors)
            case .settings:
                SettingsPane(settings: runtime.settings)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
    }
}
