import Foundation
import EscribaCore

public enum SummaryAvailability: Sendable, Equatable {
    case ready
    case unavailable(String)

    public var isReady: Bool { self == .ready }

    public var problem: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

public enum SummaryError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    case nothingToSummarize
    case empty
    case failed(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): "el modelo de lenguaje no esta disponible: \(reason)"
        case .nothingToSummarize: "no hay texto que resumir"
        case .empty: "el modelo no devolvio ningun resumen"
        case .failed(let detail): "no se pudo resumir: \(detail)"
        }
    }

    public static func catching<T>(
        _ body: () async throws -> T
    ) async throws(SummaryError) -> T {
        do {
            return try await body()
        } catch let error as SummaryError {
            throw error
        } catch {
            throw SummaryError.failed("\(error)")
        }
    }
}

public struct Summarizer: Sendable {
    public let name: String
    public let capacity: Int
    public let availability: @Sendable () -> SummaryAvailability
    public let run: @Sendable (DigestRequest) async throws(SummaryError) -> Digest

    public init(
        name: String,
        capacity: Int,
        availability: @escaping @Sendable () -> SummaryAvailability = { .ready },
        run: @escaping @Sendable (DigestRequest) async throws(SummaryError) -> Digest
    ) {
        self.name = name
        self.capacity = capacity
        self.availability = availability
        self.run = run
    }
}

public let maxReduceRounds = 3

extension Summarizer {
    public func digest(of text: String, language: String?) async throws(SummaryError) -> Digest {
        if case .unavailable(let reason) = availability() { throw .unavailable(reason) }
        let chunks = digestChunks(of: text, maxCharacters: capacity)
        guard !chunks.isEmpty else { throw .nothingToSummarize }
        guard chunks.count > 1 else {
            return try await answer(digestRequest(text: chunks[0], language: language))
        }

        var partials = try await summaries(of: chunks) { digestRequest(text: $0, language: language) }
        for _ in 0...maxReduceRounds {
            let joined = digestChunks(of: partials.joined(separator: "\n"), maxCharacters: capacity)
            guard joined.count > 1 else {
                return try await answer(reduceRequest(partials: joined, language: language))
            }
            partials = try await summaries(of: joined) { reduceRequest(partials: [$0], language: language) }
        }
        throw .failed("la transcripcion es demasiado larga para \(name)")
    }

    private func summaries(
        of chunks: [String], _ request: (String) -> DigestRequest
    ) async throws(SummaryError) -> [String] {
        var partials: [String] = []
        for chunk in chunks {
            partials.append(try await answer(request(chunk)).rendered)
        }
        return partials
    }

    private func answer(_ request: DigestRequest) async throws(SummaryError) -> Digest {
        let digest = normalizedDigest(try await run(request))
        guard !digest.isEmpty else { throw .empty }
        return digest
    }
}

public typealias Enricher = @Sendable (Transcript) async -> Digest?

public func enricher(_ summarizer: Summarizer, language: String?) -> Enricher {
    { transcript in
        do {
            return try await summarizer.digest(of: transcript.rendered, language: language)
        } catch {
            Log.error("no se pudo resumir con \(summarizer.name): \(error)")
            return nil
        }
    }
}
