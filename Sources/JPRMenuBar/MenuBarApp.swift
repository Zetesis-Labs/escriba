import JPRApp
import SwiftUI

@main
struct JPRTranscribeApp: App {
    @State private var runtime = AppRuntime()

    var body: some Scene {
        MenuBarExtra("JPR Transcribe", systemImage: runtime.symbolName) {
            MenuContent(runtime: runtime)
        }

        Window("Biblioteca", id: "library") {
            LibraryWindow(model: runtime.model, problem: runtime.startupProblem)
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuContent: View {
    let runtime: AppRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(runtime.statusLabel)

        if let model = runtime.model {
            Text("\(model.scanned) grabaciones en disco · \(model.recordings.count) en la biblioteca")
            Divider()
            Button("Abrir biblioteca") {
                openWindow(id: "library")
                NSApp.activate()
            }
            Button("Buscar grabaciones ahora") { runtime.wake() }
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
