#if canImport(FoundationModels)
import Foundation
import FoundationModels
import EscribaCore
import EscribaEngine

@Generable
struct GeneratedDigest {
    @Guide(description: "Título breve y concreto de la grabación, sin comillas ni punto final")
    var title: String

    @Guide(description: "Resumen fiel del contenido, de tres a seis frases")
    var summary: String

    @Guide(description: "Temas principales, en minúsculas y de una o dos palabras", .count(2...5))
    var tags: [String]
}

public enum AppleIntelligence {
    public static let name = "Apple Intelligence"
    public static let capacity = 3500

    public static func availability() -> SummaryAvailability {
        reason(SystemLanguageModel.default.availability)
    }

    public static func summarizer(capacity: Int = capacity) -> Summarizer {
        Summarizer(name: name, capacity: capacity, availability: availability) {
            request throws(SummaryError) in
            try await SummaryError.catching {
                let session = LanguageModelSession(
                    model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                    instructions: request.instructions)
                let response = try await session.respond(
                    to: request.prompt,
                    generating: GeneratedDigest.self,
                    options: GenerationOptions(temperature: 0.2))
                return Digest(
                    title: response.content.title,
                    summary: response.content.summary,
                    tags: response.content.tags)
            }
        }
    }
}

func reason(_ availability: SystemLanguageModel.Availability) -> SummaryAvailability {
    switch availability {
    case .available:
        return .ready
    case .unavailable(let why):
        switch why {
        case .deviceNotEligible:
            return .unavailable("este Mac no admite Apple Intelligence")
        case .appleIntelligenceNotEnabled:
            return .unavailable("Apple Intelligence está apagado en Ajustes del Sistema")
        case .modelNotReady:
            return .unavailable("el modelo del sistema aún se está descargando")
        @unknown default:
            return .unavailable("el modelo del sistema no está disponible")
        }
    }
}
#endif
