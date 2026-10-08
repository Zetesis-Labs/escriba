import Foundation
import EscribaCore
import EscribaEngine
import Observation

nonisolated public struct WatchedFolder: Codable, Sendable, Equatable, Identifiable {
    public enum Style: String, Codable, Sendable {
        case justPressRecord
        case voiceMemos
        case any
    }

    public var path: String
    public var style: Style

    public var id: String { path }

    public init(path: String, style: Style = .any) {
        self.path = path
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case path, style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .any
    }
}

nonisolated extension WatchedFolder {
    public var displayName: String {
        switch style {
        case .justPressRecord: "Just Press Record"
        case .voiceMemos: "Notas de Voz"
        case .any: URL(fileURLWithPath: path).lastPathComponent
        }
    }

    fileprivate var pathComponents: [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }
}

nonisolated public func folder(for sourcePath: String, among folders: [WatchedFolder]) -> WatchedFolder? {
    let components = URL(fileURLWithPath: sourcePath).standardizedFileURL.pathComponents

    return folders
        .filter { components.starts(with: $0.pathComponents) }
        .max { $0.pathComponents.count < $1.pathComponents.count }
}

nonisolated public func recipeOrigin(
    forSource sourcePath: String, inbox: String, folders: [WatchedFolder]
) -> RecipeOrigin? {
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.pathComponents
    if source.starts(with: URL(fileURLWithPath: inbox).standardizedFileURL.pathComponents) {
        return RecipeOrigin(kind: .inbox, name: "Bandeja", path: inbox)
    }
    return folder(for: sourcePath, among: folders).map {
        RecipeOrigin(kind: .folder, name: $0.displayName, path: $0.path)
    }
}

public func seededWithVoiceMemos(
    _ folders: [WatchedFolder], root: URL?, alreadySeeded: Bool
) -> [WatchedFolder] {
    guard !alreadySeeded, let path = root?.path(percentEncoded: false),
        !folders.contains(where: { $0.path == path })
    else { return folders }

    return folders + [WatchedFolder(path: path, style: .voiceMemos)]
}

public func voiceMemosRoot(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    home.appending(path: "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
}

public func liveVoiceMemosRoot() -> URL? {
    let root = voiceMemosRoot()
    return FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) ? root : nil
}

public func defaultRecorderRoot(
    argument: String?, environment: [String: String], bundle: String?, home: URL
) -> URL? {
    let raw = argument ?? environment["ESCRIBA_ROOT"] ?? bundle
    guard let raw, !raw.isEmpty else { return nil }
    return raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : home.appending(path: raw)
}

public func liveRecorderRoot() -> URL? {
    defaultRecorderRoot(
        argument: UserDefaults.standard.string(forKey: "defaultRoot"),
        environment: ProcessInfo.processInfo.environment,
        bundle: Bundle.main.object(forInfoDictionaryKey: "EscribaDefaultRoot") as? String,
        home: FileManager.default.homeDirectoryForCurrentUser)
}

@Observable
public final class AppSettings {
    public var notifyEveryNote: Bool {
        didSet { defaults.set(notifyEveryNote, forKey: Keys.notifyEveryNote) }
    }
    public var recipesFolderPath: String? {
        didSet { defaults.set(recipesFolderPath, forKey: Keys.recipesFolder) }
    }
    public var recipeBook: RecipeBook {
        didSet { persist(recipeBook, forKey: Keys.recipeBook) }
    }
    public var watchedFolders: [WatchedFolder] {
        didSet { persist(watchedFolders, forKey: Keys.watchedFolders) }
    }
    public var connectors: [Connector] {
        didSet { persist(connectors, forKey: Keys.connectors) }
    }
    public var connectorAccounts: [ConnectorAccount] {
        didSet { persist(connectorAccounts, forKey: Keys.connectorAccounts) }
    }
    public var sttResolvers: ResolverSet {
        didSet { persist(sttResolvers, forKey: Keys.sttResolvers) }
    }
    public var llmResolvers: ResolverSet {
        didSet { persist(llmResolvers, forKey: Keys.llmResolvers) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        recorderRoot: URL? = liveRecorderRoot(),
        voiceMemos: URL? = liveVoiceMemosRoot()
    ) {
        self.defaults = defaults
        notifyEveryNote = defaults.object(forKey: Keys.notifyEveryNote) as? Bool ?? true
        recipesFolderPath = defaults.string(forKey: Keys.recipesFolder)
        let stored = Self.restore([WatchedFolder].self, from: defaults, key: Keys.watchedFolders)
            ?? recorderRoot.map {
                [WatchedFolder(path: $0.path(percentEncoded: false), style: .justPressRecord)]
            } ?? []

        let storedConnectors = Self.restore([Connector].self, from: defaults, key: Keys.connectors) ?? []
        let stt = Self.restore(ResolverSet.self, from: defaults, key: Keys.sttResolvers) ?? ResolverSet(role: .stt)
        let llm = Self.restore(ResolverSet.self, from: defaults, key: Keys.llmResolvers) ?? ResolverSet(role: .llm)
        connectors = storedConnectors
        connectorAccounts = Self.restore([ConnectorAccount].self, from: defaults, key: Keys.connectorAccounts) ?? []
        sttResolvers = stt
        llmResolvers = llm
        let (sttFavorite, llmFavorite) = (stt.resolver(stt.legacyFavorite), llm.resolver(llm.legacyFavorite))
        let savedDefaultRecipe = Self.restore(DefaultRecipeSettings.self, from: defaults, key: Keys.defaultRecipe)
            ?? migratedDefaultRecipe(
                stt: sttFavorite.recipeKey(role: .stt), llm: llmFavorite.recipeKey(role: .llm),
                llmPrompt: llmFavorite.prompt,
                language: defaults.string(forKey: Keys.language) ?? "es",
                diarization: defaults.object(forKey: Keys.diarization) as? Int ?? -1,
                summarize: defaults.object(forKey: Keys.summarize) as? Bool ?? false,
                connectors: storedConnectors.filter { $0.enabled }.map(\.key))
        recipeBook = (Self.restore(RecipeBook.self, from: defaults, key: Keys.recipeBook)
            ?? RecipeBook(migrating: savedDefaultRecipe, key: UUID().uuidString))
            .forgettingMissing(
                connectors: Set(storedConnectors.map(\.key)),
                stts: Set(stt.resolvers.map { $0.recipeKey(role: .stt) }),
                llms: Set(llm.resolvers.map { $0.recipeKey(role: .llm) }))
        watchedFolders = seededWithVoiceMemos(
            stored,
            root: voiceMemos,
            alreadySeeded: defaults.bool(forKey: Keys.voiceMemosSeeded))
        if voiceMemos != nil { defaults.set(true, forKey: Keys.voiceMemosSeeded) }
        persist(watchedFolders, forKey: Keys.watchedFolders)
        persist(recipeBook, forKey: Keys.recipeBook)
    }

    private static func restore<Value: Decodable>(
        _ type: Value.Type, from defaults: UserDefaults, key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Log.error("el ajuste \(key) guardado no se pudo leer y se ignora: \(error)")
            return nil
        }
    }

    private func persist(_ value: some Encodable, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Log.error("no se pudo guardar el ajuste \(key): \(error)")
        }
    }

    public var liveConnectors: [Connector] { connectors.filter { connector in
        connector.isLive && connectorAccounts.contains { $0.id == connector.accountID && $0.enabled }
    } }

    public func connector(_ id: UUID) -> Connector? {
        connectors.first { $0.id == id }
    }

    public func update(_ connector: Connector) {
        guard let index = connectors.firstIndex(where: { $0.id == connector.id }) else { return }
        connectors[index] = connector
    }

    public func resolvers(_ role: ResolverRole) -> ResolverSet {
        role == .stt ? sttResolvers : llmResolvers
    }

    public func setResolvers(_ set: ResolverSet, for role: ResolverRole) {
        switch role {
        case .stt: sttResolvers = set
        case .llm: llmResolvers = set
        }
    }

    public func removeWatchedFolder(path: String) {
        watchedFolders.removeAll { $0.path == path }
    }

    public func forget(resolver id: UUID, as role: ResolverRole) {
        recipeBook = recipeBook.forgettingResolver(id.uuidString)
    }

    public static func adoptLegacyDefaults(
        from legacy: UserDefaults?, into defaults: UserDefaults = .standard
    ) {
        guard let legacy, defaults.data(forKey: Keys.watchedFolders) == nil else { return }
        for key in [
            Keys.language, Keys.diarization, Keys.notifyEveryNote,
            Keys.watchedFolders,
        ] {
            if let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    private enum Keys {
        static let language = "language"
        static let diarization = "diarization"
        static let notifyEveryNote = "notifyEveryNote"
        static let summarize = "summarize"
        static let recipesFolder = "recipesFolder"
        static let defaultRecipe = "defaultRecipe"
        static let recipeBook = "recipeBook"
        static let watchedFolders = "watchedFolders"
        static let voiceMemosSeeded = "voiceMemosSeeded"
        static let connectors = "connectors"
        static let connectorAccounts = "connectorAccounts"
        static let sttResolvers = "sttResolvers"
        static let llmResolvers = "llmResolvers"
    }
}
