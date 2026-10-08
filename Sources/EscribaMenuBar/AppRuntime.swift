import Foundation
import AppKit
import EscribaModel
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import EscribaIntelligence
import EscribaJSC
import EscribaOpenAI
import EscribaStore
import EscribaWhisper
import Observation
import Synchronization

private func recipeDigester(_ llm: Resolver, prompt: String?, language: String?) -> Digester {
    { _, transcript in
        try await summarizer(for: llm).prompted(prompt).digest(of: transcript.rendered, language: language)
    }
}

nonisolated private final class Shared<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private let inboxPrefix = "Escriba"

private func keepRecordingAwake() -> () -> Void {
    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled], reason: "Grabando una nota de voz")
    return { ProcessInfo.processInfo.endActivity(activity) }
}

private final class WakeRelay {
    var wake: () -> Void = {}
}

private func fingerprint(of connectors: [Connector]) -> String {
    connectors.map { "\($0)" }.joined(separator: ";")
}

@Observable
final class AppRuntime {
    private(set) var model: LibraryModel?
    private(set) var people: PeopleModel?
    private(set) var recipeForms: RecipeForms?
    private(set) var startupProblem: String?
    var section = MainSection.initial(from: ProcessInfo.processInfo.environment)
    let settings: AppSettings
    let connectors: ConnectorsModel
    let stt: ResolversModel
    let llm: ResolversModel
    let recorder: RecorderModel
    let inbox: InboxModel
    let recipes: RecipeProjectModel

    @ObservationIgnored private var controllers: [DaemonController] = []
    @ObservationIgnored private var instanceLock: InstanceLock?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var settingsWatch: Task<Void, Never>?
    @ObservationIgnored private var recipeBookWatch: Task<Void, Never>?
    @ObservationIgnored private let microphone: MicrophoneRecorder
    @ObservationIgnored private let sampleMicrophone = MicrophoneRecorder()
    @ObservationIgnored private var recordingItem: RecordingStatusItem?
    @ObservationIgnored private var recordingPanel: RecordingPanel?
    @ObservationIgnored private let recipeBook: Shared<RecipeBook>
    @ObservationIgnored private let connectorArchive: ConnectorArchive
    @ObservationIgnored private let connectorServices: ConnectorServices
    @ObservationIgnored private var connectorPublications: ConnectorPublications?

    var recipeListing: [RecipeListing] {
        settings.recipeBook.listing(
            code: (recipes.report?.recipes ?? []).filter { $0.active != nil }.map {
                RecipeCodeEntry(key: $0.key, name: $0.name)
            })
    }

    var symbolName: String {
        if recorder.isRecording { return "record.circle" }
        return model?.status.symbolName ?? WatcherStatus.problem("").symbolName
    }

    var statusLabel: String {
        if let startupProblem { return "Problema: \(startupProblem)" }
        return model?.status.label ?? WatcherStatus.starting.label
    }

    init() {
        let rotation = Result { try rotateLog(at: Paths.logFile, maxBytes: 5 * 1024 * 1024) }
        Log.mirrorToFile(Paths.logFile)
        Log.info("Escriba arrancando")
        if case .failure(let error) = rotation { Log.error("no se pudo rotar el log: \(error)") }
        if let isolated = Paths.isolatedRoot {
            settings = AppSettings(defaults: UserDefaults(suiteName: "dev.escriba.preview." + connectorFingerprint(isolated.path))!,
                recorderRoot: nil, voiceMemos: nil)
        } else {
            LegacyMigration.run()
            AppSettings.adoptLegacyDefaults(from: UserDefaults(suiteName: "dev.ruben.jpr-transcribe"))
            settings = AppSettings()
        }
        recipeBook = Shared(settings.recipeBook)
        let bundled = Result { try BundledConnectors.program() }
        let archive = ConnectorArchive(directory: Paths.applicationSupport.appending(path: "conectores"))
        connectorArchive = archive
        let services = EscribaMenuBar.connectorServices(program: bundled)
        connectorServices = services
        connectors = ConnectorsModel(settings: settings, tokens: { appTokenStore(account: $0.uuidString) }, services: services)
        stt = ResolversModel(role: .stt, settings: settings, services: resolverServices())
        llm = ResolversModel(role: .llm, settings: settings, services: resolverServices())
        let relay = WakeRelay()
        let box = fileInbox(root: Paths.inbox)
        let microphone = MicrophoneRecorder()
        self.microphone = microphone
        recorder = RecorderModel(
            recorder: microphone.port(), inbox: box, wake: { relay.wake() },
            keepAwake: keepRecordingAwake)
        inbox = InboxModel(inbox: box, wake: { relay.wake() })
        recipes = recipeProjectModel(connectors: connectors, archive: archive)
        relay.wake = { [weak self] in self?.wake() }
        recordingItem = RecordingStatusItem(recorder: recorder)
        recordingPanel = RecordingPanel(recorder: recorder) { [weak self] key in
            self?.recipeListing.first { $0.key == key }?.name ?? key
        }
        if Paths.isolatedRoot == nil { Notifier.requestAuthorization() }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await archive.retain(bundled.get())
                try await connectors.initialize()
                if let path = settings.recipesFolderPath { await recipes.open(URL(fileURLWithPath: path)) }
                start()
                watchSettings()
            } catch {
                startupProblem = "No se pudieron preparar los conectores: \(error.localizedDescription)"
                Log.error(startupProblem ?? "Error de conectores")
            }
        }
    }

    func wake() {
        controllers.forEach { $0.wake() }
    }

    private func start() {
        guard let lock = InstanceLock(path: Paths.lockFile) else {
            let holder = InstanceLock.holderDescription(path: Paths.lockFile)
            Log.error("ya hay \(holder) vigilando, esta copia no arranca")
            startupProblem = "ya hay otra copia vigilando"
            Notifier.problem(
                title: "Escriba ya esta abierto",
                detail: "Hay \(holder) vigilando. Esta copia no hara nada.")
            return
        }
        instanceLock = consume lock
        build()
    }

    private func rebuild() {
        Log.info("ajustes cambiados, reconstruyendo pipelines")
        startupProblem = nil
        build()
    }

    private func build() {
        stopPipelines()

        do {
            let store = try Store(root: Paths.defaultLibrary)
            let (stts, llms) = (settings.sttResolvers, settings.llmResolvers)
            let engine = WhisperKitEngine(language: nil)
            let book = recipeBook
            let formReading: @Sendable () -> FormRecipeReading = {
                let current = book.value
                return current.reading(of: current.defaultKey)
            }

            let unchosen = TranscriptionOptions(language: nil, diarize: false)
            let backend = recipeTranscriber(stts.local, options: unchosen, engine: engine)
            let enrich = enricher(summarizer(for: llms.local), language: nil)
            if connectorPublications == nil {
                connectorPublications = ConnectorPublications(store: store, archive: connectorArchive,
                    runtime: try javaScriptCoreConnectorRuntime(),
                    authority: { [settings] id in
                        await MainActor.run {
                            settings.connectorAccounts.first { $0.id.uuidString == id }.map(connectorPermission)
                        }
                    }, credentials: { appTokenStore(account: $0).read() })
            }
            let publishers = publishers(for: store)
            let installed = Paths.installedRecipes
            let recipe = recipeRuntime().map { runtime in
                Recipe(
                    shelf: recipeShelf(
                        book: { book.value }, installed: { try readInstalledRecipes(at: installed) },
                        formPackage: .defaultRecipe),
                    runtime: runtime, publishers: publishers,
                    catalog: recipeCatalog(
                        stts: stts, llms: llms,
                        connectors: settings.connectors.map {
                            recipeConnector($0, isActive: $0.isLive && publishers[$0.key] != nil)
                        },
                        unchosen: unchosen, engine: engine,
                        origin: { [folders = settings.watchedFolders, inbox = Paths.inbox.path(percentEncoded: false)] in
                            recipeOrigin(forSource: $0.url.path(percentEncoded: false), inbox: inbox, folders: folders)
                        }))
            }
            recipeForms = recipe.map(RecipeForms.init)
            let memory = store.memory()
            let saveSink = saveSink(for: store)

            let ledger = try Ledger(path: Paths.defaultState)
            let model = LibraryModel(
                store: store,
                reprocess: { stored, choice, dryRun in
                    await reprocessed(
                        stored, choice, recipe: recipe, backend: backend, enrich: enrich, memory: memory,
                        save: saveSink, dryRun: dryRun)
                },
                digester: { recording, transcript in
                    let form = formReading()
                    return try await recipeDigester(
                        recipeResolver(llms, key: form.llm ?? ""), prompt: form.prompt, language: form.language
                    )(recording, transcript)
                },
                publishers: publishers,
                unpublishers: unpublishers(),
                discarded: { key, source in try ledger.markDiscarded(key: key, source: source) })
            model.startObserving()
            self.model = model
            let people = PeopleModel(
                store: store, recorder: sampleMicrophone.port(),
                printer: { try await engine.diarizedVoices(of: $0) })
            do {
                try people.reload()
            } catch {
                Log.error("no se pudieron leer las personas: \(error)")
            }
            self.people = people

            let form = formReading()
            warnAboutUnusable(
                stt: recipeResolver(stts, key: form.stt ?? ""), llm: recipeResolver(llms, key: form.llm ?? ""),
                summarizes: form.summarize)

            let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
            events = Task { [settings] in
                for await event in stream {
                    await model.apply(event)
                    if settings.notifyEveryNote || event.isProblem {
                        Notifier.notify(event)
                    }
                }
            }

            reconcileLibrary(store: store, ledger: ledger)
            controllers = sources().map { source in
                let pipeline = Pipeline(
                    source: source,
                    ledger: ledger,
                    backend: backend,
                    sink: recipe == nil ? sink(for: store) : saveSink,
                    enrich: enrich,
                    memory: memory,
                    recipe: recipe,
                    onEvent: { continuation.yield($0) }
                )
                let controller = DaemonController(pipeline: pipeline)
                controller.start()
                return controller
            }
            if controllers.isEmpty {
                Log.error("ninguna carpeta vigilada disponible")
                model.status = .problem("ninguna carpeta vigilada disponible")
            } else {
                model.status = .watching
            }
        } catch {
            Log.error("no se pudo arrancar el pipeline: \(error)")
            startupProblem = "\(error)"
            Notifier.problem(title: "No se pudo arrancar", detail: "\(error)")
        }

        func sources() -> [RecordingSource] {
            var result: [RecordingSource] = []
            var prefixes: Set<String> = [inboxPrefix]

            do {
                try FileManager.default.createDirectory(at: Paths.inbox, withIntermediateDirectories: true)
                result.append(namespaced(
                    folderSource(name: inboxPrefix, root: Paths.inbox, chosenRecipe: fileInbox(root: Paths.inbox).recipe),
                    prefix: inboxPrefix))
            } catch {
                Log.error("no se pudo preparar la bandeja de Escriba: \(error)")
            }

            for folder in settings.watchedFolders {
                let folderRoot = URL(fileURLWithPath: folder.path)
                if let problem = FileSystem.accessProblem(root: folderRoot) {
                    Log.error("\(problem)")
                    Notifier.problem(title: "Carpeta vigilada inaccesible", detail: folder.path)
                    continue
                }

                switch folder.style {
                case .justPressRecord:
                    result.append(justPressRecordSource(root: folderRoot))
                    continue
                case .voiceMemos:
                    result.append(namespaced(voiceMemosSource(root: folderRoot, expectedSpeakers: nil), prefix: "Notas de Voz"))
                    continue
                case .any:
                    break
                }

                var prefix = folderRoot.lastPathComponent
                var counter = 2
                while !prefixes.insert(prefix).inserted {
                    prefix = "\(folderRoot.lastPathComponent)-\(counter)"
                    counter += 1
                }
                result.append(namespaced(
                    folderSource(name: prefix, root: folderRoot, expectedSpeakers: nil), prefix: prefix))
            }
            return result
        }
    }

    private func warnAboutUnusable(stt: Resolver, llm: Resolver, summarizes: Bool) {
        let sttProblem = stt.kind == .local ? localResolverProblem(.stt) : resolverProblem(stt, localProblem: nil)
        if let sttProblem {
            Log.error("no se puede transcribir con \(stt.name): \(sttProblem)")
            Notifier.problem(title: "No se puede transcribir con \(stt.name)", detail: sttProblem)
        }
        guard summarizes, let llmProblem = summarizer(for: llm).availability().problem
        else { return }
        Log.error("la receta por defecto resume pero \(llm.name): \(llmProblem)")
        Notifier.problem(
            title: "No se puede resumir con \(llm.name)",
            detail: "\(llmProblem). Las notas se transcribiran igual.")
    }

    private func reconcileLibrary(store: Store, ledger: Ledger) {
        Task {
            await offloaded {
                do {
                    try store.resetInterrupted()
                    store.adoptLedgerHistory(try ledger.doneRecords())
                    for recording in try store.discardedRecordings() {
                        try ledger.markDiscarded(key: recording.key, source: recording.sourceURL)
                    }
                } catch {
                    Log.error("no se pudo reconciliar la biblioteca con el ledger: \(error)")
                }
            }
        }
    }

    private func recipeRuntime() -> RecipeRuntime? {
        do {
            let runtime = try javaScriptCoreRuntime()
            let book = recipeBook.value
            let name = book.form(book.defaultKey)?.name ?? book.defaultKey
            Log.info("recetas en \(runtime.name); la por defecto es «\(name)», formulario \(RecipePackage.defaultRecipe.fingerprint)")
            return runtime
        } catch {
            Log.error("las recetas no arrancan, se procesa sin receta: \(error)")
            Notifier.problem(
                title: "Las recetas no arrancan",
                detail: "\(error). Las notas se procesan sin receta, como antes.")
            return nil
        }
    }

    private func sink(for store: Store) -> Sink {
        sinks(primary: saveSink(for: store), all: publishers(for: store).values.map(forgiving))
    }

    private func saveSink(for store: Store) -> Sink {
        store.audioCopySink()
    }

    private func bindings() -> [ConnectorBinding] {
        settings.connectors.compactMap { destination in
            guard destination.enabled, destination.isReady,
                  let account = settings.connectorAccounts.first(where: { $0.id == destination.accountID }), account.enabled,
                  let fingerprint = destination.programFingerprint else { return nil }
            return ConnectorBinding(key: destination.key, provider: destination.provider,
                destination: destination.destinationID, configurationJSON: destination.configurationJSON,
                programFingerprint: fingerprint, permission: connectorPermission(account),
                allowsNewPublications: !destination.sourceMissing)
        }
    }

    private func publishers(for store: Store) -> [String: Sink] {
        guard let publications = connectorPublications else { return [:] }
        return Dictionary(uniqueKeysWithValues: bindings().map { binding in
            (binding.key, { @Sendable note in
                if let url = try await publications.publish(note, to: binding) { return url }
                return URL(string: "urn:escriba:publication:" + connectorFingerprint(binding.key + ":" + note.recording.key))!
            } as Sink)
        })
    }

    private func unpublishers() -> [String: Unpublisher] {
        guard let publications = connectorPublications else { return [:] }
        return Dictionary(uniqueKeysWithValues: bindings().map { binding in
            (binding.key, { @Sendable key, locator in try await publications.remove(key: key, locator: locator, from: binding) } as Unpublisher)
        })
    }

    func openConnectorProject() {
        Task {
            do {
                let folder: URL
                if let path = settings.recipesFolderPath { folder = URL(fileURLWithPath: path) }
                else {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.prompt = "Elegir proyecto"
                    guard panel.runModal() == .OK, let chosen = panel.url else { return }
                    folder = chosen
                    settings.recipesFolderPath = chosen.path
                }
                try await writeConnectorProject(folder: folder, destinations: settings.connectors,
                    accounts: settings.connectorAccounts, services: connectorServices)
                await recipes.open(folder)
                NSWorkspace.shared.open(folder.appending(path: "conectores.ts"))
            } catch { startupProblem = "No se pudo abrir el proyecto: \(error.localizedDescription)" }
        }
    }

    private func stopPipelines() {
        controllers.forEach { $0.stop() }
        controllers = []
        events?.cancel()
        events = nil
    }

    private func watchSettings() {
        settingsWatch = Task { [weak self] in
            guard let settings = self?.settings else { return }
            let changes = Observations {
                [
                    settings.watchedFolders.map(\.path).joined(separator: ","),
                    "\(settings.sttResolvers)",
                    "\(settings.llmResolvers)",
                    fingerprint(of: settings.connectors),
                    "\(settings.connectorAccounts)",
                ].joined(separator: "|")
            }

            var initial = true
            for await _ in changes {
                if initial {
                    initial = false
                    continue
                }
                self?.rebuild()
            }
        }
        recipeBookWatch = Task { [weak self] in
            guard let settings = self?.settings else { return }
            for await book in Observations({ settings.recipeBook }) {
                self?.recipeBook.value = book
            }
        }
    }
}

nonisolated private func reprocessed(
    _ stored: StoredRecording, _ choice: RecipeChoice, recipe: Recipe?, backend: TranscriptionBackend,
    enrich: Enricher?, memory: NoteMemory, save: @escaping Sink, dryRun: Bool
) async -> RecipeRunReport {
    guard let recipe else { return RecipeRunReport(trace: nil, failure: "las recetas no arrancan en este Mac") }
    let target: RecipeTarget
    do {
        target = try recipe.shelf.target(choice.recipe).overriding(values: choice.values)
    } catch {
        return RecipeRunReport(trace: nil, failure: "\(error)")
    }
    let (result, trace) = await runRecipe(
        target, of: recipe, on: Recording(url: stored.sourceURL, startedAt: stored.startedAt, key: stored.key),
        audio: stored.audio == .libraryCopy ? stored.audioURL : stored.sourceURL,
        backend: backend, enrich: enrich, memory: memory, save: save, dryRun: dryRun, fresh: !dryRun)
    switch result {
    case .success: return RecipeRunReport(trace: trace, failure: nil)
    case .failure(let error): return RecipeRunReport(trace: trace, failure: "\(error)")
    }
}

private func recipeProjectModel(connectors: ConnectorsModel, archive: ConnectorArchive) -> RecipeProjectModel {
    let tools = EsbuildTools.directory(in: Paths.applicationSupport)
    let zod = ZodPackage.directory(in: Paths.applicationSupport)
    let installed = Paths.installedRecipes
    let compiler = EsbuildCompiler(tools: tools, zod: zod)
    return RecipeProjectModel(
        prepare: {
            if !EsbuildTools.isInstalled(in: tools) {
                Log.info("recetas: bajando esbuild \(EsbuildTools.version)")
                try await EsbuildTools.install(into: tools)
            }
            if !ZodPackage.isInstalled(in: zod) {
                Log.info("recetas: bajando Zod \(ZodPackage.version)")
                do {
                    try await ZodPackage.install(into: zod)
                } catch {
                    Log.error("recetas: no se pudo bajar Zod, las recetas que lo importen no compilarán: \(error)")
                }
            }
        },
        create: { folder in
            let written = try createRecipeProject(disk: folderRecipeProject(root: folder, installed: installed))
            if !written.isEmpty { Log.info("recetas: proyecto creado en \(folder.path(percentEncoded: false))") }
        },
        rebuild: { folder in
            if ZodPackage.isInstalled(in: zod), try ZodPackage.installTypes(from: zod, intoProject: folder) {
                Log.info("recetas: tipos de Zod \(ZodPackage.version) copiados a \(ZodPackage.projectFolder)")
            }
            try BundledConnectors.install(intoProject: folder)
            let snapshot = try snapshotConnectorProject(root: folder)
            let sources = try BundledConnectors.resolving(in: snapshot.sources)
            let base = folderRecipeProject(root: folder, installed: installed)
            let disk = RecipeProjectDisk(snapshot: { RecipeProjectSnapshot(paths: snapshot.paths, sources: sources) },
                write: base.write, loadInstalled: base.loadInstalled, saveInstalled: base.saveInstalled)
            var catalog = (#"{"destinations":[]}"#, "empty")
            if snapshot.paths.contains("conectores.ts") {
                switch try await compiler.compileConnector(files: sources, entry: "conectores.ts") {
                case .compiled(let source, _):
                    let program = ConnectorProgram(source: source, fingerprint: connectorFingerprint(source))
                    let inspected = try await inspectConnectorProgram(program)
                    try await archive.retain(program)
                    catalog = (inspected, program.fingerprint)
                case .failed(let issues):
                    throw ConnectorCatalogError.invalid(issues.map(\.text).joined(separator: "\n"))
                }
            }
            let (inspection, fingerprint) = catalog
            try await connectors.validateDestinations(inspectJSON: inspection, fingerprint: fingerprint)
            let staged = Shared<[String: InstalledRecipe]?>(nil)
            let stagedDisk = RecipeProjectDisk(snapshot: disk.snapshot, write: disk.write,
                loadInstalled: disk.loadInstalled, saveInstalled: { staged.value = $0 })
            let report = try await rebuildRecipeProject(disk: stagedDisk, toolchain: compiler.toolchain, now: Date())
            try await MainActor.run {
                try connectors.validateDestinations(inspectJSON: inspection, fingerprint: fingerprint)
                if let installed = staged.value { try disk.saveInstalled(installed) }
                try connectors.installDestinations(inspectJSON: inspection, fingerprint: fingerprint)
            }
            return report
        },
        watcher: recipeProjectWatcher)
}
