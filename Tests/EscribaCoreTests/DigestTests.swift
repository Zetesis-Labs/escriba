import Testing

@testable import EscribaCore

@Suite("Titulo, resumen y etiquetas")
struct DigestTests {
    @Test("las etiquetas salen en minusculas, sin almohadilla, sin repetidas y acotadas")
    func etiquetasNormalizadas() {
        let crudas = ["#Kubernetes", " backups ", "kubernetes", "", "Talos Linux", "MinIO", "wasm", "spike", "extra"]

        #expect(normalizedTags(crudas, limit: 6) == ["kubernetes", "backups", "talos linux", "minio", "wasm", "spike"])
        #expect(normalizedTags(crudas).count == digestTagLimit)
        #expect(normalizedTags([]).isEmpty)
    }

    @Test("el titulo queda en una linea, sin comillas ni punto final, y acotado por palabras")
    func tituloNormalizado() {
        let digest = Digest(
            title: "  \"Reunión sobre\nlos backups.\"  ", summary: " Se habló de backups.\n", tags: ["Backups"])
        let limpio = normalizedDigest(digest)

        #expect(limpio.title == "Reunión sobre los backups")
        #expect(limpio.summary == "Se habló de backups.")
        #expect(limpio.tags == ["backups"])

        let largo = normalizedDigest(Digest(title: String(repeating: "palabra ", count: 30), summary: "", tags: []))
        #expect(largo.title.count <= digestTitleLimit)
        #expect(largo.title.hasSuffix("…"))
    }

    @Test("una etiqueta con comas se parte, porque Notion no las admite en un multi_select")
    func etiquetasSinComas() {
        #expect(normalizedTags(["backups, minio", "talos"]) == ["backups minio", "talos"])
    }

    @Test("un titulo de una sola palabra interminable se corta, no se queda en puntos suspensivos")
    func tituloSinEspacios() {
        let titulo = normalizedDigest(
            Digest(title: String(repeating: "a", count: 200), summary: "x", tags: [])
        ).title

        #expect(titulo.count == digestTitleLimit)
        #expect(titulo.hasSuffix("…"))
    }

    @Test("un digest sin titulo ni resumen se considera vacio")
    func vacio() {
        #expect(Digest(title: " ", summary: "", tags: []).isEmpty)
        #expect(!Digest(title: "Algo", summary: "", tags: []).isEmpty)
    }

    @Test("el texto que se manda a reducir omite las lineas que no tienen nada")
    func renderizado() {
        #expect(Digest(title: "", summary: "", tags: []).rendered == "")
        #expect(Digest(title: "", summary: "", tags: ["uno", "dos"]).rendered == "Etiquetas: uno, dos")
        #expect(
            Digest(title: "T", summary: "R", tags: ["x"]).rendered
                == "Título: T\nResumen: R\nEtiquetas: x")
    }

    @Test("un texto corto va entero en un solo trozo")
    func trozoUnico() {
        #expect(digestChunks(of: "Hola.\nAdiós.", maxCharacters: 100) == ["Hola.\nAdiós."])
        #expect(digestChunks(of: "   ", maxCharacters: 100).isEmpty)
    }

    @Test("un texto largo se trocea por parrafos sin partir ninguno que quepa")
    func trozosPorParrafos() {
        let parrafos = (1...6).map { "Párrafo \($0) con algo de texto." }
        let texto = parrafos.joined(separator: "\n")
        let trozos = digestChunks(of: texto, maxCharacters: 70)

        #expect(trozos.allSatisfy { $0.count <= 70 })
        #expect(trozos.joined(separator: "\n") == texto)
        #expect(trozos.count == 3)
    }

    @Test("un parrafo que no cabe se parte por frases y, si hace falta, por palabras")
    func trozosPorFrases() {
        let texto = "Primera frase larga. Segunda frase larga. Tercera frase larga."
        let porFrases = digestChunks(of: texto, maxCharacters: 42)
        #expect(porFrases == ["Primera frase larga. Segunda frase larga.", "Tercera frase larga."])

        let porPalabras = digestChunks(of: "uno dos tres cuatro cinco", maxCharacters: 8)
        #expect(porPalabras == ["uno dos", "tres", "cuatro", "cinco"])
        #expect(porPalabras.allSatisfy { $0.count <= 8 })
    }

    @Test("una palabra mas larga que el limite se parte a lo bruto en vez de bloquear")
    func palabraInterminable() {
        let trozos = digestChunks(of: "abcdefghij", maxCharacters: 4)
        #expect(trozos == ["abcd", "efgh", "ij"])
    }

    @Test("las instrucciones piden responder en el idioma de la transcripcion")
    func instrucciones() {
        #expect(DigestPrompt.instructions(language: "es").contains("español"))
        #expect(DigestPrompt.instructions(language: "en").contains("inglés"))
        #expect(DigestPrompt.instructions(language: nil).contains("mismo idioma"))
        #expect(DigestPrompt.instructions(language: "xx").contains("mismo idioma"))
    }

    @Test("un prompt propio sustituye al de serie y conserva la frase del idioma")
    func promptPropio() {
        let propio = DigestPrompt.instructions(language: "es", base: "  Resume como un acta.\n")

        #expect(propio.hasPrefix("Resume como un acta."))
        #expect(propio.contains("español"))
        #expect(!propio.contains("Eres un asistente"))
        #expect(DigestPrompt.instructions(language: "es").hasPrefix(DigestPrompt.standard))
        #expect(DigestPrompt.instructions(language: "es", base: " \n ") == DigestPrompt.instructions(language: "es"))
        #expect(DigestPrompt.instructions(language: "es", base: nil) == DigestPrompt.instructions(language: "es"))
    }

    @Test("las peticiones de trozo y de reduccion llevan el prompt propio")
    func peticionesConPrompt() {
        #expect(digestRequest(text: "x", language: nil, prompt: "Acta.").instructions.hasPrefix("Acta."))
        #expect(reduceRequest(partials: ["x"], language: nil, prompt: "Acta.").instructions.hasPrefix("Acta."))
        #expect(digestRequest(text: "x", language: nil).instructions.hasPrefix(DigestPrompt.standard))
    }

    @Test("la peticion de un trozo y la de reduccion se distinguen y llevan el texto")
    func peticiones() {
        let trozo = DigestPrompt.request(text: "Hola mundo")
        #expect(trozo.hasSuffix("Hola mundo"))
        #expect(trozo.contains("Transcripción"))

        let reducida = DigestPrompt.reduce(partials: ["Parte A.", "Parte B."])
        #expect(reducida.contains("Parte A."))
        #expect(reducida.contains("Parte B."))
        #expect(reducida.contains("parciales"))
        #expect(reducida != trozo)
    }
}
