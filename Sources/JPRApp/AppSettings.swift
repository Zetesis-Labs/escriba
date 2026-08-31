import Foundation
import Observation

public struct WatchedFolder: Codable, Sendable, Equatable, Identifiable {
    public enum Style: String, Codable, Sendable {
        case justPressRecord
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

public func defaultRecorderRoot(
    argument: String?, environment: [String: String], bundle: String?, home: URL
) -> URL? {
    let raw = argument ?? environment["JPR_TRANSCRIBE_ROOT"] ?? bundle
    guard let raw, !raw.isEmpty else { return nil }
    return raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : home.appending(path: raw)
}

public func liveRecorderRoot() -> URL? {
    defaultRecorderRoot(
        argument: UserDefaults.standard.string(forKey: "defaultRoot"),
        environment: ProcessInfo.processInfo.environment,
        bundle: Bundle.main.object(forInfoDictionaryKey: "JPRDefaultRoot") as? String,
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
        didSet {
            defaults.set(try? JSONEncoder().encode(watchedFolders), forKey: Keys.watchedFolders)
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, recorderRoot: URL? = liveRecorderRoot()) {
        self.defaults = defaults
        language = defaults.string(forKey: Keys.language) ?? "es"
        diarization = Diarization(
            storageValue: defaults.object(forKey: Keys.diarization) as? Int ?? -1)
        notifyEveryNote = defaults.object(forKey: Keys.notifyEveryNote) as? Bool ?? true
        writeTxt = defaults.object(forKey: Keys.writeTxt) as? Bool ?? true
        txtFolderPath = defaults.string(forKey: Keys.txtFolder)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Documents/Transcripciones JPR").path(percentEncoded: false)
        if let stored = defaults.data(forKey: Keys.watchedFolders)
            .flatMap({ try? JSONDecoder().decode([WatchedFolder].self, from: $0) }) {
            watchedFolders = stored
        } else {
            let seeded = recorderRoot.map {
                [WatchedFolder(path: $0.path(percentEncoded: false), style: .justPressRecord)]
            } ?? []
            watchedFolders = seeded
            defaults.set(try? JSONEncoder().encode(seeded), forKey: Keys.watchedFolders)
        }
    }

    public var languageCode: String? {
        language == "auto" ? nil : language
    }

    private enum Keys {
        static let language = "language"
        static let diarization = "diarization"
        static let notifyEveryNote = "notifyEveryNote"
        static let writeTxt = "writeTxt"
        static let txtFolder = "txtFolder"
        static let watchedFolders = "watchedFolders"
    }
}
