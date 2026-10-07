import Foundation
import EscribaModel
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import EscribaIntelligence
import EscribaJSC
import EscribaNotion
import EscribaOKF
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
    @ObservationIgnored private var recordingItem: RecordingStatusItem?
    @ObservationIgnored private let choices = fileChoiceStore(Paths.choices)
    @ObservationIgnored private let recipeBook: Shared<RecipeBook>

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
        LegacyMigration.run()
        AppSettings.adoptLegacyDefaults(from: UserDefaults(suiteName: "dev.ruben.jpr-transcribe"))
        settings = AppSettings()
        recipeBook = Shared(settings.recipeBook)
        connectors = ConnectorsModel(settings: settings)
        stt = ResolversModel(role: .stt, settings: settings, services: resolverServices())
        llm = ResolversModel(role: .llm, settings: settings, services: resolverServices())
        let relay = WakeRelay()
        let box = fileInbox(root: Paths.inbox)
        let microphone = MicrophoneRecorder()
        self.microphone = microphone
        recorder = RecorderModel(
            recorder: microphone.port(), inbox: box, choices: choices, wake: { relay.wake() },
            keepAwake: keepRecordingAwake)
        inbox = InboxModel(inbox: box, choices: choices, wake: { relay.wake() })
        recipes = recipeProjectModel()
        if let path = settings.recipesFolderPath {
            Task { [recipes] in await recipes.open(URL(fileURLWithPath: path)) }
        }
        relay.wake = { [weak self] in self?.wake() }
        recordingItem = RecordingStatusItem(recorder: recorder)
        Notifier.requestAuthorization()
        start()
        watchSettings()
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
            let formSettings: @Sendable () -> DefaultRecipeSettings = {
                let current = book.value
                return current.form(current.defaultKey)?.settings ?? .standard
            }

            let unchosen = TranscriptionOptions(language: nil, diarize: false)
            let backend = recipeTranscriber(stts.local, options: unchosen, engine: engine)
            let enrich = enricher(summarizer(for: llms.local), language: nil)
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
                            recipeConnector($0, isActive: publishers[$0.key] != nil)
                        },
                        unchosen: unchosen, engine: engine,
                        origin: { [folders = settings.watchedFolders, inbox = Paths.inbox.path(percentEncoded: false)] in
                            recipeOrigin(forSource: $0.url.path(percentEncoded: false), inbox: inbox, folders: folders)
                        }))
            }
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
                    let form = formSettings()
                    return try await recipeDigester(
                        recipeResolver(llms, key: form.llm), prompt: form.prompt, language: form.language
                    )(recording, transcript)
                },
                publishers: publishers,
                unpublishers: unpublishers(),
                discarded: { key, source in try ledger.markDiscarded(key: key, source: source) })
            model.startObserving()
            self.model = model

            warnAboutUnusable(stt: recipeResolver(stts, key: formSettings().stt), llm: recipeResolver(llms, key: formSettings().llm))

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
                result.append(namespaced(folderSource(name: inboxPrefix, root: Paths.inbox), prefix: inboxPrefix))
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

    private func warnAboutUnusable(stt: Resolver, llm: Resolver) {
        let sttProblem = stt.kind == .local ? localResolverProblem(.stt) : resolverProblem(stt, localProblem: nil)
        if let sttProblem {
            Log.error("no se puede transcribir con \(stt.name): \(sttProblem)")
            Notifier.problem(title: "No se puede transcribir con \(stt.name)", detail: sttProblem)
        }
        guard recipeBook.value.form(recipeBook.value.defaultKey)?.settings.summarize == true,
            let llmProblem = summarizer(for: llm).availability().problem
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

    private func publishers(for store: Store) -> [String: Sink] {
        var publishers: [String: Sink] = [:]
        for connector in settings.liveConnectors {
            switch connector.kind {
            case .notion:
                guard let export = connector.notion,
                    let token = defaultTokenStore(account: connector.key).read(), !token.isEmpty
                else { continue }
                publishers[connector.key] = notionSink(
                    export: export,
                    client: makeNotionClient(token: token),
                    journal: journal(for: store, connector: connector.key))
            case .okf:
                guard let export = connector.okf, export.isUsable else { continue }
                let folder = fileFolder(URL(fileURLWithPath: export.folder))
                publishers[connector.key] = okfSink(
                    export: export, folder: folder,
                    journal: okfJournal(for: store, connector: connector.key, root: folder.root),
                    producer: Self.producer)
            }
        }
        return publishers
    }

    private func unpublishers() -> [String: Unpublisher] {
        var result: [String: Unpublisher] = [:]
        for connector in settings.liveConnectors {
            switch connector.kind {
            case .notion:
                guard let token = defaultTokenStore(account: connector.key).read(), !token.isEmpty
                else { continue }
                let client = makeNotionClient(token: token)
                result[connector.key] = { pageId in try await unpublish(pageId: pageId, using: client) }
            case .okf:
                guard let export = connector.okf, export.isUsable else { continue }
                let folder = fileFolder(URL(fileURLWithPath: export.folder))
                let documents = export.documents
                result[connector.key] = { notePath in try okfUnpublish(notePath, from: folder, documents: documents) }
            }
        }
        return result
    }

    private static let producer =
        "escriba/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"

    private func okfJournal(for store: Store, connector: String, root: URL) -> OKFJournal {
        OKFJournal(
            published: { key, notePath, moment in
                do {
                    try store.markPublished(
                        key: key, connector: connector, pageId: notePath,
                        url: root.appending(path: notePath), at: moment)
                } catch {
                    Log.error("no se pudo anotar la exportacion de \(key): \(error)")
                }
            },
            failed: { key, problem in
                do {
                    try store.markPublishFailed(key: key, connector: connector, error: problem)
                } catch {
                    Log.error("no se pudo anotar el fallo al exportar \(key): \(error)")
                }
            })
    }

    private func journal(for store: Store, connector: String) -> NotionJournal {
        NotionJournal(
            known: { key in
                guard let publication = try store.recording(for: key)?.publication(in: connector),
                    let pageId = publication.pageId
                else { return nil }
                return NotionPageRef(id: pageId, url: publication.url)
            },
            published: { key, page, moment in
                do {
                    try store.markPublished(
                        key: key, connector: connector, pageId: page.id, url: page.url, at: moment)
                } catch {
                    Log.error("no se pudo anotar la publicacion de \(key): \(error)")
                }
            },
            failed: { key, problem in
                do {
                    try store.markPublishFailed(key: key, connector: connector, error: problem)
                } catch {
                    Log.error("no se pudo anotar el fallo al publicar \(key): \(error)")
                }
            })
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
        target = try recipe.shelf.target(choice.recipe).overriding(choice.parameters)
    } catch {
        return RecipeRunReport(trace: nil, failure: "\(error)")
    }
    let (result, trace) = await runRecipe(
        target, of: recipe, on: Recording(url: stored.sourceURL, startedAt: stored.startedAt, key: stored.key),
        audio: stored.audio == .libraryCopy ? stored.audioURL : stored.sourceURL,
        backend: backend, enrich: enrich, memory: memory, save: save, dryRun: dryRun)
    switch result {
    case .success: return RecipeRunReport(trace: trace, failure: nil)
    case .failure(let error): return RecipeRunReport(trace: trace, failure: "\(error)")
    }
}

private func recipeProjectModel() -> RecipeProjectModel {
    let tools = EsbuildTools.directory(in: Paths.applicationSupport)
    let installed = Paths.installedRecipes
    let compiler = EsbuildCompiler(tools: tools)
    return RecipeProjectModel(
        prepare: {
            guard !EsbuildTools.isInstalled(in: tools) else { return }
            Log.info("recetas: bajando esbuild \(EsbuildTools.version)")
            try await EsbuildTools.install(into: tools)
        },
        create: { folder in
            let written = try createRecipeProject(disk: folderRecipeProject(root: folder, installed: installed))
            if !written.isEmpty { Log.info("recetas: proyecto creado en \(folder.path(percentEncoded: false))") }
        },
        rebuild: { folder in
            try await rebuildRecipeProject(
                disk: folderRecipeProject(root: folder, installed: installed), toolchain: compiler.toolchain, now: Date())
        },
        watcher: recipeProjectWatcher)
}
