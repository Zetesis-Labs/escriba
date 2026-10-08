import Foundation
import Testing

@testable import EscribaCore

private let deHoy = DefaultRecipeSettings(
    stt: "whisper", language: "es", detectSpeakers: false, speakerCount: nil, summarize: true, llm: "apple",
    prompt: nil, connectors: ["K1", "K2"])

private let conGroq = DefaultRecipeSettings(
    stt: "U1", language: nil, detectSpeakers: true, speakerCount: 2, summarize: true, llm: "U2",
    prompt: "Tres viñetas", connectors: [])

private func instalada(_ key: String, _ name: String) -> InstalledRecipe {
    InstalledRecipe(key: key, name: name, source: "/* \(key) */", fingerprint: "f-\(key)", installedAt: Date())
}

private func valores(_ libro: RecipeBook, _ clave: String) throws -> DataValue? {
    try libro.values[clave].map { try parseData($0) }
}

private let guardadoAntes = #"""
    {"defaultKey": "mi-receta", "values": {}, "forms": [{"settings": {"idioma": "es", "stt": "whisper", "resumir": true,
    "conectores": ["03823BB9-D0D1-4D90-9440-00711AEC3D9A", "3DD3155B-1F5C-459D-BEF0-9B682167F9CA"], "prompt": null,
    "hablantes": {"cuantos": null, "detectar": false}, "llm": "apple"}, "key": "826A5CE2-1951-410E-8784-AC847FDBB665",
    "name": "Por defecto"}]}
    """#

@Suite("Libro de recetas: una lista de formulario y de código, con una por defecto")
struct LibroDeRecetasTests {
    @Test("los ajustes de una receta de formulario son sus valores, en el orden del esquema de «Por defecto»")
    func valoresDeAjustes() throws {
        #expect(dataText(formRecipeValues(conGroq)) == #"{"stt":"U1","idioma":null,"hablantes":{"detectar":true,"cuantos":2},"#
            + #""resumir":true,"llm":"U2","prompt":"Tres viñetas","conectores":[]}"#)
    }

    @Test("la primera vez nace una receta de formulario «Por defecto» con los ajustes que había, y es la por defecto")
    func migracion() throws {
        let libro = RecipeBook(migrating: deHoy, key: "F1")

        #expect(libro.forms == [FormRecipe(key: "F1", name: "Por defecto")])
        #expect(libro.defaultKey == "F1")
        #expect(try valores(libro, "F1") == formRecipeValues(deHoy))
    }

    @Test("un libro guardado con los ajustes de antes los convierte en valores y no pierde ninguna receta")
    func libroDeAntes() throws {
        let leido = try JSONDecoder().decode(RecipeBook.self, from: Data(guardadoAntes.utf8))

        #expect(leido.forms == [FormRecipe(key: "826A5CE2-1951-410E-8784-AC847FDBB665", name: "Por defecto")])
        #expect(leido.defaultKey == "mi-receta")
        #expect(leido.values["826A5CE2-1951-410E-8784-AC847FDBB665"] == #"{"stt":"whisper","idioma":"es","#
            + #""hablantes":{"detectar":false,"cuantos":null},"resumir":true,"llm":"apple","prompt":null,"#
            + #""conectores":["03823BB9-D0D1-4D90-9440-00711AEC3D9A","3DD3155B-1F5C-459D-BEF0-9B682167F9CA"]}"#)
    }

    @Test("en un libro de antes con varias recetas, cada una migra o conserva lo suyo, y ninguna se pierde aunque sus ajustes no se lean")
    func libroDeAntesMixto() throws {
        let guardado = #"{"defaultKey":"B","values":{"B":"{\"resumir\":false}"},"forms":["#
            + #"{"key":"A","name":"A","settings":{"stt":"whisper","idioma":"en","hablantes":{"detectar":false},"#
            + #""resumir":true,"llm":"apple","conectores":[]}},"#
            + #"{"key":"B","name":"B","settings":{"stt":"whisper","idioma":"es","hablantes":{"detectar":false},"#
            + #""resumir":true,"llm":"apple","conectores":[]}},"#
            + #"{"key":"C","name":"C"},"#
            + #"{"key":"D","name":"D","settings":{"stt":7}}]}"#

        let leido = try JSONDecoder().decode(RecipeBook.self, from: Data(guardado.utf8))

        #expect(leido.forms.map(\.key) == ["A", "B", "C", "D"])
        #expect(try valores(leido, "A")?["idioma"] == .string("en"))
        #expect(leido.values["B"] == #"{"resumir":false}"#)
        #expect(leido.values["C"] == nil)
        #expect(leido.values["D"] == nil)
        #expect(leido.defaultKey == "B")
    }

    @Test("si ya hay valores guardados para una receta de formulario, mandan sobre sus ajustes de antes")
    func valoresMandan() throws {
        let guardado = #"{"defaultKey":"F1","values":{"F1":"{\"resumir\":false}"},"forms":[{"key":"F1","name":"A","#
            + #""settings":{"stt":"whisper","idioma":"es","hablantes":{"detectar":false},"resumir":true,"llm":"apple","#
            + #""conectores":[]}}]}"#

        let leido = try JSONDecoder().decode(RecipeBook.self, from: Data(guardado.utf8))

        #expect(leido.values == ["F1": #"{"resumir":false}"#])
    }

    @Test("añadir una de formulario le da un nombre que no se repite, sin valores, y no cambia la por defecto")
    func anadir() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")

        let primera = libro.add(key: "F2", name: "Receta nueva")
        let segunda = libro.add(key: "F3", name: "Receta nueva")

        #expect(primera.name == "Receta nueva")
        #expect(segunda.name == "Receta nueva 2")
        #expect(libro.forms.map(\.key) == ["F1", "F2", "F3"])
        #expect(libro.values["F2"] == nil)
        #expect(libro.defaultKey == "F1")
    }

    @Test("duplicar copia los valores con otra clave y un nombre que dice que es copia")
    func duplicar() throws {
        var libro = RecipeBook(migrating: deHoy, key: "F1")

        let copia = libro.duplicate("F1", as: "F2")
        let otra = libro.duplicate("F1", as: "F3")
        let ninguna = libro.duplicate("NO", as: "F4")

        #expect(copia == FormRecipe(key: "F2", name: "Por defecto (copia)"))
        #expect(try valores(libro, "F2") == formRecipeValues(deHoy))
        #expect(otra?.name == "Por defecto (copia) 2")
        #expect(ninguna == nil)
    }

    @Test("una receta de código se guarda como receta de formulario: con su nombre, sus valores y la receta de la que parte")
    func variante() throws {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.setValues(#"{"llm":"U2"}"#, for: "analisis")

        let variante = libro.add(key: "V1", name: "Análisis con Groq", base: "analisis", values: libro.values["analisis"])
        libro.makeDefault("V1")

        #expect(variante == FormRecipe(key: "V1", name: "Análisis con Groq", base: "analisis"))
        #expect(libro.values["V1"] == #"{"llm":"U2"}"#)
        #expect(libro.resolve("V1", installed: [:]) == .form(variante))
        #expect(libro.listing(code: [RecipeCodeEntry(key: "analisis", name: "Análisis completo")]).map(\.key)
            == ["F1", "V1", "analisis"])
        #expect(libro.duplicate("V1", as: "V2")?.base == "analisis")
        let leido = try JSONDecoder().decode(RecipeBook.self, from: try JSONEncoder().encode(libro))
        #expect(leido == libro)
        #expect(leido.form("F1")?.base == nil)
    }

    @Test("lo que se limpia y se lee de los ajustes de «Por defecto» no toca las recetas que parten de una de código")
    func varianteNoSeLimpia() {
        var libro = RecipeBook(migrating: conGroq, key: "F1")
        libro.add(key: "V1", name: "Otra", base: "analisis", values: #"{"stt":"U1","llm":"U2","conectores":["K1"]}"#)

        #expect(libro.forgettingResolver("U1").values["V1"] == libro.values["V1"])
        #expect(libro.forgettingConnector("K1").values["V1"] == libro.values["V1"])
        #expect(libro.forgettingMissing(connectors: [], stts: [], llms: []).values["V1"] == libro.values["V1"])
        #expect(libro.reading(of: "V1") == RecipeBook(migrating: .standard, key: "S").reading(of: "S"))
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

    @Test("quitar la por defecto pasa la por defecto a la primera de formulario, se lleva sus valores, y la última no se quita")
    func quitar() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Reuniones")

        libro.remove("F1")
        #expect(libro.forms.map(\.key) == ["F2"])
        #expect(libro.defaultKey == "F2")
        #expect(libro.values["F1"] == nil)

        libro.remove("F2")
        #expect(libro.forms.map(\.key) == ["F2"])
    }

    @Test("quitar una de formulario que no es la por defecto deja la por defecto donde estaba, aunque sea de código")
    func quitarOtra() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Reuniones")
        libro.makeDefault("ideas")

        libro.remove("F2")

        #expect(libro.defaultKey == "ideas")
    }

    @Test("la lista junta las de formulario y las de código, y marca la por defecto")
    func lista() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Reuniones")
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

    @Test("una receta se resuelve: la de formulario, la de código con su paquete, y si no hay paquete dice cuál falta")
    func resolver() {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        let instaladas = ["ideas": instalada("ideas", "Ideas")]

        #expect(libro.resolve(libro.defaultKey, installed: instaladas) == .form(libro.forms[0]))

        libro.makeDefault("ideas")
        #expect(libro.resolve(libro.defaultKey, installed: instaladas) == .code(instaladas["ideas"]!))

        libro.makeDefault("borrada")
        #expect(libro.resolve(libro.defaultKey, installed: instaladas) == .missing("borrada"))
    }

    @Test("quitar un resolutor devuelve al de serie las recetas de formulario que lo usaban; las de código no se tocan")
    func resolutorQuitado() throws {
        var libro = RecipeBook(migrating: conGroq, key: "F1")
        libro.add(key: "F2", name: "Otra")
        libro.setValues(#"{"llm":"U2","resumir":true}"#, for: "F2")
        libro.setValues(#"{"llm":"U2"}"#, for: "analisis")

        let sinGroqSTT = libro.forgettingResolver("U1")
        let sinGroqLLM = libro.forgettingResolver("U2")

        #expect(try valores(sinGroqSTT, "F1")?["stt"] == nil)
        #expect(try valores(sinGroqSTT, "F1")?["llm"] == .string("U2"))
        #expect(try valores(sinGroqLLM, "F1")?["llm"] == nil)
        #expect(try valores(sinGroqLLM, "F1")?["stt"] == .string("U1"))
        #expect(sinGroqLLM.values["F2"] == #"{"resumir":true}"#)
        #expect(sinGroqLLM.values["analisis"] == #"{"llm":"U2"}"#)
    }

    @Test("quitar un conector lo quita de lo que publican las recetas de formulario; las de código no se tocan")
    func conectorQuitado() throws {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.setValues(#"{"conector":"K1"}"#, for: "analisis")

        let sinK1 = libro.forgettingConnector("K1")

        #expect(try valores(sinK1, "F1")?["conectores"] == .array([.string("K2")]))
        #expect(sinK1.values["analisis"] == #"{"conector":"K1"}"#)
        #expect(libro.forgettingConnector("K9") == libro)
    }

    @Test("al arrancar, lo que una receta de formulario usa y ya no existe vuelve a lo de serie")
    func limpiezaAlArrancar() throws {
        var libro = RecipeBook(migrating: conGroq, key: "F1")
        libro.setValues(#"{"conectores":["K1","borrado"],"stt":"borrado"}"#, for: "F1")
        libro.setValues(#"{"conector":"borrado"}"#, for: "analisis")

        let limpio = libro.forgettingMissing(connectors: ["K1"], stts: ["whisper", "U1"], llms: ["apple"])

        #expect(limpio.values["F1"] == #"{"conectores":["K1"]}"#)
        #expect(limpio.values["analisis"] == #"{"conector":"borrado"}"#)
        #expect(libro.forgettingMissing(connectors: ["K1", "borrado"], stts: ["borrado"], llms: []).values["F1"]
            == #"{"conectores":["K1","borrado"],"stt":"borrado"}"#)
    }

    @Test("lo que la app lee de una receta de formulario: lo guardado sobre los valores de serie de «Por defecto»; si no parte de «Por defecto», los de serie")
    func lectura() {
        var libro = RecipeBook(migrating: conGroq, key: "F1")
        libro.add(key: "F2", name: "De serie")
        libro.setValues(#"{"llm":"U2","resumir":true}"#, for: "analisis")

        #expect(libro.reading(of: "F1") == FormRecipeReading(
            stt: "U1", language: nil, summarize: true, llm: "U2", prompt: "Tres viñetas"))
        #expect(libro.reading(of: "F2") == FormRecipeReading(
            stt: "whisper", language: "es", summarize: true, llm: "apple", prompt: nil))
        #expect(libro.reading(of: "analisis") == libro.reading(of: "F2"))
        libro.setValues(#"{"resumir":false}"#, for: "F2")
        #expect(libro.reading(of: "F2") == FormRecipeReading(
            stt: "whisper", language: "es", summarize: false, llm: "apple", prompt: nil))
    }

    @Test("se guarda y se vuelve a leer igual")
    func idaYVuelta() throws {
        var libro = RecipeBook(migrating: deHoy, key: "F1")
        libro.add(key: "F2", name: "Groq")
        libro.setValues(dataText(formRecipeValues(conGroq)), for: "F2")
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
        #expect(leido.values.isEmpty)
    }

    @Test("los valores del formulario de una receta se guardan por clave, se restablecen y sobreviven a leer el libro")
    func valoresDeCodigo() throws {
        var libro = RecipeBook(migrating: deHoy, key: "F1")

        libro.setValues(#"{"idioma":"en"}"#, for: "analisis")
        libro.setValues(#"{"llm":"U2"}"#, for: "reparto")
        libro.setValues(nil, for: "reparto")
        libro.setValues(nil, for: "F1")

        #expect(libro.values == ["analisis": #"{"idioma":"en"}"#])
        let leido = try JSONDecoder().decode(RecipeBook.self, from: try JSONEncoder().encode(libro))
        #expect(leido == libro)
    }

    @Test("las recetas llegan a JavaScript con clave, nombre y tipo")
    func info() throws {
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

@Suite("Recetas que llaman a otras: ciclos y profundidad")
struct CadenaDeRecetasTests {
    private let a = RecipeInfo(key: "a", name: "Reparto", kind: .code)
    private let b = RecipeInfo(key: "b", name: "Reuniones", kind: .form)

    @Test("llamar a otra receta distinta, dentro del limite, se puede")
    func permitida() {
        #expect(recipeCallProblem(chain: [a], next: b) == nil)
    }

    @Test("una receta que vuelve a una de su cadena es un ciclo, y el error dice la cadena")
    func ciclo() {
        let problema = recipeCallProblem(chain: [a, b], next: a)

        #expect(problema == .cycle(["Reparto", "Reuniones", "Reparto"]))
        #expect("\(problema!)" == "las recetas se llaman en círculo: Reparto → Reuniones → Reparto")
    }

    @Test("pasar del limite de recetas encadenadas se corta")
    func profundidad() {
        let cadena = (1...recipeCallLimit).map { RecipeInfo(key: "r\($0)", name: "R\($0)", kind: .code) }
        let siguiente = RecipeInfo(key: "r9", name: "R9", kind: .code)

        let problema = recipeCallProblem(chain: cadena, next: siguiente)

        #expect(problema == .tooDeep(cadena.map(\.name) + ["R9"]))
        #expect("\(problema!)" == "demasiadas recetas encadenadas (como mucho \(recipeCallLimit)): R1 → R2 → R3 → R4 → R9")
    }
}
