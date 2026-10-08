import Foundation
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaSystemKit

private func carpeta() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-proyecto-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func escribir(_ texto: String, en ruta: String, dentro de: URL) throws {
    let url = de.appending(path: ruta)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try texto.write(to: url, atomically: true, encoding: .utf8)
}

private let herramientas = RecipeToolchain(
    compile: { ficheros, entrada in .compiled("compilado:\(ficheros[entrada] ?? "")", sourceMap: nil) },
    inspect: { _ in .valid(name: "Prueba") },
    fingerprint: { "h\($0.count)" })

@Suite("El proyecto de recetas en una carpeta de verdad")
struct ProyectoEnDiscoTests {
    @Test("la foto del proyecto incluye npm fijado y excluye lo que escribe Escriba y git")
    func foto() throws {
        let raiz = try carpeta()
        try escribir("export const a = 1", en: "recetas/a/receta.ts", dentro: raiz)
        try escribir("# notas", en: "AGENTS.md", dentro: raiz)
        try escribir("{}", en: ".escriba/estado.json", dentro: raiz)
        try escribir("ref", en: ".git/HEAD", dentro: raiz)
        try escribir("x", en: "node_modules/l/index.js", dentro: raiz)
        try escribir("{}", en: "package-lock.json", dentro: raiz)
        try escribir("", en: "recetas/.DS_Store", dentro: raiz)

        let foto = try folderRecipeProject(root: raiz, installed: raiz.appending(path: "../i.json")).snapshot()

        #expect(foto.paths == ["recetas/a/receta.ts", "AGENTS.md", "node_modules/l/index.js", "package-lock.json"])
        #expect(foto.sources["recetas/a/receta.ts"] == "export const a = 1")
    }

    @Test("al crear el proyecto en una carpeta vacia queda la plantilla en disco, y al compilar la receta de ejemplo instalada y el estado escrito")
    func deVacioAInstalada() async throws {
        let raiz = try carpeta()
        let instaladas = raiz.deletingLastPathComponent().appending(path: "instaladas-\(UUID().uuidString).json")
        let disco = folderRecipeProject(root: raiz, installed: instaladas)

        try createRecipeProject(disk: disco)
        let informe = try await rebuildRecipeProject(disk: disco, toolchain: herramientas, now: Date())

        for ruta in ["escriba-recetas.d.ts", "tsconfig.json", "AGENTS.md", "CLAUDE.md", ".gitignore",
                     "recetas/mi-receta/receta.ts", ".escriba/estado.json"] {
            #expect(FileManager.default.fileExists(atPath: raiz.appending(path: ruta).path(percentEncoded: false)), "\(ruta)")
        }
        #expect(informe.recipes.map(\.key) == ["mi-receta"])
        #expect(try disco.loadInstalled()["mi-receta"]?.name == "Prueba")
    }

    @Test("sin fichero de instaladas todavia, no hay ninguna")
    func sinInstaladas() throws {
        let raiz = try carpeta()

        #expect(try folderRecipeProject(root: raiz, installed: raiz.appending(path: "no/existe.json")).loadInstalled().isEmpty)
    }

    @Test("el vigilante observa npm y descarta cambios internos y git")
    func vigilante() {
        #expect(ignoredByRecipesWatch("/Users/r/recetas/.escriba/estado.json"))
        #expect(ignoredByRecipesWatch("/Users/r/recetas/.git/index"))
        #expect(!ignoredByRecipesWatch("/Users/r/recetas/node_modules/x/y.js"))
        #expect(!ignoredByRecipesWatch("/Users/r/recetas/package-lock.json"))
        #expect(ignoredByRecipesWatch("/Users/r/recetas/comun/.DS_Store"))
        #expect(!ignoredByRecipesWatch("/Users/r/recetas/recetas/general/receta.ts"))
    }
}
