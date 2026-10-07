import Foundation
import Testing

@testable import EscribaCore

private let deHoy = DefaultRecipeSettings(
    stt: "whisper", language: "es", detectSpeakers: false, speakerCount: nil, summarize: true, llm: "apple",
    prompt: nil, connectors: ["K1", "K2"])

private let conGroq = DefaultRecipeSettings(
    stt: "U1", language: nil, detectSpeakers: false, speakerCount: nil, summarize: true, llm: "U2",
    prompt: "Tres viñetas", connectors: [])

private func instalada(_ key: String, _ name: String) -> InstalledRecipe {
    InstalledRecipe(key: key, name: name, source: "/* \(key) */", fingerprint: "f-\(key)", installedAt: Date())
}

@Suite("Libro de recetas: una lista de formulario y de código, con una por defecto")
struct LibroDeRecetasTests {
    @Test("la primera vez nace una receta de formulario «Por defecto» con los ajustes que habia, y es la por defecto")
    func migracion() {
        let libro = RecipeBook(migrating: deHoy, key: "F1")

        #expect(libro.forms == [FormRecipe(key: "F1", name: "Por defecto", settings: deHoy)])
        #expect(libro.defaultKey == "F1")
    }

    @Test("añadir una de formulario le da un nombre que no se repite y no cambia la por defecto")
    func anadir() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")

        let primera = libro.add(key: "F2", name: "Receta nueva", settings: deHoy)
        let segunda = libro.add(key: "F3", name: "Receta nueva", settings: deHoy)

        #expect(primera.name == "Receta nueva")
        #expect(segunda.name == "Receta nueva 2")
        #expect(libro.forms.map(\.key) == ["F1", "F2", "F3"])
        #expect(libro.defaultKey == "F1")
    }

    @Test("duplicar copia los parametros con otra clave y un nombre que dice que es copia")
    func duplicar() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")

        let copia = libro.duplicate("F1", as: "F2")
        let otra = libro.duplicate("F1", as: "F3")
        let ninguna = libro.duplicate("NO", as: "F4")

        #expect(copia == FormRecipe(key: "F2", name: "Por defecto (copia)", settings: deHoy))
        #expect(otra?.name == "Por defecto (copia) 2")
        #expect(ninguna == nil)
    }

    @Test("renombrar cambia el nombre y no la clave; un nombre en blanco no se acepta")
    func renombrar() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")

        libro.rename("F1", to: "  Reuniones ")
        #expect(libro.forms[0].name == "Reuniones")
        #expect(libro.forms[0].key == "F1")

        libro.rename("F1", to: "   ")
        #expect(libro.forms[0].name == "Reuniones")
    }

    @Test("cambiar los parametros de una no toca las demas")
    func parametros() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Groq", settings: deHoy)

        libro.update("F2", settings: conGroq)

        #expect(libro.form("F1")?.settings == deHoy)
        #expect(libro.form("F2")?.settings == conGroq)
    }

    @Test("quitar la por defecto pasa la por defecto a la primera de formulario, y la ultima de formulario no se quita")
    func quitar() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Reuniones", settings: deHoy)

        libro.remove("F1")
        #expect(libro.forms.map(\.key) == ["F2"])
        #expect(libro.defaultKey == "F2")

        libro.remove("F2")
        #expect(libro.forms.map(\.key) == ["F2"])
    }

    @Test("quitar una de formulario que no es la por defecto deja la por defecto donde estaba, aunque sea de codigo")
    func quitarOtra() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Reuniones", settings: deHoy)
        libro.makeDefault("ideas")

        libro.remove("F2")

        #expect(libro.defaultKey == "ideas")
    }

    @Test("la lista junta las de formulario y las de codigo, y marca la por defecto")
    func lista() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Reuniones", settings: deHoy)
        libro.makeDefault("ideas")

        let lista = libro.listing(code: [
            RecipeCodeEntry(key: "ideas", name: "Ideas"),
            RecipeCodeEntry(key: "rota", name: nil),
        ])

        #expect(lista == [
            RecipeListing(key: "F1", name: "Por defecto", kind: .form, isDefault: false),
            RecipeListing(key: "F2", name: "Reuniones", kind: .form, isDefault: false),
            RecipeListing(key: "ideas", name: "Ideas", kind: .code, isDefault: true),
            RecipeListing(key: "rota", name: "rota", kind: .code, isDefault: false),
        ])
    }

    @Test("una receta se resuelve: la de formulario con sus parametros, la de codigo con su paquete, y si no hay paquete dice cual falta")
    func resolver() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        let instaladas = ["ideas": instalada("ideas", "Ideas")]

        #expect(libro.resolve(libro.defaultKey, installed: instaladas) == .form(libro.forms[0]))

        libro.makeDefault("ideas")
        #expect(libro.resolve(libro.defaultKey, installed: instaladas) == .code(instaladas["ideas"]!))

        libro.makeDefault("borrada")
        #expect(libro.resolve(libro.defaultKey, installed: instaladas) == .missing("borrada"))
    }

    @Test("quitar un resolutor devuelve al local todas las recetas de formulario que lo usaban")
    func resolutorQuitado() {
        var libro = RecipeBook(migrating: conGroq, key: "F1")
        libro.add(key: "F2", name: "Otra", settings: conGroq)

        let sinGroq = libro.forgettingResolver("U1", stt: "whisper", llm: "apple")

        #expect(sinGroq.forms.map(\.settings.stt) == ["whisper", "whisper"])
        #expect(sinGroq.forms.map(\.settings.llm) == ["U2", "U2"])
    }

    @Test("se guarda y se vuelve a leer igual")
    func idaYVuelta() throws {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Groq", settings: conGroq)
        libro.makeDefault("F2")

        let leido = try JSONDecoder().decode(RecipeBook.self, from: try JSONEncoder().encode(libro))

        #expect(leido == libro)
    }

    @Test("un libro guardado sin recetas de formulario se lee con una «Por defecto» de serie")
    func lecturaTolerante() throws {
        let guardado = #"{"forms":[],"defaultKey":"ideas"}"#

        let leido = try JSONDecoder().decode(RecipeBook.self, from: Data(guardado.utf8))

        #expect(leido.forms.map(\.name) == ["Por defecto"])
        #expect(leido.defaultKey == "ideas")
    }

    @Test("las recetas llegan a JavaScript con clave, nombre y tipo")
    func contrato() throws {
        let json = try recipeJSON([
            RecipeInfo(key: "F1", name: "Por defecto", kind: .form),
            RecipeInfo(key: "ideas", name: "Ideas", kind: .code),
        ])

        let objetos = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]]

        #expect(objetos == [
            ["clave": "F1", "nombre": "Por defecto", "tipo": "formulario"],
            ["clave": "ideas", "nombre": "Ideas", "tipo": "codigo"],
        ])
    }
}
