import Foundation

nonisolated public enum ResolverRole: String, Codable, Sendable, CaseIterable {
    case stt
    case llm

    public var label: String {
        switch self {
        case .stt: "STT"
        case .llm: "LLMs"
        }
    }

    public var localName: String {
        switch self {
        case .stt: "Whisper en este Mac"
        case .llm: "Apple Intelligence"
        }
    }

    public var localID: UUID {
        switch self {
        case .stt: UUID(uuidString: "E5C81BA0-0000-4000-8000-000000000001")!
        case .llm: UUID(uuidString: "E5C81BA0-0000-4000-8000-000000000002")!
        }
    }
}

nonisolated public struct Resolver: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case local
        case remote
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var baseURL: String
    public var model: String
    public var prompt: String?

    public init(
        id: UUID = UUID(), name: String, kind: Kind, baseURL: String = "", model: String = "",
        prompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.prompt = prompt
    }

    public static func local(_ role: ResolverRole) -> Resolver {
        Resolver(id: role.localID, name: role.localName, kind: .local)
    }

    public static func remote(_ preset: RemotePreset, role: ResolverRole, name: String) -> Resolver {
        Resolver(name: name, kind: .remote, baseURL: preset.baseURL, model: preset.model)
    }
}

nonisolated public struct ResolverSet: Codable, Equatable, Sendable {
    public let role: ResolverRole
    public private(set) var resolvers: [Resolver]
    public private(set) var favorite: UUID

    public init(role: ResolverRole, resolvers: [Resolver] = [], favorite: UUID? = nil) {
        self.role = role
        let local = resolvers.first { $0.id == role.localID }
        self.resolvers = [
            Resolver(
                id: role.localID, name: role.localName, kind: .local, prompt: local?.prompt)
        ] + resolvers.filter { $0.id != role.localID }
        let candidate = favorite ?? role.localID
        self.favorite = self.resolvers.contains { $0.id == candidate } ? candidate : role.localID
    }

    private enum CodingKeys: String, CodingKey {
        case role, resolvers, favorite
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            role: try container.decode(ResolverRole.self, forKey: .role),
            resolvers: try container.decodeIfPresent([Resolver].self, forKey: .resolvers) ?? [],
            favorite: try container.decodeIfPresent(UUID.self, forKey: .favorite))
    }

    public var favoriteResolver: Resolver { resolver(nil) }

    public func resolver(_ id: UUID?) -> Resolver {
        resolvers.first { $0.id == id } ?? resolvers.first { $0.id == favorite } ?? Resolver.local(role)
    }

    public func contains(_ id: UUID) -> Bool { resolvers.contains { $0.id == id } }

    public mutating func add(_ resolver: Resolver) {
        guard !contains(resolver.id) else { return }
        resolvers.append(resolver)
    }

    public mutating func update(_ resolver: Resolver) {
        guard let index = resolvers.firstIndex(where: { $0.id == resolver.id }) else { return }
        var updated = resolver
        if updated.id == role.localID {
            updated.kind = .local
            updated.name = role.localName
        }
        resolvers[index] = updated
    }

    public mutating func remove(_ id: UUID) {
        guard id != role.localID else { return }
        resolvers.removeAll { $0.id == id }
        if favorite == id { favorite = role.localID }
    }

    public mutating func makeFavorite(_ id: UUID) {
        guard contains(id) else { return }
        favorite = id
    }
}

nonisolated public struct ResolverChoice: Codable, Equatable, Hashable, Sendable {
    public var stt: UUID?
    public var llm: UUID?

    public init(stt: UUID? = nil, llm: UUID? = nil) {
        self.stt = stt
        self.llm = llm
    }

    public var isEmpty: Bool { stt == nil && llm == nil }

    public func overridden(by other: ResolverChoice?) -> ResolverChoice {
        ResolverChoice(stt: other?.stt ?? stt, llm: other?.llm ?? llm)
    }

    public subscript(role: ResolverRole) -> UUID? {
        get { role == .stt ? stt : llm }
        set {
            switch role {
            case .stt: stt = newValue
            case .llm: llm = newValue
            }
        }
    }

    public func forgetting(_ id: UUID, as role: ResolverRole) -> ResolverChoice {
        var copy = self
        if copy[role] == id { copy[role] = nil }
        return copy
    }
}

nonisolated public struct ResolverRouting: Sendable {
    public let stt: ResolverSet
    public let llm: ResolverSet
    public let folders: [WatchedFolder]
    public let inbox: String
    public let inboxChoice: ResolverChoice
    public let overrides: ChoiceStore

    public init(
        stt: ResolverSet, llm: ResolverSet, folders: [WatchedFolder], inbox: String,
        inboxChoice: ResolverChoice, overrides: ChoiceStore = .inMemory()
    ) {
        self.stt = stt
        self.llm = llm
        self.folders = folders
        self.inbox = inbox
        self.inboxChoice = inboxChoice
        self.overrides = overrides
    }

    public func choice(forSource path: String) -> ResolverChoice {
        originChoice(forSource: path).overridden(by: overrides.read(path))
    }

    public func originChoice(forSource path: String) -> ResolverChoice {
        let source = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if source.starts(with: URL(fileURLWithPath: inbox).standardizedFileURL.pathComponents) {
            return inboxChoice
        }
        return folder(for: path, among: folders)?.resolvers ?? ResolverChoice()
    }

    public func resolver(_ role: ResolverRole, forSource path: String) -> Resolver {
        resolvers(role).resolver(choice(forSource: path)[role])
    }

    public func resolvers(_ role: ResolverRole) -> ResolverSet {
        role == .stt ? stt : llm
    }
}

nonisolated public struct RemotePreset: Sendable, Equatable, Identifiable {
    public let name: String
    public let baseURL: String
    public let model: String

    public var id: String { name }

    public init(name: String, baseURL: String, model: String = "") {
        self.name = name
        self.baseURL = baseURL
        self.model = model
    }
}

nonisolated public func remotePresets(for role: ResolverRole) -> [RemotePreset] {
    let other = RemotePreset(name: "Otro servicio compatible", baseURL: "")
    switch role {
    case .stt:
        return [
            RemotePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "whisper-1"),
            RemotePreset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
            other,
        ]
    case .llm:
        return [
            RemotePreset(name: "OpenAI", baseURL: "https://api.openai.com/v1"),
            RemotePreset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
            RemotePreset(name: "Groq", baseURL: "https://api.groq.com/openai/v1"),
            RemotePreset(name: "LM Studio", baseURL: "http://localhost:1234/v1"),
            RemotePreset(name: "Ollama", baseURL: "http://localhost:11434/v1"),
            other,
        ]
    }
}

nonisolated public func nextResolverName(_ base: String, in set: ResolverSet) -> String {
    let taken = Set(set.resolvers.map(\.name))
    guard taken.contains(base) else { return base }
    return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
}

nonisolated public func resolverTokenStore(_ id: UUID) -> TokenStore {
    fileTokenStore(account: "resolver-\(id.uuidString)")
}
