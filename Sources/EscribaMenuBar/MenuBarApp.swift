import EscribaModel
import SwiftUI

@main
struct EscribaApp: App {
    @State private var runtime = AppRuntime()

    var body: some Scene {
        MenuBarExtra("Escriba", systemImage: runtime.symbolName) {
            MenuContent(runtime: runtime)
        }

        Window("Biblioteca", id: "library") {
            LibraryWindow(model: runtime.model, problem: runtime.startupProblem)
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(settings: runtime.settings)
        }
    }
}

struct MenuContent: View {
    let runtime: AppRuntime
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(runtime.statusLabel)

        if let model = runtime.model {
            Text("\(model.recordings.count) en la biblioteca")
            Divider()
            Button("Abrir biblioteca") {
                openWindow(id: "library")
                NSApp.activate()
            }
            Button("Buscar grabaciones ahora") { runtime.wake() }
        }

        Button("Ajustes…") {
            openSettings()
            NSApp.activate()
        }

        Divider()
        Button("Abrir carpeta de transcripciones") {
            NSWorkspace.shared.open(Paths.defaultOutput)
        }
        Button("Ver registro") { NSWorkspace.shared.open(Paths.logFile) }
        Divider()
        Button("Salir") { NSApp.terminate(nil) }
    }
}
