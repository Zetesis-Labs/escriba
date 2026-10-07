import Foundation
import Testing

@testable import EscribaCore

private let ahora = Date(timeIntervalSince1970: 1_000_000)
private let antes = Date(timeIntervalSince1970: 500_000)

private func instalada(_ huella: String, desde: Date = antes) -> InstalledRecipe {
    InstalledRecipe(key: "general", name: "General", source: "js \(huella)", fingerprint: huella, installedAt: desde)
}

private let fallo = RecipeBuildIssue(file: "recetas/general/receta.ts", line: 3, column: 8, text: "Expected \"}\"")

@Suite("El proyecto de recetas")
struct ProyectoRecetasTests {
    @Test("una receta es recetas/<clave>/receta.ts o .js; lo demas es codigo compartido")
    func claves() {
        let rutas: Set<String> = [
            "recetas/general/receta.ts", "recetas/general/util.ts", "recetas/otra/receta.js",
            "comun/glosario.ts", "recetas/receta.ts", "recetas/a/b/receta.ts", "escriba-recetas.d.ts",
        ]

        #expect(recipeKeys(in: rutas) == ["general", "otra"])
    }

    @Test("lo que escribe Escriba, git y node_modules no cuentan como cambios del proyecto")
    func ignorados() {
        #expect(ignoredByRecipes(".escriba/estado.json"))
        #expect(ignoredByRecipes(".git/HEAD"))
        #expect(ignoredByRecipes("node_modules/lodash/index.js"))
        #expect(ignoredByRecipes(".DS_Store"))
        #expect(!ignoredByRecipes("recetas/general/receta.ts"))
        #expect(!ignoredByRecipes("comun/.escriba.ts"))
    }

    @Test("un proyecto vacio recibe la plantilla entera y una receta de ejemplo")
    func plantillaNueva() {
        let escritos = templateWrites(paths: [], contents: [:])

        #expect(Set(escritos.map(\.path)) == [
            "escriba-recetas.d.ts", "tsconfig.json", "AGENTS.md", "CLAUDE.md", ".gitignore",
            "recetas/mi-receta/receta.ts",
        ])
        #expect(escritos.first { $0.path == "CLAUDE.md" }?.contents == "@AGENTS.md\n")
        #expect(escritos.first { $0.path == ".gitignore" }?.contents.contains(".escriba/") == true)
        #expect(escritos.first { $0.path == "escriba-recetas.d.ts" }?.contents == RecipeTemplate.contract + "\n")
    }

    @Test("el contrato y el tsconfig se reescriben si cambian; lo que edita el usuario, nunca")
    func plantillaExistente() {
        let rutas: Set<String> = [
            "escriba-recetas.d.ts", "tsconfig.json", "AGENTS.md", "CLAUDE.md", ".gitignore",
            "recetas/propia/receta.ts",
        ]
        let contenidos = [
            "escriba-recetas.d.ts": "interface Viejo {}",
            "tsconfig.json": RecipeTemplate.tsconfig + "\n",
        ]

        #expect(templateWrites(paths: rutas, contents: contenidos).map(\.path) == ["escriba-recetas.d.ts"])
    }

    @Test("la receta de ejemplo no vuelve si el usuario ya tenia proyecto y la borro")
    func ejemploBorrado() {
        let rutas: Set<String> = ["escriba-recetas.d.ts", "tsconfig.json", "AGENTS.md", "CLAUDE.md", ".gitignore"]
        let contenidos = [
            "escriba-recetas.d.ts": RecipeTemplate.contract + "\n", "tsconfig.json": RecipeTemplate.tsconfig + "\n",
        ]

        #expect(templateWrites(paths: rutas, contents: contenidos).isEmpty)
    }

    @Test("una receta que compila por primera vez se instala")
    func primeraVez() {
        let paso = nextInstalled(
            key: "general", previous: nil,
            outcome: .valid(name: "General", source: "js nuevo", fingerprint: "nuevo"), now: ahora)

        #expect(paso.installed == InstalledRecipe(
            key: "general", name: "General", source: "js nuevo", fingerprint: "nuevo", installedAt: ahora))
        #expect(paso.status == RecipeStatus(key: "general", name: "General", active: "nuevo", activeSince: ahora, issues: []))
    }

    @Test("una receta que deja de compilar sigue con su ultimo paquete bueno, y el estado dice por que")
    func ultimoBueno() {
        let paso = nextInstalled(key: "general", previous: instalada("viejo"), outcome: .failed([fallo]), now: ahora)

        #expect(paso.installed == instalada("viejo"))
        #expect(paso.status == RecipeStatus(
            key: "general", name: "General", active: "viejo", activeSince: antes, issues: [fallo]))
    }

    @Test("una receta que nunca ha compilado no tiene paquete, ni uno vacio")
    func nuncaCompilo() {
        let paso = nextInstalled(key: "general", previous: nil, outcome: .failed([fallo]), now: ahora)

        #expect(paso.installed == nil)
        #expect(paso.status == RecipeStatus(key: "general", name: nil, active: nil, activeSince: nil, issues: [fallo]))
    }

    @Test("al arreglarla, la nueva sustituye a la vieja")
    func arreglada() {
        let paso = nextInstalled(
            key: "general", previous: instalada("viejo"),
            outcome: .valid(name: "General 2", source: "js nuevo", fingerprint: "nuevo"), now: ahora)

        #expect(paso.installed?.fingerprint == "nuevo")
        #expect(paso.status.issues.isEmpty)
        #expect(paso.status.name == "General 2")
    }

    @Test("compilar lo mismo otra vez no cambia desde cuando esta activa")
    func mismaHuella() {
        let paso = nextInstalled(
            key: "general", previous: instalada("igual"),
            outcome: .valid(name: "General", source: "js igual", fingerprint: "igual"), now: ahora)

        #expect(paso.installed == instalada("igual"))
        #expect(paso.status.activeSince == antes)
    }

    @Test("el estado se escribe con los nombres que lee un agente")
    func estadoJSON() throws {
        let informe = RecipeBuildReport(
            builtAt: ahora,
            recipes: [RecipeStatus(key: "general", name: "General", active: "viejo", activeSince: antes, issues: [fallo])])

        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(try recipeBuildReportJSON(informe).utf8)) as? [String: Any])
        let receta = try #require((json["recetas"] as? [[String: Any]])?.first)
        let error = try #require((receta["errores"] as? [[String: Any]])?.first)

        #expect(json["compiladoEn"] as? String == "1970-01-12T13:46:40Z")
        #expect(receta["clave"] as? String == "general")
        #expect(receta["activa"] as? String == "viejo")
        #expect(receta["activaDesde"] as? String == "1970-01-06T18:53:20Z")
        #expect(error["fichero"] as? String == "recetas/general/receta.ts")
        #expect(error["linea"] as? Int == 3)
        #expect(error["columna"] as? Int == 8)
        #expect(error["texto"] as? String == "Expected \"}\"")
    }
}
