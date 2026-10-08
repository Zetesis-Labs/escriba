import Foundation
import EscribaCore

public struct AnswerRequest: Sendable, Equatable {
    public let instructions: String?
    public let input: String
    public let schema: AnswerSchema?

    public init(instructions: String?, input: String, schema: AnswerSchema?) {
        self.instructions = instructions
        self.input = input
        self.schema = schema
    }
}

public enum AnswerError: Error, Equatable, CustomStringConvertible {
    case unavailable(String)
    case tooLong(model: String, characters: Int, capacity: Int)
    case empty
    case malformed(String)
    case failed(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): "el LLM no está disponible: \(reason)"
        case .tooLong(let model, let characters, let capacity):
            "la pregunta tiene \(characters) caracteres y \(model) admite \(capacity): pregunta sobre el resumen, recorta la entrada o usa un LLM remoto"
        case .empty: "el LLM no devolvió ninguna respuesta"
        case .malformed(let detail): "la respuesta del LLM no sirve: \(detail)"
        case .failed(let detail): "no se pudo preguntar al LLM: \(detail)"
        }
    }

    public static func catching<T>(_ body: () async throws -> T) async throws(AnswerError) -> T {
        do {
            return try await body()
        } catch let error as AnswerError {
            throw error
        } catch {
            throw AnswerError.failed("\(error)")
        }
    }
}

public struct Asker: Sendable {
    public let name: String
    public let capacity: Int
    public let availability: @Sendable () -> SummaryAvailability
    public let run: @Sendable (AnswerRequest) async throws(AnswerError) -> String

    public init(
        name: String,
        capacity: Int,
        availability: @escaping @Sendable () -> SummaryAvailability = { .ready },
        run: @escaping @Sendable (AnswerRequest) async throws(AnswerError) -> String
    ) {
        self.name = name
        self.capacity = capacity
        self.availability = availability
        self.run = run
    }
}

extension Asker {
    public func answer(_ request: AnswerRequest) async throws(AnswerError) -> DataValue {
        if case .unavailable(let reason) = availability() { throw .unavailable(reason) }
        let characters = (request.instructions?.count ?? 0) + request.input.count
        guard characters <= capacity else {
            throw .tooLong(model: name, characters: characters, capacity: capacity)
        }
        let raw = try await run(request)
        guard let schema = request.schema else {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw .empty }
            return .string(text)
        }
        do {
            return completingNulls(try answerObject(in: raw), for: schema)
        } catch {
            throw .malformed("\(error)")
        }
    }
}
