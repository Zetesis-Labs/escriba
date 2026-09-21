import Foundation
import EscribaCore
import EscribaEngine
import Observation
import EscribaNotion

public struct WatchedFolder: Codable, Sendable, Equatable, Identifiable {
    public enum Style: String, Codable, Sendable {
        case justPressRecord
        case voiceMemos
        case any
    }

    public var path: String
    public var speakers: Int?
    public var style: Style

    public var id: String { path }

    public init(path: String, speakers: Int? = nil, style: Style = .any) {
        self.path = path
        self.speakers = speakers
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case path, speakers, style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        speakers = try container.decodeIfPresent(Int.self, forKey: .speakers)
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .any
    }
}

extension WatchedFolder {
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

public func folder(for sourcePath: String, among folders: [WatchedFolder]) -> WatchedFolder? {
    let components = URL(fileURLWithPath: sourcePath).standardizedFileURL.pathComponents

    return folders
        .filter { components.starts(with: $0.pathComponents) }
        .max { $0.pathComponents.count < $1.pathComponents.count }
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

public enum Diarization: Equatable, Sendable {
    case off
    case auto
    case fixed(Int)

    public var storageValue: Int {
        switch self {
        case .off: -1
        case .auto: 0
        case .fixed(let count): count
        }
    }

    public init(storageValue: Int) {
        switch storageValue {
        case ..<0: self = .off
        case 0: self = .auto
        default: self = .fixed(storageValue)
        }
    }

    public var speakerCount: Int? {
        if case .fixed(let count) = self { return count }
        return nil
    }
}

@Observable
public final class AppSettings {
    public var language: String {
        didSet { defaults.set(language, forKey: Keys.language) }
    }
    public var diarization: Diarization {
        didSet { defaults.set(diarization.storageValue, forKey: Keys.diarization) }
    }
    public var notifyEveryNote: Bool {
        didSet { defaults.set(notifyEveryNote, forKey: Keys.notifyEveryNote) }
    }
    public var writeTxt: Bool {
        didSet { defaults.set(writeTxt, forKey: Keys.writeTxt) }
    }
    public var txtFolderPath: String {
        didSet { defaults.set(txtFolderPath, forKey: Keys.txtFolder) }
    }
    public var watchedFolders: [WatchedFolder] {
        didSet { persist(watchedFolders, forKey: Keys.watchedFolders) }
    }
    public var connectors: [Connector] {
        didSet { persist(connectors, forKey: Keys.connectors) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        recorderRoot: URL? = liveRecorderRoot(),
        voiceMemos: URL? = liveVoiceMemosRoot()
    ) {
        self.defaults = defaults
        language = defaults.string(forKey: Keys.language) ?? "es"
        diarization = Diarization(
            storageValue: defaults.object(forKey: Keys.diarization) as? Int ?? -1)
        notifyEveryNote = defaults.object(forKey: Keys.notifyEveryNote) as? Bool ?? true
        writeTxt = defaults.object(forKey: Keys.writeTxt) as? Bool ?? true
        txtFolderPath = defaults.string(forKey: Keys.txtFolder)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Documents/Transcripciones JPR").path(percentEncoded: false)
        let stored = Self.restore([WatchedFolder].self, from: defaults, key: Keys.watchedFolders)
            ?? recorderRoot.map {
                [WatchedFolder(path: $0.path(percentEncoded: false), style: .justPressRecord)]
            } ?? []

        connectors = Self.restore([Connector].self, from: defaults, key: Keys.connectors) ?? []
        watchedFolders = seededWithVoiceMemos(
            stored,
            root: voiceMemos,
            alreadySeeded: defaults.bool(forKey: Keys.voiceMemosSeeded))
        if voiceMemos != nil { defaults.set(true, forKey: Keys.voiceMemosSeeded) }
        persist(watchedFolders, forKey: Keys.watchedFolders)
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

    public var languageCode: String? {
        language == "auto" ? nil : language
    }

    public var transcriptionDefaults: TranscriptionOptions {
        TranscriptionOptions(
            language: languageCode, diarize: diarization != .off,
            speakerCount: diarization.speakerCount)
    }

    public func transcriptionOptions(for folder: WatchedFolder) -> TranscriptionOptions {
        TranscriptionOptions(
            language: languageCode,
            diarize: folder.speakers != nil || diarization != .off,
            speakerCount: folder.speakers ?? diarization.speakerCount)
    }

    public var txtFolder: URL? {
        writeTxt ? URL(fileURLWithPath: txtFolderPath) : nil
    }

    public var liveConnectors: [Connector] { connectors.filter(\.isLive) }

    public func connector(_ id: UUID) -> Connector? {
        connectors.first { $0.id == id }
    }

    public func update(_ connector: Connector) {
        guard let index = connectors.firstIndex(where: { $0.id == connector.id }) else { return }
        connectors[index] = connector
    }

    public static func adoptLegacyDefaults(
        from legacy: UserDefaults?, into defaults: UserDefaults = .standard
    ) {
        guard let legacy, defaults.data(forKey: Keys.watchedFolders) == nil else { return }
        for key in [
            Keys.language, Keys.diarization, Keys.notifyEveryNote,
            Keys.writeTxt, Keys.txtFolder, Keys.watchedFolders,
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
        static let writeTxt = "writeTxt"
        static let txtFolder = "txtFolder"
        static let watchedFolders = "watchedFolders"
        static let voiceMemosSeeded = "voiceMemosSeeded"
        static let connectors = "connectors"
    }
}
