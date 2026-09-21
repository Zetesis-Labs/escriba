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
    case failed(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): "el modelo de lenguaje no esta disponible: \(reason)"
        case .nothingToSummarize: "no hay texto que resumir"
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

extension Summarizer {
    public func digest(of text: String, language: String?) async throws(SummaryError) -> Digest {
        if case .unavailable(let reason) = availability() { throw .unavailable(reason) }
        let chunks = digestChunks(of: text, maxCharacters: capacity)
        guard !chunks.isEmpty else { throw .nothingToSummarize }

        guard chunks.count > 1 else {
            return normalizedDigest(try await run(digestRequest(text: chunks[0], language: language)))
        }

        var partials: [String] = []
        for chunk in chunks {
            let partial = normalizedDigest(try await run(digestRequest(text: chunk, language: language)))
            partials.append(partial.rendered)
        }
        return normalizedDigest(try await run(reduceRequest(partials: partials, language: language)))
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
