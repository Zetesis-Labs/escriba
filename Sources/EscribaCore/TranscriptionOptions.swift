import Foundation

public struct TranscriptionOptions: Sendable, Equatable, Codable, Hashable {
    public var language: String?
    public var diarize: Bool
    public var speakerCount: Int?

    public init(language: String? = nil, diarize: Bool = false, speakerCount: Int? = nil) {
        self.language = language
        self.diarize = diarize
        self.speakerCount = diarize ? speakerCount : nil
    }

    public static let automatic = TranscriptionOptions()

    public var label: String {
        var parts = [language.map { $0.uppercased() } ?? "idioma automático"]
        if diarize {
            parts.append(speakerCount.map { "\($0) hablantes" } ?? "hablantes automáticos")
        } else {
            parts.append("sin hablantes")
        }
        return parts.joined(separator: " · ")
    }
}

public func spokenLanguage(_ options: TranscriptionOptions?, fallback: String?) -> String? {
    guard let options else { return fallback }
    return options.language
}
