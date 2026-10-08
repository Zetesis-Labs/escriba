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

@Suite("Traza en texto plano, para copiarla")
struct TrazaEnTextoTests {
    @Test("la traza se copia con su cabecera, sus pasos, su log y su error")
    func texto() {
        let traza = RecipeTrace(
            recipe: "mi-receta", name: "Mi receta", fingerprint: "8105438abc",
            steps: [
                RecipeStep(capability: "transcribir", detail: "WhisperKit · ES", seconds: 1.25, error: nil, origin: "Por defecto"),
                RecipeStep(capability: "publicar", detail: "Notion", seconds: 0.4, error: "sin red"),
            ],
            logs: [
                RecipeLogLine(level: .info, text: "hola", origin: nil, seconds: 0),
                RecipeLogLine(level: .warn, text: "ojo", origin: "Por defecto", seconds: 1.5),
            ],
            error: "la receta falló: sin red", seconds: 2, data: #"{"cliente":"Acme"}"#)

        #expect(recipeTraceText(traza) == """
            Receta «Mi receta» · 8105438 · falló · 2,0 s
            ✓ Por defecto › transcribir · WhisperKit · ES (1,3 s)
            ✗ publicar · Notion (0,4 s): sin red
            +0,0 s hola
            +1,5 s aviso Por defecto › ojo
            Datos: {"cliente":"Acme"}
            Error: la receta falló: sin red
            """)
    }

    @Test("los datos guardados viajan con la traza y una traza vieja, sin ellos, se sigue leyendo")
    func datosEnLaTraza() throws {
        let traza = RecipeTrace(recipe: "x", fingerprint: "f", steps: [], logs: [], error: nil, data: #"{"a":1}"#)
        let leida = try JSONDecoder().decode(RecipeTrace.self, from: try JSONEncoder().encode(traza))
        let vieja = try JSONDecoder().decode(
            RecipeTrace.self, from: Data(#"{"recipe":"x","fingerprint":"f","steps":[],"logs":[]}"#.utf8))

        #expect(leida.data == #"{"a":1}"#)
        #expect(vieja.data == nil)
    }
}
