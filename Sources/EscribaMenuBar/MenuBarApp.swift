import EscribaModel
import SwiftUI

@main
struct EscribaApp: App {
    @State private var runtime = AppRuntime()

    var body: some Scene {
        MenuBarExtra("Escriba", systemImage: runtime.symbolName) {
            MenuContent(runtime: runtime)
        }

        Window("Escriba", id: "main") {
            MainWindow(runtime: runtime)
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.automatic)
    }
}

struct MenuContent: View {
    let runtime: AppRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(runtime.statusLabel)

        if let model = runtime.model {
            Text("\(model.recordings.count) en la biblioteca")
            Divider()
            Button("Abrir biblioteca") { show(.library) }
            Button("Buscar grabaciones ahora") { runtime.wake() }
        }

        Button("Conectores…") { show(.connectors) }
        Button("Ajustes…") { show(.settings) }

        Divider()
        Button("Abrir carpeta de transcripciones") {
            NSWorkspace.shared.open(Paths.defaultOutput)
        }
        Button("Ver registro") { NSWorkspace.shared.open(Paths.logFile) }
        Divider()
        Button("Salir") { NSApp.terminate(nil) }
    }

    private func show(_ section: MainSection) {
        runtime.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}
