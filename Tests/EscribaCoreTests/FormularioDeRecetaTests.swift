import Testing

@testable import EscribaCore

private let esquema = #"""
    {"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","properties":{
     "idioma":{"default":"es","title":"Idioma","description":"null = detectar","anyOf":[{"type":"string","enum":["es","en"]},{"type":"null"}]},
     "hablantes":{"title":"Hablantes","default":{},"type":"object","properties":{
       "detectar":{"default":false,"title":"Detectar hablantes","type":"boolean"},
       "cuantos":{"default":null,"title":"Cuántos","anyOf":[{"type":"integer","minimum":2,"maximum":6},{"type":"null"}]}}},
     "llm":{"default":"apple","title":"LLM","type":"string","enum":["apple","openai-1"]},
     "conectores":{"default":[],"type":"array","items":{"type":"string","enum":["notion","okf"]}},
     "nota":{"type":"string"},
     "umbral":{"default":0.5,"type":"number","minimum":0,"maximum":1},
     "obligatorio":{"type":"string"},
     "h2":{"default":{"a":true},"type":"object","properties":{"a":{"default":true,"type":"boolean"}}}},
    "required":["obligatorio"]}
    """#

private func formulario(_ texto: String = esquema) throws -> RecipeForm {
    try recipeForm(from: try parseData(texto))
}

private func objeto(_ texto: String) throws -> DataValue {
    try parseData(texto)
}

private func campo(_ formulario: RecipeForm, _ nombre: String) -> RecipeFormField? {
    formulario.fields.first { $0.name == nombre }
}

private func subcampo(_ formulario: RecipeForm, _ grupo: String, _ nombre: String) -> RecipeFormField? {
    guard case .group(let campos)? = campo(formulario, grupo)?.kind else { return nil }
    return campos.first { $0.name == nombre }
}

@Suite("Formulario de una receta de código: el esquema de Zod de buildRecipeForm")
struct FormularioDeRecetaTests {
    @Test("lee cada campo con su título, su ayuda, su valor por defecto y si admite vacío, en el orden del script")
    func campos() throws {
        let leido = try formulario()

        #expect(leido.fields.map(\.name) == [
            "idioma", "hablantes", "llm", "conectores", "nota", "umbral", "obligatorio", "h2",
        ])
        #expect(campo(leido, "idioma") == RecipeFormField(
            name: "idioma", label: "Idioma", help: "null = detectar",
            kind: .choice([RecipeFormOption(value: "es"), RecipeFormOption(value: "en")]),
            nullable: true, required: false, defaultValue: .string("es")))
        #expect(campo(leido, "hablantes") == RecipeFormField(
            name: "hablantes", label: "Hablantes",
            kind: .group([
                RecipeFormField(
                    name: "detectar", label: "Detectar hablantes", kind: .toggle, defaultValue: .bool(false)),
                RecipeFormField(
                    name: "cuantos", label: "Cuántos", kind: .number(minimum: 2, maximum: 6, integer: true),
                    nullable: true, defaultValue: .null),
            ]),
            defaultValue: .object([])))
        #expect(campo(leido, "conectores")?.kind == .choices([
            RecipeFormOption(value: "notion"), RecipeFormOption(value: "okf"),
        ]))
        #expect(campo(leido, "nota") == RecipeFormField(name: "nota", label: "nota", kind: .text(lines: 1)))
        #expect(campo(leido, "umbral")?.kind == .number(minimum: 0, maximum: 1, integer: false))
        #expect(campo(leido, "obligatorio")?.required == true)
        #expect(campo(leido, "obligatorio")?.defaultValue == nil)
    }

    @Test("un texto con .meta({ lineas }) es un cuadro de esas líneas, con un tope; sin ellas, de una")
    func lineas() throws {
        let leido = try formulario(#"""
            {"type":"object","properties":{
             "prompt":{"default":null,"title":"Prompt","lineas":6,"type":["string","null"]},
             "mucho":{"type":"string","lineas":500},
             "raro":{"type":"string","lineas":"seis"},
             "corto":{"type":"string"}}}
            """#)

        #expect(campo(leido, "prompt")?.kind == .text(lines: 6))
        #expect(campo(leido, "prompt")?.nullable == true)
        #expect(campo(leido, "mucho")?.kind == .text(lines: maximumTextLines))
        #expect(campo(leido, "raro")?.kind == .text(lines: 1))
        #expect(campo(leido, "corto")?.kind == .text(lines: 1))
    }

    @Test("una unión de literales con título se ve con sus nombres, y una constante es una opción fija")
    func literales() throws {
        let leido = try formulario(#"""
            {"type":"object","properties":{
             "llm":{"default":"apple","title":"LLM","anyOf":[{"type":"string","const":"apple","title":"Apple"},{"type":"string","const":"o1","title":"OpenAI"}]},
             "uno":{"type":"string","const":"solo"},
             "conector":{"default":null,"anyOf":[{"anyOf":[{"type":"string","const":"K1","title":"Notion"}]},{"type":"null"}]},
             "ninguno":{"default":null,"anyOf":[{"anyOf":[]},{"type":"null"}]}},"required":["uno"]}
            """#)

        #expect(campo(leido, "llm")?.kind == .choice([
            RecipeFormOption(value: "apple", label: "Apple"), RecipeFormOption(value: "o1", label: "OpenAI"),
        ]))
        #expect(campo(leido, "uno")?.kind == .choice([RecipeFormOption(value: "solo")]))
        #expect(campo(leido, "conector")?.kind == .choice([RecipeFormOption(value: "K1", label: "Notion")]))
        #expect(campo(leido, "conector")?.nullable == true)
        #expect(campo(leido, "ninguno")?.kind == .choice([]))
        #expect(campo(leido, "ninguno")?.nullable == true)
    }

    @Test("un enumerado vacío, como los conectores cuando no hay ninguno, es un desplegable sin opciones")
    func enumeradoVacio() throws {
        let leido = try formulario(#"""
            {"type":"object","properties":{"conector":{"not":{}},"otro":{"anyOf":[]},
             "varios":{"type":"array","items":{"not":{}}}}}
            """#)

        #expect(campo(leido, "conector")?.kind == .choice([]))
        #expect(campo(leido, "otro")?.kind == .choice([]))
        #expect(campo(leido, "varios")?.kind == .choices([]))
    }

    @Test("lo que el formulario no sabe pintar se dice con su camino")
    func noSoportado() {
        let casos: [(String, RecipeFormProblem)] = [
            (#"{"type":"string"}"#, .notAnObject),
            (#"{"anyOf":[{"type":"object","properties":{}},{"type":"null"}]}"#, .notAnObject),
            (
                #"{"type":"object","properties":{"extra":{"type":"object","additionalProperties":{"type":"string"}}}}"#,
                .unsupported(path: "extra", what: "un registro de claves libres (z.record)")
            ),
            (
                #"{"type":"object","properties":{"g":{"type":"object","properties":{"tareas":{"type":"array","items":{"type":"string"}}}}}}"#,
                .unsupported(path: "g.tareas", what: "una lista que no es de opciones (z.array de z.enum)")
            ),
            (
                #"{"type":"object","properties":{"x":{"anyOf":[{"type":"string"},{"type":"number"}]}}}"#,
                .unsupported(path: "x", what: "una unión de tipos distintos")
            ),
            (
                ##"{"type":"object","properties":{"x":{"$ref":"#"}}}"##,
                .unsupported(path: "x", what: "un esquema recursivo ($ref)")
            ),
            (
                #"{"type":"object","properties":{"x":{"type":"array","prefixItems":[{"type":"string"}]}}}"#,
                .unsupported(path: "x", what: "una tupla (z.tuple)")
            ),
        ]
        for (texto, problema) in casos {
            #expect(throws: problema, "\(texto)") { try formulario(texto) }
        }
    }

    @Test("los valores son los del script con lo guardado encima, también dentro de los grupos")
    func valores() throws {
        let leido = try formulario()

        let valores = recipeFormValues(
            leido, saved: try objeto(#"{"hablantes":{"cuantos":3},"llm":"openai-1","quitado":1}"#))

        #expect(valores == (try objeto(
            #"{"idioma":"es","hablantes":{"detectar":false,"cuantos":3},"llm":"openai-1","conectores":[],"#
                + #""umbral":0.5,"h2":{"a":true}}"#)))
        #expect(recipeFormValues(leido, saved: nil) == recipeFormDefaults(leido))
    }

    @Test("se guarda solo lo que difiere del script, y volver al valor del script lo borra")
    func guardados() throws {
        let leido = try formulario()
        let porDefecto = recipeFormDefaults(leido)

        #expect(recipeFormOverrides(leido, values: porDefecto) == nil)

        let cambiados = porDefecto
            .setting(.number(3), at: ["hablantes", "cuantos"])
            .setting(.string("en"), at: ["idioma"])
            .setting(.string("x"), at: ["obligatorio"])
        #expect(recipeFormOverrides(leido, values: cambiados) == (try objeto(
            #"{"idioma":"en","hablantes":{"cuantos":3},"obligatorio":"x"}"#)))

        let deVuelta = cambiados.setting(.string("es"), at: ["idioma"]).setting(nil, at: ["obligatorio"])
        #expect(recipeFormOverrides(leido, values: deVuelta) == (try objeto(#"{"hablantes":{"cuantos":3}}"#)))
    }

    @Test("un grupo obligatorio sin valor por defecto se guarda vacío para que Zod rellene sus campos")
    func grupoObligatorio() throws {
        let leido = try formulario(#"""
            {"type":"object","properties":{"g":{"type":"object","properties":{"a":{"default":true,"type":"boolean"}}}},
             "required":["g"]}
            """#)

        #expect(recipeFormOverrides(leido, values: recipeFormDefaults(leido)) == (try objeto(#"{"g":{}}"#)))
    }

    @Test("lo guardado que ya no casa con el script se avisa en su campo")
    func avisos() throws {
        let leido = try formulario()
        let llm = try #require(campo(leido, "llm"))
        let cuantos = try #require(subcampo(leido, "hablantes", "cuantos"))
        let conectores = try #require(campo(leido, "conectores"))

        #expect(recipeFormIssue(llm, value: .string("viejo")) == "«viejo» ya no está entre las opciones")
        #expect(recipeFormIssue(llm, value: .string("apple")) == nil)
        #expect(recipeFormIssue(cuantos, value: .number(9)) == "tiene que estar entre 2 y 6")
        #expect(recipeFormIssue(cuantos, value: .number(2.5)) == "tiene que ser un número entero")
        #expect(recipeFormIssue(cuantos, value: .null) == nil)
        #expect(recipeFormIssue(conectores, value: try objeto(#"["notion","borrado"]"#))
            == "«borrado» ya no está entre las opciones")
        #expect(recipeFormIssue(try #require(campo(leido, "obligatorio")), value: nil) == "falta un valor")
        #expect(recipeFormIssue(try #require(campo(leido, "nota")), value: nil) == nil)
    }

    @Test("cambiar o quitar un valor por su camino crea los grupos que falten y no toca lo demás")
    func porCamino() throws {
        let valores = try objeto(#"{"a":1,"g":{"b":true}}"#)

        #expect(valores.setting(.string("x"), at: ["g", "c"]) == (try objeto(#"{"a":1,"g":{"b":true,"c":"x"}}"#)))
        #expect(valores.setting(.number(2), at: ["a"]) == (try objeto(#"{"a":2,"g":{"b":true}}"#)))
        #expect(valores.setting(nil, at: ["g", "b"]) == (try objeto(#"{"a":1,"g":{}}"#)))
        #expect(valores.setting(.bool(false), at: ["n", "m"]) == (try objeto(#"{"a":1,"g":{"b":true},"n":{"m":false}}"#)))
        #expect(valores.value(at: ["g", "b"]) == .bool(true))
        #expect(valores.value(at: ["g", "z"]) == nil)
    }

    @Test("lo que devuelve buildRecipeForm se lee como sin formulario, un formulario o un problema que se enseña")
    func carga() throws {
        #expect(recipeFormLoad(schema: nil) == .noForm)
        #expect(recipeFormLoad(schema: esquema) == .form(try formulario()))
        #expect(recipeFormLoad(schema: #"{"type":"string"}"#) == .problem("\(RecipeFormProblem.notAnObject)"))
        #expect(recipeFormLoad(schema: "{").isProblem)
    }

    @Test("las secciones siguen el orden del script: cada grupo con su camino y su título, y los campos sueltos de seguido juntos")
    func secciones() throws {
        let leido = try formulario(#"""
            {"type":"object","properties":{
             "a":{"type":"boolean"},
             "g":{"title":"Hablantes","type":"object","properties":{
               "b":{"type":"boolean"},
               "h":{"title":"Avanzado","type":"object","properties":{"c":{"type":"string"}}}}},
             "d":{"type":"string"}}}
            """#)

        let secciones = recipeFormSections(leido)

        #expect(secciones.map(\.path) == [[], ["g"], ["g", "h"], []])
        #expect(secciones.map(\.title) == [nil, "Hablantes", "Hablantes · Avanzado", nil])
        #expect(secciones.map { $0.fields.map(\.name) } == [["a"], ["b"], ["c"], ["d"]])
        #expect(Set(secciones.map(\.id)).count == secciones.count)
    }

    @Test("un entero con mínimo y máximo cercanos se elige de una lista; un rango absurdo o enorme, no")
    func enterosEnLista() {
        let entero = { (minimo: Double, maximo: Double) in
            RecipeFormField(name: "n", kind: .number(minimum: minimo, maximum: maximo, integer: true))
        }

        #expect(recipeFormNumberChoices(entero(2, 6)) == [2, 3, 4, 5, 6])
        #expect(recipeFormNumberChoices(entero(1.5, 4.5)) == [2, 3, 4])
        #expect(recipeFormNumberChoices(entero(6, 2)) == nil)
        #expect(recipeFormNumberChoices(entero(0, 100)) == nil)
        #expect(recipeFormNumberChoices(entero(1e20, 1e20 + 5)) == nil)
        #expect(recipeFormNumberChoices(RecipeFormField(name: "n", kind: .number(minimum: 2, maximum: 6, integer: false))) == nil)
        #expect(recipeFormNumberText(1e20) == "1e+20")
        #expect(recipeFormNumberText(3) == "3")
    }
}
