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

    @Test("una carpeta sin proyecto recibe la plantilla entera, con una receta de ejemplo")
    func plantillaNueva() {
        let escritos = templateWrites(paths: [])

        #expect(Set(escritos.map(\.path)) == [
            "escriba-recetas.d.ts", "tsconfig.json", "AGENTS.md", "CLAUDE.md", ".gitignore",
            "recetas/mi-receta/receta.ts",
        ])
        #expect(escritos.first { $0.path == "CLAUDE.md" }?.contents == "@AGENTS.md\n")
        #expect(escritos.first { $0.path == ".gitignore" }?.contents.contains(".escriba/") == true)
        #expect(escritos.first { $0.path == "escriba-recetas.d.ts" }?.contents == RecipeTemplate.contract + "\n")
    }

    @Test("la receta de ejemplo es «Por defecto» con otro nombre: trae su formulario de Zod para tocarlo")
    func ejemploComoPorDefecto() throws {
        let ejemplo = try #require(templateWrites(paths: []).first { $0.path == "recetas/mi-receta/receta.ts" })

        #expect(ejemplo.contents.contains(#"export const receta = { nombre: "Mi receta" }"#))
        #expect(ejemplo.contents.contains("export function \(recipeFormExport)("))
        #expect(ejemplo.contents.contains("escriba: Escriba<Parametros>"))
    }

    @Test("una carpeta con algo dentro recibe la plantilla sin pisar lo que ya habia")
    func carpetaConCosas() {
        let escritos = templateWrites(paths: ["README.md", "AGENTS.md"])

        #expect(!escritos.map(\.path).contains("AGENTS.md"))
        #expect(escritos.map(\.path).contains("escriba-recetas.d.ts"))
    }

    @Test("un proyecto que ya existe no recibe nada: la plantilla se escribe solo al crearlo")
    func proyectoExistente() {
        #expect(templateWrites(paths: ["escriba-recetas.d.ts"]).isEmpty)
        #expect(templateWrites(paths: ["escriba-recetas.d.ts", "recetas/a/receta.ts"]).isEmpty)
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

    @Test("cada receta se resume en una linea: compilada, o el error y con que paquete sigue")
    func lineaDeEstado() {
        #expect(recipeStatusLine(RecipeStatus(key: "a", name: "A", active: "1a2b3c4d5e", activeSince: antes, issues: []))
            == "compilada · 1a2b3c4")
        #expect(recipeStatusLine(RecipeStatus(key: "a", name: "A", active: "1a2b3c4d5e", activeSince: antes, issues: [fallo]))
            == "error en recetas/general/receta.ts:3:8: Expected \"}\" · sigue con 1a2b3c4")
        #expect(recipeStatusLine(RecipeStatus(key: "a", name: nil, active: nil, activeSince: nil, issues: [RecipeBuildIssue(text: "roto")]))
            == "error: roto · sin paquete")
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
