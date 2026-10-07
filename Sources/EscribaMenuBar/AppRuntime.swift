import Foundation
import EscribaModel
import EscribaCore
import EscribaEngine
import EscribaSystemKit
import EscribaIntelligence
import EscribaNotion
import EscribaOKF
import EscribaOpenAI
import EscribaStore
import EscribaWhisper
import Observation

private func digester(_ routing: ResolverRouting, enabled: Bool, language: String?) -> Digester? {
    guard enabled else { return nil }
    return { recording, transcript in
        try await summarizer(for: routing.resolver(.llm, forSource: recording.sourceURL.path(percentEncoded: false)))
            .digest(of: transcript.rendered, language: language)
    }
}

private struct PipelineSource {
    let source: RecordingSource
    let backend: TranscriptionBackend
    let options: TranscriptionOptions
    let stt: Resolver
    let llm: Resolver
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
    let stt: ResolversModel
    let llm: ResolversModel
    let recorder: RecorderModel
    let inbox: InboxModel

    @ObservationIgnored private var controllers: [DaemonController] = []
    @ObservationIgnored private var instanceLock: InstanceLock?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var settingsWatch: Task<Void, Never>?
    @ObservationIgnored private let microphone: MicrophoneRecorder
    @ObservationIgnored private var recordingItem: RecordingStatusItem?
    @ObservationIgnored private let choices = fileChoiceStore(Paths.choices)

    var symbolName: String {
        if recorder.isRecording { return "record.circle" }
        return model?.status.symbolName ?? WatcherStatus.problem("").symbolName
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
            let engine = WhisperKitEngine(language: settings.languageCode)
            let routing = settings.routing(inbox: Paths.inbox.path(percentEncoded: false), overrides: choices)
            let pipelineSources = sources(engine: engine, routing: routing)

            let model = LibraryModel(
                store: store,
                reprocess: { [engine] recording, options in
                    let stt = routing.resolver(.stt, forSource: recording.sourceURL.path(percentEncoded: false))
                    return try await transcriber(for: stt, options: options, engine: engine)
                        .transcribe(recording.audioURL)
                },
                digester: digester(routing, enabled: settings.summarize, language: settings.languageCode),
                writeText: textWriter(into: settings.txtFolder),
                publishers: publishers(for: store),
                unpublishers: unpublishers(),
                choices: choices)
            model.startObserving()
            self.model = model

            warnAboutUnusable(pipelineSources)

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
            let summarize = settings.summarize
            let language = settings.languageCode
            controllers = pipelineSources.map { entry in
                let pipeline = Pipeline(
                    source: entry.source,
                    ledger: ledger,
                    backend: entry.backend,
                    sink: sink(for: store),
                    enrich: summarize ? routedEnricher(routing, language: language) : nil,
                    memory: store.memory(inputs: routedInputs(routing, options: entry.options)),
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

        func sources(engine: WhisperKitEngine, routing: ResolverRouting) -> [PipelineSource] {
            var result: [PipelineSource] = []
            var prefixes: Set<String> = [inboxPrefix]

            func entry(_ source: RecordingSource, _ choice: ResolverChoice, _ options: TranscriptionOptions) -> PipelineSource {
                PipelineSource(
                    source: source, backend: routedTranscriber(routing, options: options, engine: engine),
                    options: options, stt: settings.sttResolvers.resolver(choice.stt),
                    llm: settings.llmResolvers.resolver(choice.llm))
            }

            do {
                try FileManager.default.createDirectory(at: Paths.inbox, withIntermediateDirectories: true)
                let options = settings.transcriptionOptions(for: WatchedFolder(path: Paths.inbox.path(percentEncoded: false)))
                result.append(entry(
                    namespaced(folderSource(name: inboxPrefix, root: Paths.inbox), prefix: inboxPrefix),
                    settings.inboxResolvers, options))
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

                let options = settings.transcriptionOptions(for: folder)

                switch folder.style {
                case .justPressRecord:
                    result.append(entry(justPressRecordSource(root: folderRoot), folder.resolvers, options))
                    continue
                case .voiceMemos:
                    result.append(entry(
                        namespaced(
                            voiceMemosSource(root: folderRoot, expectedSpeakers: folder.speakers),
                            prefix: "Notas de Voz"),
                        folder.resolvers, options))
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
                result.append(entry(
                    namespaced(
                        folderSource(
                            name: prefix, root: folderRoot, expectedSpeakers: folder.speakers),
                        prefix: prefix),
                    folder.resolvers, options))
            }
            return result
        }
    }

    private func warnAboutUnusable(_ sources: [PipelineSource]) {
        var warned: Set<UUID> = []
        for resolver in sources.map(\.stt) where warned.insert(resolver.id).inserted {
            let problem = resolver.kind == .local
                ? localResolverProblem(.stt)
                : resolverProblem(resolver, localProblem: nil)
            guard let problem else { continue }
            Log.error("no se puede transcribir con \(resolver.name): \(problem)")
            Notifier.problem(title: "No se puede transcribir con \(resolver.name)", detail: problem)
        }
        guard settings.summarize else { return }
        for resolver in sources.map(\.llm) where warned.insert(resolver.id).inserted {
            guard let problem = summarizer(for: resolver).availability().problem else { continue }
            Log.error("los resumenes estan activados pero \(resolver.name): \(problem)")
            Notifier.problem(
                title: "No se puede resumir con \(resolver.name)",
                detail: "\(problem). Las notas se transcribiran igual.")
        }
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

    private func sink(for store: Store) -> Sink {
        let primary = settings.writeTxt
            ? sidecarTextSink(outputRoot: URL(fileURLWithPath: settings.txtFolderPath))
            : store.audioCopySink()
        return sinks(primary: primary, all: publishers(for: store).values.map(forgiving))
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
                    settings.language,
                    "\(settings.diarization.storageValue)",
                    "\(settings.writeTxt)",
                    settings.txtFolderPath,
                    "\(settings.summarize)",
                    settings.watchedFolders
                        .map { "\($0.path):\($0.speakers ?? 0):\($0.resolvers)" }.joined(separator: ","),
                    "\(settings.sttResolvers)",
                    "\(settings.llmResolvers)",
                    "\(settings.inboxResolvers)",
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
    }
}
