#if canImport(FoundationModels)
import Foundation
import FoundationModels
import EscribaCore
import EscribaEngine

extension AppleIntelligence {
    public static let answerTokens = 1500

    public static func asker(capacity: Int = capacity) -> Asker {
        Asker(name: name, capacity: capacity, availability: availability) { request throws(AnswerError) in
            try await AnswerError.catching {
                let session = LanguageModelSession(
                    model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
                    instructions: request.instructions)
                let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: answerTokens)
                guard let schema = request.schema else {
                    return try await session.respond(to: request.input, options: options).content
                }
                let generation = try GenerationSchema(root: dynamicSchema(schema, name: "Respuesta"), dependencies: [])
                return try await session.respond(to: request.input, schema: generation, options: options)
                    .content.jsonString
            }
        }
    }
}

func dynamicSchema(_ schema: AnswerSchema, name: String) -> DynamicGenerationSchema {
    switch schema.kind {
    case .string(let choices?):
        return DynamicGenerationSchema(name: name, description: schema.description, anyOf: choices)
    case .string(nil):
        return DynamicGenerationSchema(type: String.self)
    case .number:
        return DynamicGenerationSchema(type: Double.self)
    case .integer:
        return DynamicGenerationSchema(type: Int.self)
    case .boolean:
        return DynamicGenerationSchema(type: Bool.self)
    case .array(let items, let minimum, let maximum):
        return DynamicGenerationSchema(
            arrayOf: dynamicSchema(items, name: name + "_elemento"), minimumElements: minimum, maximumElements: maximum)
    case .object(let properties):
        return DynamicGenerationSchema(
            name: name, description: schema.description,
            properties: properties.map { property in
                DynamicGenerationSchema.Property(
                    name: property.name, description: property.schema.description,
                    schema: dynamicSchema(property.schema, name: name + "_" + property.name),
                    isOptional: property.schema.nullable || !property.required)
            })
    }
}
#endif
