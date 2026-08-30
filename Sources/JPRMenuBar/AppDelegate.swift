import AppKit
import Foundation
import JPRCore
import JPRKit
import JPRStore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState()
    private var controller: DaemonController?
    private var instanceLock: InstanceLock?

    private let root = Paths.defaultRoot
    private let output = Paths.defaultOutput
    private let ledgerPath = Paths.defaultState
    private let library = Paths.defaultLibrary

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.mirrorToFile(Paths.logFile)
        Log.info("JPR Transcribe arrancando")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self
        refreshIcon()

        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: .jprStateChanged, object: nil)

        Notifier.requestAuthorization()
        startWatching()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    private func startWatching() {
        guard let lock = InstanceLock(path: Paths.lockFile) else {
            let holder = InstanceLock.holderDescription(path: Paths.lockFile)
            Log.error("ya hay \(holder) vigilando, esta copia no arranca")
            state.status = .problem("ya hay otra copia vigilando")
            refreshIcon()
            Notifier.problem(
                title: "JPR Transcribe ya esta abierto",
                detail: "Hay \(holder) vigilando. Esta copia no hara nada.")
            return
        }
        instanceLock = lock

        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            Log.error(
                "no encuentro \(root.path(percentEncoded: false)); si existe, falta el Acceso total al disco")
            state.status = .problem("no encuentro la carpeta de Just Press Record")
            refreshIcon()
            Notifier.problem(
                title: "Just Press Record no encontrado",
                detail: "No existe \(root.path(percentEncoded: false))")
            return
        }

        do {
            let backend = MacWhisperBackend.make()
            do {
                try backend.preflight()
            } catch {
                Log.error("\(error)")
                Notifier.problem(title: "Modelo de transcripcion no disponible", detail: "\(error)")
            }

            let ledger = try Ledger(path: ledgerPath)
            let store = try Store(root: library)
            let pipeline = Pipeline(
                source: justPressRecordSource(root: root),
                ledger: ledger,
                backend: backend,
                sink: sinks(
                    primary: sidecarTextSink(outputRoot: output),
                    also: store.sink(backend: backend.name)),
                onEvent: EventRouter.handler(for: state)
            )

            let controller = DaemonController(pipeline: pipeline)
            controller.start()
            self.controller = controller

            state.status = .watching
            refreshIcon()
        } catch {
            state.status = .problem("\(error)")
            refreshIcon()
            Notifier.problem(title: "No se pudo arrancar", detail: "\(error)")
        }
    }

    @objc private func stateChanged() {
        refreshIcon()
    }

    private func refreshIcon() {
        let status = state.status
        let image = NSImage(
            systemSymbolName: status.symbolName, accessibilityDescription: status.label)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Just Press Record · \(status.label)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        rebuild(menu)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        rebuild(menu)
        return menu
    }

    private func rebuild(_ menu: NSMenu) {
        let status = state.status
        let header = NSMenuItem(title: status.label, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let counts = try? Ledger(path: ledgerPath).counts(),
            let onDisk = (try? FileSystem.scan(root: root))?.count {
            let line = "\(onDisk) grabaciones · \(counts["done"] ?? 0) transcritas"
                + ((counts["failed"] ?? 0) > 0 ? " · \(counts["failed"]!) con fallo" : "")
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let recent = state.recent
        if !recent.isEmpty {
            menu.addItem(.separator())
            let title = NSMenuItem(title: "Últimas transcripciones", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            for summary in recent {
                let item = NSMenuItem(
                    title: "  \(summary.key.suffix(8))  \(summary.preview)",
                    action: #selector(openTranscript(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = summary.output
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        add(menu, "Buscar grabaciones ahora", #selector(transcribeNow))
        add(menu, "Abrir carpeta de transcripciones", #selector(openOutputFolder))
        add(menu, "Ver registro", #selector(openLog))
        menu.addItem(.separator())
        add(menu, "Salir", #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openTranscript(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func transcribeNow() {
        controller?.wake()
    }

    @objc private func openOutputFolder() {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSWorkspace.shared.open(output)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Paths.logFile)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
