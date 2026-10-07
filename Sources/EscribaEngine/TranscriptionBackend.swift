import Foundation
import EscribaCore

public enum TranscriptionError: Error, CustomStringConvertible {
    case backendUnavailable(String)
    case failed(String)
    case timedOut(TimeInterval)
    case modelMissing(model: String, installed: [String])

    public var description: String {
        switch self {
        case .backendUnavailable(let detail): "backend de transcripcion no disponible: \(detail)"
        case .failed(let detail): "la transcripcion fallo: \(detail)"
        case .timedOut(let seconds): "la transcripcion excedio \(Int(seconds))s"
        case .modelMissing(let model, let installed):
            "el modelo \(model) no esta instalado."
                + " Disponibles: \(installed.joined(separator: ", "))"
        }
    }

    public var isBackendUnavailable: Bool {
        if case .backendUnavailable = self { return true }
        return false
    }

    public static func catching<T>(_ body: () throws -> T) throws(TranscriptionError) -> T {
        do {
            return try body()
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.failed("\(error)")
        }
    }

    public static func catching<T>(
        _ body: () async throws -> T
    ) async throws(TranscriptionError) -> T {
        do {
            return try await body()
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.failed("\(error)")
        }
    }
}

public struct TranscriptionBackend: Sendable {
    public let name: String
    public let transcribe: @Sendable (URL) async throws(TranscriptionError) -> Transcript
    public let preflight: @Sendable () throws(TranscriptionError) -> Void
    public let route: @Sendable (URL) -> String

    public init(
        name: String,
        transcribe: @escaping @Sendable (URL) async throws(TranscriptionError) -> Transcript,
        preflight: @escaping @Sendable () throws(TranscriptionError) -> Void = {},
        route: (@Sendable (URL) -> String)? = nil
    ) {
        self.name = name
        self.transcribe = transcribe
        self.preflight = preflight
        self.route = route ?? { _ in name }
    }
}
