import Testing

@testable import EscribaCore

private let mapa = #"""
{"version":3,"sources":["proyecto:recetas/prueba/receta.ts"],"mappings":";;;;;;;;;;;;;;;;;;;;AAAA;AAAA;AAAA;AAAA;AAAA;AAAO,MAAM,SAAS,EAAE,QAAQ,SAAS;AAEzC,iBAAsB,MAAM,OAAgB,SAAkD;AAC5F,YAAQ,IAAI,MAAM;AAClB,UAAM,IAAY;AAClB,UAAM,IAAI,MAAM,wBAAwB;AAAA,EAC1C;","names":[]}
"""#

@Suite("Mapa de fuentes: del paquete compilado al TypeScript")
struct MapaDeFuentesTests {
    @Test("una posicion del paquete se traduce al fichero, linea y columna del TypeScript")
    func traduce() throws {
        let map = try #require(SourceMap(json: mapa))

        #expect(map.original(line: 30, column: 5) == SourcePosition(file: "recetas/prueba/receta.ts", line: 6, column: 3))
        #expect(map.original(line: 28, column: 5) == SourcePosition(file: "recetas/prueba/receta.ts", line: 4, column: 3))
        #expect(map.original(line: 30, column: 15) == SourcePosition(file: "recetas/prueba/receta.ts", line: 6, column: 13))
    }

    @Test("una posicion sin correspondencia, o un mapa roto, no inventa nada")
    func sinCorrespondencia() {
        #expect(SourceMap(json: mapa)?.original(line: 2, column: 1) == nil)
        #expect(SourceMap(json: mapa)?.original(line: 999, column: 1) == nil)
        #expect(SourceMap(json: "no es json") == nil)
    }

    @Test("la posicion se escribe como fichero:linea:columna")
    func texto() {
        #expect("\(SourcePosition(file: "recetas/a/receta.ts", line: 6, column: 3))" == "recetas/a/receta.ts:6:3")
    }
}
