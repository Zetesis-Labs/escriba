import Foundation
import Testing

@testable import EscribaCore

@Suite("Traza de una ejecucion: log con niveles, resultado y recetas")
struct TrazaDeRecetaTests {
    @Test("una traza guardada antes de los niveles se lee con su log como info y su resultado deducido")
    func trazaVieja() throws {
        let bien = #"{"recipe":"por-defecto","fingerprint":"abc","steps":[],"logs":["hola"],"error":null}"#
        let mal = #"{"recipe":"por-defecto","fingerprint":"abc","steps":[],"logs":[],"error":"se rompio"}"#

        let leida = try JSONDecoder().decode(RecipeTrace.self, from: Data(bien.utf8))
        let fallida = try JSONDecoder().decode(RecipeTrace.self, from: Data(mal.utf8))

        #expect(leida.logs == [RecipeLogLine(level: .info, text: "hola", origin: nil, seconds: 0)])
        #expect(leida.outcome == .ok)
        #expect(leida.recipes == ["por-defecto"])
        #expect(leida.startedAt == nil)
        #expect(fallida.outcome == .failed)
    }

    @Test("una traza nueva se guarda y se vuelve a leer igual")
    func idaYVuelta() throws {
        let traza = RecipeTrace(
            recipe: "reparto", name: "Reparto", fingerprint: "abc",
            steps: [RecipeStep(capability: "receta", detail: "Reuniones", seconds: 1.5, error: nil)],
            logs: [RecipeLogLine(level: .warn, text: "ojo", origin: "Reuniones", seconds: 0.4)],
            error: "motor caido", outcome: .waiting, recipes: ["reparto", "F1"],
            startedAt: Date(timeIntervalSince1970: 1_000), seconds: 2.5)

        let leida = try JSONDecoder().decode(RecipeTrace.self, from: try JSONEncoder().encode(traza))

        #expect(leida == traza)
    }

    @Test("sin decir otra cosa, una traza sin error salio bien y solo paso por su receta")
    func porDefecto() {
        let traza = RecipeTrace(recipe: "x", fingerprint: "abc", steps: [], logs: [], error: nil)

        #expect(traza.outcome == .ok)
        #expect(traza.recipes == ["x"])
    }
}
