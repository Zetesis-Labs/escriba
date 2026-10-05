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
        .commands {
            CommandGroup(replacing: .newItem) {
                if runtime.recorder.isRecording {
                    Button("Detener y transcribir") { runtime.recorder.stop() }
                        .keyboardShortcut("n")
                } else {
                    Button("Nueva grabación") { Task { await runtime.recorder.start() } }
                        .keyboardShortcut("n")
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Salir de Escriba") { quit(runtime) }
                    .keyboardShortcut("q")
            }
        }
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
            if runtime.recorder.isRecording {
                Button("Detener y transcribir (\(runtime.recorder.clock))") { runtime.recorder.stop() }
                Button("Descartar la grabación") { runtime.recorder.cancel() }
            } else {
                Button("Grabar nota") {
                    Task { await runtime.recorder.start() }
                }
            }
            if let problem = runtime.recorder.problem {
                Text(problem)
                Button("Entendido") { runtime.recorder.dismissProblem() }
            }
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
        Button("Salir") { quit(runtime) }
    }

    private func show(_ section: MainSection) {
        runtime.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}

@MainActor
private func quit(_ runtime: AppRuntime) {
    runtime.recorder.prepareForQuit()
    NSApp.terminate(nil)
}
