import Foundation
import Observation
import EscribaCore
import EscribaOpenAI

nonisolated public struct ResolverServices: Sendable {
    public var models: @Sendable (Resolver, String?) async throws -> [String]
    public var summarize: @Sendable (Resolver, String?, String) async throws -> Digest
    public var transcribe: @Sendable (Resolver, String?) async throws -> String
    public var localProblem: @Sendable (ResolverRole) -> String?

    public init(
        models: @escaping @Sendable (Resolver, String?) async throws -> [String],
        summarize: @escaping @Sendable (Resolver, String?, String) async throws -> Digest,
        transcribe: @escaping @Sendable (Resolver, String?) async throws -> String,
        localProblem: @escaping @Sendable (ResolverRole) -> String?
    ) {
        self.models = models
        self.summarize = summarize
        self.transcribe = transcribe
        self.localProblem = localProblem
    }
}

@Observable
public final class ResolversModel {
    public let role: ResolverRole
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tokens: @Sendable (UUID) -> TokenStore
    @ObservationIgnored private let services: ResolverServices
    @ObservationIgnored private var editors: [UUID: ResolverModel] = [:]

    public init(
        role: ResolverRole, settings: AppSettings,
        tokens: @escaping @Sendable (UUID) -> TokenStore = resolverTokenStore,
        services: ResolverServices
    ) {
        self.role = role
        self.settings = settings
        self.tokens = tokens
        self.services = services
    }

    public var resolvers: [Resolver] { settings.resolvers(role).resolvers }

    public var favorite: UUID { settings.resolvers(role).favorite }

    public func problem(of resolver: Resolver) -> String? {
        resolverProblem(resolver, localProblem: services.localProblem(role))
    }

    @discardableResult
    public func add(_ preset: RemotePreset) -> Resolver {
        var set = settings.resolvers(role)
        let resolver = Resolver.remote(preset, role: role, name: nextResolverName(preset.name, in: set))
        set.add(resolver)
        settings.setResolvers(set, for: role)
        return resolver
    }

    public func remove(_ id: UUID) {
        guard id != role.localID else { return }
        var set = settings.resolvers(role)
        set.remove(id)
        settings.setResolvers(set, for: role)
        settings.forget(resolver: id, as: role)
        tokens(id).write(nil)
        editors[id] = nil
    }

    public func makeFavorite(_ id: UUID) {
        var set = settings.resolvers(role)
        set.makeFavorite(id)
        settings.setResolvers(set, for: role)
    }

    public func editor(for id: UUID) -> ResolverModel {
        if let editor = editors[id] { return editor }
        let editor = ResolverModel(
            resolver: id, role: role, settings: settings, tokens: tokens(id), services: services)
        editors[id] = editor
        return editor
    }
}

nonisolated public func resolverProblem(_ resolver: Resolver, localProblem: String?) -> String? {
    switch resolver.kind {
    case .local:
        return localProblem
    case .remote:
        if let problem = remoteURLProblem(resolver.baseURL) { return problem }
        return resolver.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Elige el modelo." : nil
    }
}

nonisolated public func storedPrompt(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == DigestPrompt.standard ? nil : trimmed
}

@Observable
public final class ResolverModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case working
        case failed(String)

        public var isWorking: Bool { self == .working }

        public var problem: String? {
            guard case .failed(let message) = self else { return nil }
            return message
        }
    }

    public enum Trial: Equatable, Sendable {
        case digest(Digest)
        case transcript(String)
    }

    public let id: UUID
    public let role: ResolverRole
    public var key: String
    public var prompt: String
    public private(set) var models: [String] = []
    public private(set) var phase: Phase = .idle
    public private(set) var trial: Trial?
    private var base: Resolver
    @ObservationIgnored private var savedKey: String

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tokens: TokenStore
    @ObservationIgnored private let services: ResolverServices

    init(
        resolver id: UUID, role: ResolverRole, settings: AppSettings, tokens: TokenStore,
        services: ResolverServices
    ) {
        self.id = id
        self.role = role
        self.settings = settings
        self.tokens = tokens
        self.services = services
        let saved = settings.resolvers(role).resolver(id)
        base = saved
        prompt = saved.prompt ?? DigestPrompt.standard
        savedKey = tokens.read() ?? ""
        key = savedKey
    }

    public var saved: Resolver { settings.resolvers(role).resolver(id) }

    public var draft: Resolver {
        var draft = base
        draft.prompt = role == .llm ? storedPrompt(prompt) : nil
        return draft
    }

    public var isLocal: Bool { base.kind == .local }

    public var isFavorite: Bool { settings.resolvers(role).favorite == id }

    public var isDirty: Bool { draft != saved || key != savedKey }

    public var name: String {
        get { base.name }
        set { if !isLocal { base.name = newValue } }
    }

    public var baseURL: String {
        get { base.baseURL }
        set { base.baseURL = newValue }
    }

    public var model: String {
        get { base.model }
        set { base.model = newValue }
    }

    public var usesStandardPrompt: Bool { storedPrompt(prompt) == nil }

    public func restoreStandardPrompt() {
        prompt = DigestPrompt.standard
    }

    public func apply(_ preset: RemotePreset) {
        base.baseURL = preset.baseURL
        if !preset.model.isEmpty { base.model = preset.model }
        models = []
    }

    public var readiness: String? {
        resolverProblem(draft, localProblem: services.localProblem(role))
    }

    public func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isLocal { tokens.write(trimmed.isEmpty ? nil : trimmed) }
        savedKey = trimmed
        key = trimmed
        var set = settings.resolvers(role)
        set.update(draft)
        settings.setResolvers(set, for: role)
        base = saved
        prompt = base.prompt ?? DigestPrompt.standard
    }

    public func discard() {
        base = saved
        prompt = base.prompt ?? DigestPrompt.standard
        key = savedKey
        phase = .idle
        trial = nil
    }

    private var currentKey: String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func loadModels() async {
        phase = .working
        do {
            models = try await services.models(draft, currentKey).sorted()
            phase = .idle
        } catch {
            models = []
            phase = .failed(String(describing: error))
        }
    }

    public func tryIt() async {
        phase = .working
        trial = nil
        do {
            switch role {
            case .llm:
                trial = .digest(try await services.summarize(draft, currentKey, sampleTranscriptText))
            case .stt:
                trial = .transcript(try await services.transcribe(draft, currentKey))
            }
            phase = .idle
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}

nonisolated public let sampleTranscriptText = sampleNote(recordedAt: Date(timeIntervalSince1970: 0)).transcript.rendered
