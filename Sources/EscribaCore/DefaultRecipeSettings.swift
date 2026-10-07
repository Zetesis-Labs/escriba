import Foundation

public struct DefaultRecipeSettings: Sendable, Equatable, Codable {
    public var stt: String
    public var language: String?
    public var detectSpeakers: Bool
    public var speakerCount: Int?
    public var summarize: Bool
    public var llm: String
    public var prompt: String?
    public var connectors: [String]

    public init(
        stt: String, language: String?, detectSpeakers: Bool, speakerCount: Int?, summarize: Bool, llm: String,
        prompt: String?, connectors: [String]
    ) {
        self.stt = stt
        self.language = language
        self.detectSpeakers = detectSpeakers
        self.speakerCount = detectSpeakers ? speakerCount : nil
        self.summarize = summarize
        self.llm = llm
        self.prompt = prompt
        self.connectors = connectors
    }

    enum CodingKeys: String, CodingKey {
        case stt, language = "idioma", speakers = "hablantes", summarize = "resumir", llm, prompt
        case connectors = "conectores"
    }

    enum SpeakerKeys: String, CodingKey {
        case detect = "detectar", count = "cuantos"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let speakers = try container.nestedContainer(keyedBy: SpeakerKeys.self, forKey: .speakers)
        self.init(
            stt: try container.decode(String.self, forKey: .stt),
            language: try container.decodeIfPresent(String.self, forKey: .language),
            detectSpeakers: try speakers.decode(Bool.self, forKey: .detect),
            speakerCount: try speakers.decodeIfPresent(Int.self, forKey: .count),
            summarize: try container.decode(Bool.self, forKey: .summarize),
            llm: try container.decode(String.self, forKey: .llm),
            prompt: try container.decodeIfPresent(String.self, forKey: .prompt),
            connectors: try container.decode([String].self, forKey: .connectors))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stt, forKey: .stt)
        try container.encode(language, forKey: .language)
        var speakers = container.nestedContainer(keyedBy: SpeakerKeys.self, forKey: .speakers)
        try speakers.encode(detectSpeakers, forKey: .detect)
        try speakers.encode(speakerCount, forKey: .count)
        try container.encode(summarize, forKey: .summarize)
        try container.encode(llm, forKey: .llm)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(connectors, forKey: .connectors)
    }
}

extension DefaultRecipeSettings {
    public func forgettingResolver(_ key: String, stt localSTT: String, llm localLLM: String) -> DefaultRecipeSettings {
        var settings = self
        if settings.stt == key { settings.stt = localSTT }
        if settings.llm == key { settings.llm = localLLM }
        return settings
    }
}

public func migratedDefaultRecipe(
    stt: String, llm: String, llmPrompt: String?, language: String, diarization: Int, summarize: Bool,
    connectors: [String]
) -> DefaultRecipeSettings {
    DefaultRecipeSettings(
        stt: stt,
        language: language == "auto" ? nil : language,
        detectSpeakers: diarization >= 0,
        speakerCount: diarization > 0 ? diarization : nil,
        summarize: summarize,
        llm: llm,
        prompt: llmPrompt.flatMap { $0.isEmpty ? nil : $0 },
        connectors: connectors)
}
