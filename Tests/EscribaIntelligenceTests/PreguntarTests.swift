#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Testing
import EscribaCore

@testable import EscribaEngine
@testable import EscribaIntelligence

private let reunion = #"""
{"type":"object","properties":{"cliente":{"description":"La empresa","type":["string","null"]},"tareas":{"minItems":1,"maxItems":5,"type":"array","items":{"type":"string"}},"urgente":{"type":"boolean"},"tipo":{"type":"string","enum":["reunion","idea"]},"personas":{"type":"integer"},"contacto":{"anyOf":[{"type":"object","properties":{"nombre":{"type":"string"},"email":{"type":"string"}},"required":["nombre","email"],"additionalProperties":false},{"type":"null"}]}},"required":["cliente","tareas","urgente","tipo","contacto"],"additionalProperties":false}
"""#

@Suite("Preguntar al modelo del sistema con un esquema construido al vuelo")
struct PreguntarAppleTests {
    @Test("el esquema de Zod se convierte en un esquema de generación válido, con objetos anidados")
    func esquemaValido() throws {
        let esquema = try answerSchema(from: try parseData(reunion))

        let generacion = try GenerationSchema(root: dynamicSchema(esquema, name: "Respuesta"), dependencies: [])

        let descrito = "\(generacion)"
        for campo in ["cliente", "tareas", "urgente", "tipo", "personas", "contacto", "nombre", "email"] {
            #expect(descrito.contains(campo), "\(campo)")
        }
    }

    @Test("responde de verdad con el modelo del sistema y la respuesta casa con el esquema")
    func enVivo() async throws {
        guard ProcessInfo.processInfo.environment["ESCRIBA_PREGUNTAR_EN_VIVO"] != nil else { return }
        let preguntador = AppleIntelligence.asker()
        guard preguntador.availability().isReady else { return }
        let esquema = try answerSchema(from: try parseData(reunion))

        let empezado = Date()
        let respuesta = try await preguntador.answer(AnswerRequest(
            instructions: "Extrae los datos de la reunión. Si algo no se dice, déjalo vacío.",
            input: "Reunión con Ana García de Acme. Hay que enviarle el presupuesto y llamar al proveedor antes del viernes. Es urgente.",
            schema: esquema))
        print("respuesta en \(String(format: "%.1f", Date().timeIntervalSince(empezado))) s: \(dataText(respuesta))")

        guard case .object(let campos) = respuesta else {
            Issue.record("no es un objeto")
            return
        }
        #expect(campos.map(\.name).starts(with: ["cliente", "tareas", "urgente", "tipo"]))
        #expect(respuesta["urgente"] == .bool(true))
    }
}
#endif
