import Foundation
import Observation

public struct WatchedFolder: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    public var speakers: Int?

    public var id: String { path }

    public init(path: String, speakers: Int? = nil) {
        self.path = path
        self.speakers = speakers
    }
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Keys.language) ?? "es"
        diarization = Diarization(
            storageValue: defaults.object(forKey: Keys.diarization) as? Int ?? -1)
        notifyEveryNote = defaults.object(forKey: Keys.notifyEveryNote) as? Bool ?? true
        writeTxt = defaults.object(forKey: Keys.writeTxt) as? Bool ?? true
        txtFolderPath = defaults.string(forKey: Keys.txtFolder)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Documents/Transcripciones JPR").path(percentEncoded: false)
        watchedFolders = defaults.data(forKey: Keys.watchedFolders)
            .flatMap { try? JSONDecoder().decode([WatchedFolder].self, from: $0) } ?? []
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
