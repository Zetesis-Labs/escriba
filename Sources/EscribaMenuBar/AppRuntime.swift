import Foundation
import EscribaModel
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import EscribaIntelligence
import EscribaNotion
import EscribaStore
import EscribaWhisper
import Observation

private func digester(_ summarizer: Summarizer?, language: String?) -> Digester? {
    guard let summarizer else { return nil }
    return { transcript in
        try await summarizer.digest(of: transcript.rendered, language: language)
    }
}

private func textWriter(into folder: URL?) -> TranscriptWriter? {
    guard let folder else { return nil }
    return { key, transcript in
        try writeSidecarText(outputRoot: folder, key: key, transcript: transcript)
    }
}

@Observable
final class AppRuntime {
    private(set) var model: LibraryModel?
    private(set) var startupProblem: String?
    var section = MainSection.initial(from: ProcessInfo.processInfo.environment)
    let settings: AppSettings
    let connectors: ConnectorsModel

    @ObservationIgnored private var controllers: [DaemonController] = []
    @ObservationIgnored private var instanceLock: InstanceLock?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var settingsWatch: Task<Void, Never>?

    var symbolName: String {
        model?.status.symbolName ?? WatcherStatus.problem("").symbolName
    }

    var statusLabel: String {
        if let startupProblem { return "Problema: \(startupProblem)" }
        return model?.status.label ?? WatcherStatus.starting.label
    }

    init() {
        Log.mirrorToFile(Paths.logFile)
        Log.info("Escriba arrancando")
        LegacyMigration.run()
        AppSettings.adoptLegacyDefaults(from: UserDefaults(suiteName: "dev.ruben.jpr-transcribe"))
        settings = AppSettings()
        connectors = ConnectorsModel(settings: settings)
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
            let engine = WhisperKitEngine(language: settings.languageCode)
            let summarizer = liveSummarizer()

            let model = LibraryModel(
                store: store,
                reprocess: { [engine] url, options in
                    try await engine.backend(options: options).transcribe(url)
                },
                digester: digester(summarizer, language: settings.languageCode),
                writeText: textWriter(into: settings.txtFolder),
                publishers: publishers(for: store),
                unpublishers: unpublishers())
            model.startObserving()
            self.model = model

            do {
                try engine.backend().preflight()
            } catch {
                Log.error("\(error)")
                Notifier.problem(title: "Modelo de transcripcion no disponible", detail: "\(error)")
            }

            let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
            events = Task { [settings] in
                for await event in stream {
                    await model.apply(event)
                    if settings.notifyEveryNote || event.isProblem {
                        Notifier.notify(event)
                    }
                }
            }

            let ledger = try Ledger(path: Paths.defaultState)
            reconcileLibrary(store: store, ledger: ledger)
            controllers = sources(engine: engine).map { source, backend, options in
                let pipeline = Pipeline(
                    source: source,
                    ledger: ledger,
                    backend: backend,
                    sink: sink(for: store, options: options),
                    enrich: summarizer.map { enricher($0, language: settings.languageCode) },
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
            startupProblem = "\(error)"
            Notifier.problem(title: "No se pudo arrancar", detail: "\(error)")
        }

        func sources(engine: WhisperKitEngine) -> [(RecordingSource, TranscriptionBackend, TranscriptionOptions)] {
            var result: [(RecordingSource, TranscriptionBackend, TranscriptionOptions)] = []
            var prefixes: Set<String> = []

            for folder in settings.watchedFolders {
                let folderRoot = URL(fileURLWithPath: folder.path)
                if let problem = FileSystem.accessProblem(root: folderRoot) {
                    Log.error("\(problem)")
                    Notifier.problem(title: "Carpeta vigilada inaccesible", detail: folder.path)
                    continue
                }

                let options = settings.transcriptionOptions(for: folder)
                let backend = engine.backend(options: options)

                switch folder.style {
                case .justPressRecord:
                    result.append((justPressRecordSource(root: folderRoot), backend, options))
                    continue
                case .voiceMemos:
                    result.append((
                        namespaced(
                            voiceMemosSource(root: folderRoot, expectedSpeakers: folder.speakers),
                            prefix: "Notas de Voz"),
                        backend, options))
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
                result.append((
                    namespaced(
                        folderSource(
                            name: prefix, root: folderRoot, expectedSpeakers: folder.speakers),
                        prefix: prefix),
                    backend, options
                ))
            }
            return result
        }
    }

    private func liveSummarizer() -> Summarizer? {
        guard settings.summarize else { return nil }
        let summarizer = AppleIntelligence.summarizer()
        if let problem = summarizer.availability().problem {
            Log.error("los resumenes estan activados pero \(problem)")
            Notifier.problem(
                title: "No se pueden generar resumenes",
                detail: "\(problem). Las notas se transcribiran igual.")
        }
        return summarizer
    }

    private func reconcileLibrary(store: Store, ledger: Ledger) {
        Task {
            await offloaded {
                do {
                    try store.resetInterrupted()
                    store.adoptLedgerHistory(try ledger.doneRecords())
                } catch {
                    Log.error("no se pudo reconciliar la biblioteca con el ledger: \(error)")
                }
            }
        }
    }

    private func sink(for store: Store, options: TranscriptionOptions) -> Sink {
        let librarySink = store.sink(backend: WhisperKitBackend.name, options: options)
        let extras = publishers(for: store).values.map(forgiving)

        guard settings.writeTxt else {
            return sinks(primary: librarySink, all: extras)
        }
        return sinks(
            primary: sidecarTextSink(outputRoot: URL(fileURLWithPath: settings.txtFolderPath)),
            all: [librarySink] + extras)
    }

    private func publishers(for store: Store) -> [String: Sink] {
        var publishers: [String: Sink] = [:]
        for connector in settings.liveConnectors {
            guard let export = connector.notion,
                let token = defaultTokenStore(account: connector.key).read(), !token.isEmpty
            else { continue }
            publishers[connector.key] = notionSink(
                export: export,
                client: makeNotionClient(token: token),
                journal: journal(for: store, connector: connector.key))
        }
        return publishers
    }

    private func unpublishers() -> [String: Unpublisher] {
        var result: [String: Unpublisher] = [:]
        for connector in settings.liveConnectors {
            guard let token = defaultTokenStore(account: connector.key).read(), !token.isEmpty
            else { continue }
            let client = makeNotionClient(token: token)
            result[connector.key] = { pageId in try await unpublish(pageId: pageId, using: client) }
        }
        return result
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
                    settings.language,
                    "\(settings.diarization.storageValue)",
                    "\(settings.writeTxt)",
                    settings.txtFolderPath,
                    "\(settings.summarize)",
                    settings.watchedFolders
                        .map { "\($0.path):\($0.speakers ?? 0)" }.joined(separator: ","),
                    settings.connectors.map { connector in
                        let export = connector.notion.map { export in
                            ([export.source.id, "\(export.template.hashValue)"]
                                + export.mapping.assigned.map { "\($0.key.rawValue)=\($0.value)" }
                                    .sorted())
                                .joined(separator: ",")
                        } ?? ""
                        return "\(connector.key):\(connector.enabled):\(export)"
                    }.joined(separator: ";"),
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
    }
}
