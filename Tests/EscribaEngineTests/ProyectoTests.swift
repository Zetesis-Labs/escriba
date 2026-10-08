import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine

final class DiscoFalso: Sendable {
    private let ficheros: Mutex<[String: String]>
    private let instaladas = Mutex<[String: InstalledRecipe]>([:])
    let escrituras = Trace<String>()

    init(_ ficheros: [String: String] = [:]) {
        self.ficheros = Mutex(ficheros)
    }

    subscript(_ ruta: String) -> String? { ficheros.withLock { $0[ruta] } }
    func cambiar(_ ruta: String, _ contenido: String?) { ficheros.withLock { $0[ruta] = contenido } }
    var instaladasAhora: [String: InstalledRecipe] { instaladas.withLock { $0 } }

    var puerto: RecipeProjectDisk {
        RecipeProjectDisk(
            snapshot: {
                let todo = self.ficheros.withLock { $0 }
                return RecipeProjectSnapshot(paths: Set(todo.keys), sources: todo)
            },
            write: { ruta, contenido in
                self.escrituras.append(ruta)
                self.cambiar(ruta, contenido)
            },
            loadInstalled: { self.instaladas.withLock { $0 } },
            saveInstalled: { nuevas in self.instaladas.withLock { $0 = nuevas } })
    }
}

private let herramientas = RecipeToolchain(
    compile: { ficheros, entrada in
        guard let fuente = ficheros[entrada] else { return .failed([RecipeBuildIssue(text: "no existe \(entrada)")]) }
        if fuente.contains("ROMPE") {
            return .failed([RecipeBuildIssue(file: entrada, line: 1, column: 1, text: "roto a proposito")])
        }
        return .compiled("compilado:\(fuente)", sourceMap: nil)
    },
    inspect: { paquete in
        paquete.contains("SIN FLUJO") ? .invalid("falta la función flujo") : .valid(name: "Nombre de \(paquete.count)")
    },
    fingerprint: { "h\($0.count)" })

private let ahora = Date(timeIntervalSince1970: 1_000_000)

private func reconstruir(_ disco: DiscoFalso, _ fecha: Date = ahora) async throws -> RecipeBuildReport {
    try await rebuildRecipeProject(disk: disco.puerto, toolchain: herramientas, now: fecha)
}

private func creado() throws -> DiscoFalso {
    let disco = DiscoFalso()
    try createRecipeProject(disk: disco.puerto)
    return disco
}

private func estado(_ disco: DiscoFalso) throws -> [String: Any] {
    let texto = try #require(disco[".escriba/estado.json"])
    return try #require(try JSONSerialization.jsonObject(with: Data(texto.utf8)) as? [String: Any])
}

@Suite("Compilar el proyecto de recetas")
struct ProyectoTests {
    @Test("un proyecto recien creado tiene la plantilla, compila la receta de ejemplo y la instala")
    func proyectoNuevo() async throws {
        let disco = try creado()

        let informe = try await reconstruir(disco)

        #expect(disco["escriba-recetas.d.ts"] == RecipeTemplate.contract + "\n")
        #expect(disco["AGENTS.md"] != nil)
        #expect(informe.recipes.map(\.key) == ["mi-receta"])
        #expect(informe.recipes.first?.issues == [])
        #expect(disco.instaladasAhora["mi-receta"]?.source.hasPrefix("compilado:") == true)
        #expect((try estado(disco)["recetas"] as? [[String: Any]])?.first?["clave"] as? String == "mi-receta")
    }

    @Test("una receta que se rompe sigue con su ultimo paquete bueno y el estado dice donde falla")
    func seRompe() async throws {
        let disco = try creado()
        _ = try await reconstruir(disco)
        let buena = try #require(disco.instaladasAhora["mi-receta"])
        disco.cambiar("recetas/mi-receta/receta.ts", "ROMPE")

        let informe = try await reconstruir(disco, ahora.addingTimeInterval(60))

        #expect(disco.instaladasAhora["mi-receta"] == buena)
        #expect(informe.recipes.first?.active == buena.fingerprint)
        #expect(informe.recipes.first?.issues.first?.location == "recetas/mi-receta/receta.ts:1:1")
    }

    @Test("al arreglarla se instala la nueva")
    func seArregla() async throws {
        let disco = try creado()
        _ = try await reconstruir(disco)
        disco.cambiar("recetas/mi-receta/receta.ts", "ROMPE")
        _ = try await reconstruir(disco)
        disco.cambiar("recetas/mi-receta/receta.ts", "export const receta = { nombre: 'Otra' }")

        let informe = try await reconstruir(disco, ahora.addingTimeInterval(120))

        #expect(informe.recipes.first?.issues == [])
        #expect(disco.instaladasAhora["mi-receta"]?.installedAt == ahora.addingTimeInterval(120))
    }

    @Test("un paquete que no valida no se instala y el estado lo explica")
    func noValida() async throws {
        let disco = DiscoFalso(["escriba-recetas.d.ts": "x", "recetas/vacia/receta.ts": "SIN FLUJO"])

        let informe = try await reconstruir(disco)

        #expect(disco.instaladasAhora["vacia"] == nil)
        #expect(informe.recipes.first { $0.key == "vacia" }?.issues.map(\.text) == ["falta la función flujo"])
        #expect(informe.recipes.first { $0.key == "vacia" }?.issues.first?.file == "recetas/vacia/receta.ts")
    }

    @Test("compilar no toca la plantilla: una vez creado, el proyecto es del usuario")
    func compilarNoEscribePlantilla() async throws {
        let disco = try creado()
        disco.cambiar("AGENTS.md", "mis notas")
        disco.cambiar("escriba-recetas.d.ts", "interface Mio {}")
        disco.cambiar("CLAUDE.md", nil)

        _ = try await reconstruir(disco)

        #expect(disco["AGENTS.md"] == "mis notas")
        #expect(disco["escriba-recetas.d.ts"] == "interface Mio {}")
        #expect(disco["CLAUDE.md"] == nil)
    }

    @Test("crear un proyecto donde ya hay uno no escribe nada")
    func crearSobreProyecto() throws {
        let disco = DiscoFalso(["escriba-recetas.d.ts": "interface Mio {}", "recetas/a/receta.ts": "x"])

        #expect(try createRecipeProject(disk: disco.puerto).isEmpty)
        #expect(disco.escrituras.values.isEmpty)
    }

    @Test("una receta borrada del proyecto deja de estar instalada")
    func recetaBorrada() async throws {
        let disco = try creado()
        _ = try await reconstruir(disco)
        disco.cambiar("recetas/mi-receta/receta.ts", nil)

        let informe = try await reconstruir(disco)

        #expect(informe.recipes.isEmpty)
        #expect(disco.instaladasAhora.isEmpty)
    }

    @Test("recompilar sin cambios solo reescribe el estado")
    func sinCambios() async throws {
        let disco = try creado()
        _ = try await reconstruir(disco)
        let antes = disco.escrituras.count

        _ = try await reconstruir(disco)

        #expect(Array(disco.escrituras.values.dropFirst(antes)) == [".escriba/estado.json"])
    }

    @Test("el compilador recibe npm junto al código y excluye los ficheros internos")
    func sinIgnorados() async throws {
        let vistos = Trace<String>()
        let disco = DiscoFalso([
            "escriba-recetas.d.ts": "x", "recetas/a/receta.ts": "ok", "comun/x.ts": "ok",
            ".escriba/estado.json": "{}", ".git/HEAD": "ref", "node_modules/l/index.js": "x",
        ])
        let espia = RecipeToolchain(
            compile: { ficheros, entrada in
                vistos.append(ficheros.keys.sorted().joined(separator: ","))
                return try await herramientas.compile(ficheros, entrada)
            },
            inspect: herramientas.inspect, fingerprint: herramientas.fingerprint)

        _ = try await rebuildRecipeProject(disk: disco.puerto, toolchain: espia, now: ahora)

        let rutas = Set((vistos.values.first ?? "").split(separator: ",").map(String.init))
        #expect(rutas.isDisjoint(with: [".escriba/estado.json", ".git/HEAD"]))
        #expect(rutas.contains("node_modules/l/index.js"))
        #expect(rutas.isSuperset(of: ["recetas/a/receta.ts", "comun/x.ts"]))
    }
}
