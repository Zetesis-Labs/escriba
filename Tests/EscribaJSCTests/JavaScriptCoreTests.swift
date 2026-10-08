import Foundation
import Synchronization
import Testing

@testable import EscribaCore
@testable import EscribaEngine
@testable import EscribaJSC

final class Registro: Sendable {
    private let storage = Mutex<[String]>([])

    var values: [String] { storage.withLock { $0 } }
    func append(_ value: String) { storage.withLock { $0.append(value) } }
}

private let grabacion = Recording(
    url: URL(fileURLWithPath: "/grabaciones/a.m4a"), startedAt: Date(timeIntervalSince1970: 0), key: "a")

func paquete(_ cuerpo: String, antes: String = "", datos: String? = nil, formulario: String? = nil) -> RecipePackage {
    RecipePackage(
        key: "prueba",
        source: (antes.isEmpty ? "" : antes + "\n") + "var __receta = { receta: { nombre: \"Prueba\"\(datos.map { ", datos: \($0)" } ?? "") }, "
            + (formulario.map { "buildRecipeForm: \($0), " } ?? "")
            + "flujo: async (audio, escriba) => {\n\(cuerpo)\n} };",
        fingerprint: "prueba")
}

func nota(_ texto: String = "hola", digest: Digest? = nil, datos: DataValue? = nil) -> RecipeNote {
    RecipeNote(key: "a", version: 1, transcript: Transcript(text: texto), digest: digest, data: datos)
}

private func formulario(
    conectores: [String] = [], resumir: Bool = true, prompt: String? = nil
) -> DefaultRecipeSettings {
    DefaultRecipeSettings(
        stt: "whisper", language: "es", detectSpeakers: true, speakerCount: 2, summarize: resumir, llm: "apple",
        prompt: prompt, connectors: conectores)
}

func puente(
    _ registro: Registro,
    connectors: [String] = [],
    parametros: DefaultRecipeSettings? = nil,
    recetas: [RecipeInfo] = [],
    transcribe: @escaping @Sendable (RecipeTranscription) async throws -> RecipeNote = { _ in nota() },
    summarize: @escaping @Sendable (RecipeSummaryRequest) async throws -> RecipeNote = { _ in nota() },
    ask: @escaping @Sendable (RecipeQuestion, String?) async throws -> String = { _, _ in "{}" }
) -> RecipeBridge {
    RecipeBridge(
        audio: recipeAudio(grabacion),
        values: dataText(formRecipeValues(parametros ?? formulario(conectores: connectors))),
        stts: [
            RecipeResolver(key: "whisper", name: "Whisper en este Mac", isLocal: true),
            RecipeResolver(
                key: "U1", name: "Groq", isLocal: false, model: "whisper-large-v3",
                baseURL: "https://api.groq.com/openai/v1"),
        ],
        llms: [RecipeResolver(key: "apple", name: "Apple Intelligence", isLocal: true)],
        connectors: connectors.map {
            RecipeConnector(
                key: $0, name: $0, kind: "archivo", isActive: !$0.hasPrefix("apagado"))
        },
        recipes: recetas,
        transcribe: { pedido in
            registro.append("transcribe")
            return try await transcribe(pedido)
        },
        summarize: { pedido in
            registro.append("resume")
            return try await summarize(pedido)
        },
        save: { registro.append("guarda") },
        saveData: { datos, esquema in registro.append("guarda \(datos)\(esquema.map { " según \($0)" } ?? "")") },
        ask: { pregunta, esquema in
            registro.append("pregunta \(pregunta.input)\(esquema.map { " con \($0)" } ?? "")")
            return try await ask(pregunta, esquema)
        },
        publish: { registro.append("publica \($0)") },
        process: { registro.append("procesa \($0)") },
        log: { nivel, texto in registro.append(nivel == .info ? "log \(texto)" : "log \(nivel.rawValue) \(texto)") })
}

func ejecutar(_ package: RecipePackage, _ bridge: RecipeBridge, limite: Double = 10) async throws {
    try await javaScriptCoreRuntime(timeLimit: limite).run(package, bridge)
}

@Suite("Recetas en JavaScriptCore")
struct JavaScriptCoreTests {
    @Test("la receta por defecto pide transcribir, resumir, guardar y publicar en cada conector")
    func recetaPorDefecto() async throws {
        let registro = Registro()

        try await ejecutar(.defaultRecipe, puente(registro, connectors: ["notion", "okf"]))

        #expect(registro.values == ["transcribe", "resume", "guarda", "publica notion", "publica okf"])
    }

    @Test("la receta por defecto publica solo en los conectores marcados en su formulario")
    func conectoresDelFormulario() async throws {
        let registro = Registro()

        try await ejecutar(
            .defaultRecipe, puente(registro, connectors: ["notion", "okf"], parametros: formulario(conectores: ["okf"])))

        #expect(registro.values == ["transcribe", "resume", "guarda", "publica okf"])
    }

    @Test("la receta por defecto transcribe y resume con lo que dice su formulario")
    func loDelFormulario() async throws {
        let pedidos = Registro()
        let bridge = puente(
            Registro(), parametros: formulario(prompt: "Breve"),
            transcribe: { pedido in
                pedidos.append("\(pedido)")
                return nota()
            },
            summarize: { pedido in
                pedidos.append("\(pedido)")
                return nota()
            })

        try await ejecutar(.defaultRecipe, bridge)

        #expect(pedidos.values == [
            "\(RecipeTranscription(stt: "whisper", language: .code("es"), speakers: .init(detect: true, count: 2)))",
            "\(RecipeSummaryRequest(llm: "apple", prompt: "Breve"))",
        ])
    }

    @Test("con resumir apagado en el formulario no se resume")
    func sinResumir() async throws {
        let registro = Registro()

        try await ejecutar(.defaultRecipe, puente(registro, parametros: formulario(resumir: false)))

        #expect(registro.values == ["transcribe", "guarda"])
    }

    @Test("si el resumen falla, la receta por defecto guarda y publica igual, y lo deja en el log")
    func resumenQueFalla() async throws {
        let registro = Registro()

        try await ejecutar(
            .defaultRecipe,
            puente(registro, connectors: ["notion"], summarize: { _ in throw RecipeError.failed("sin Apple Intelligence") }))

        #expect(registro.values.prefix(2) == ["transcribe", "resume"])
        #expect(registro.values.contains { $0.hasPrefix("log warn no se pudo resumir: ") })
        #expect(registro.values.suffix(2) == ["guarda", "publica notion"])
    }

    @Test("la receta ve sus parametros y no puede cambiarlos")
    func parametrosCongelados() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                try { escriba.parametros.hablantes.cuantos = 9 } catch (e) {}
                escriba.log(`${escriba.parametros.stt} ${escriba.parametros.hablantes.cuantos}`)
                """, formulario: "() => ({ '~standard': { validate: (valor) => ({ value: valor }) } })"),
            puente(registro))

        #expect(registro.values == ["log whisper 2"])
    }

    @Test("la receta ve la configuracion de los STT, los LLM y los conectores")
    func configuracionVisible() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                const groq = escriba.stts.find((s) => s.nombre === "Groq")
                escriba.log(`${groq.modelo} ${groq.url} ${groq.local}`)
                const conector = escriba.conectores[0]
                escriba.log(`${conector.activo} ${conector.tipo}`)
                """),
            puente(registro, connectors: ["notion"]))

        #expect(registro.values == ["log whisper-large-v3 https://api.groq.com/openai/v1 false", "log true archivo"])
    }

    @Test("la receta por defecto sigue con los demas conectores si uno falla, y lo apunta")
    func conectorQueFalla() async throws {
        let registro = Registro()
        var bridge = puente(registro, connectors: ["notion", "okf"])
        bridge.publish = { clave in
            if clave == "notion" { throw RecipeError.failed("sin red") }
            registro.append("publica \(clave)")
        }

        try await ejecutar(.defaultRecipe, bridge)

        #expect(registro.values.contains("publica okf"))
        #expect(registro.values.contains { $0.hasPrefix("log no se pudo publicar en notion") })
    }

    @Test("espera a capacidades lentas en orden sin bloquear el hilo principal")
    func esperas() async throws {
        let registro = Registro()
        let lento: @Sendable (RecipeTranscription) async throws -> RecipeNote = { _ in
            try await Task.sleep(for: .milliseconds(150))
            return nota()
        }
        let resumenLento: @Sendable (RecipeSummaryRequest) async throws -> RecipeNote = { _ in
            try await Task.sleep(for: .milliseconds(150))
            return nota()
        }
        let latidos = Mutex(0)
        let latido = Task { @MainActor in
            while !Task.isCancelled {
                latidos.withLock { $0 += 1 }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        try await ejecutar(.defaultRecipe, puente(registro, transcribe: lento, summarize: resumenLento))
        latido.cancel()

        #expect(registro.values == ["transcribe", "resume", "guarda"])
        #expect(latidos.withLock { $0 } > 3)
    }

    @Test("la nota llega a JavaScript con sus datos y resumir la actualiza")
    func datosDeLaNota() async throws {
        let registro = Registro()
        let paquete = paquete("""
            const nota = await escriba.transcribir(audio)
            escriba.log(`${audio.clave} ${nota.texto} ${nota.resumen}`)
            await nota.resumir()
            escriba.log(nota.resumen.titulo)
            """)

        try await ejecutar(
            paquete,
            puente(registro, summarize: { _ in nota(digest: Digest(title: "Saludo", summary: "s", tags: [])) }))

        #expect(registro.values.filter { $0.hasPrefix("log") } == ["log a hola null", "log Saludo"])
    }

    @Test("un bucle infinito se corta al vencer el tiempo limite")
    func bucleInfinito() async throws {
        let inicio = ContinuousClock.now

        await #expect(throws: RecipeError.timedOut(0.2)) {
            try await ejecutar(paquete("while (true) {}"), puente(Registro()), limite: 0.2)
        }
        #expect(ContinuousClock.now - inicio < .seconds(3))
    }

    @Test("un bucle infinito despues de una espera tambien se corta")
    func bucleTrasEspera() async throws {
        await #expect(throws: RecipeError.timedOut(0.2)) {
            try await ejecutar(
                paquete("await escriba.transcribir(audio); while (true) {}"), puente(Registro()), limite: 0.2)
        }
    }

    @Test("las esperas no cuentan para el tiempo limite: solo lo que la receta ejecuta sin parar")
    func esperasNoCuentan() async throws {
        let registro = Registro()
        let lento: @Sendable (RecipeTranscription) async throws -> RecipeNote = { _ in
            try await Task.sleep(for: .milliseconds(300))
            return nota()
        }

        try await ejecutar(
            paquete("await escriba.transcribir(audio); await escriba.transcribir(audio)"),
            puente(registro, transcribe: lento), limite: 0.2)

        #expect(registro.values == ["transcribe", "transcribe"])
    }

    @Test("un motor caido que la receta no recoge sale como el mismo error, para que la nota espere")
    func mismoError() async throws {
        let bridge = puente(Registro(), transcribe: { _ in throw TranscriptionError.backendUnavailable("sin clave") })

        do {
            try await ejecutar(.defaultRecipe, bridge)
            Issue.record("la receta debia fallar")
        } catch let error as TranscriptionError {
            #expect(error.isBackendUnavailable)
        }
    }

    @Test("la receta puede recoger el error de una capacidad, ver su codigo y seguir")
    func recogerError() async throws {
        let registro = Registro()
        let bridge = puente(registro, transcribe: { _ in throw TranscriptionError.backendUnavailable("sin clave") })

        try await ejecutar(
            paquete("""
                try { await escriba.transcribir(audio) } catch (error) { escriba.log(error.codigo) }
                """),
            bridge)

        #expect(registro.values == ["transcribe", "log no-disponible"])
    }

    @Test("una excepcion de la receta sale con su mensaje y su linea")
    func excepcion() async throws {
        do {
            try await ejecutar(paquete("throw new Error('se rompio')"), puente(Registro()))
            Issue.record("la receta debia fallar")
        } catch RecipeError.failed(let message) {
            #expect(message.contains("se rompio"))
            #expect(message.contains("línea 2"))
        }
    }

    @Test("un paquete sin flujo no carga y lo dice")
    func sinFlujo() async throws {
        let roto = RecipePackage(
            key: "rota", source: "var __receta = { receta: { nombre: 'Rota' } };", fingerprint: "x")

        do {
            try await ejecutar(roto, puente(Registro()))
            Issue.record("el paquete no debia cargar")
        } catch RecipeError.invalidPackage(let message) {
            #expect(message.contains("flujo"))
        }
    }

    @Test("un paquete con un error de sintaxis no carga y lo dice")
    func sintaxis() async throws {
        let roto = RecipePackage(key: "rota", source: "var __receta = {", fingerprint: "x")

        await #expect(throws: RecipeError.self) { try await ejecutar(roto, puente(Registro())) }
    }

    @Test("una receta que espera algo que nunca llega falla en vez de colgarse")
    func esperaEterna() async throws {
        await #expect(throws: RecipeError.stalled) {
            try await ejecutar(paquete("await new Promise(() => {})"), puente(Registro()))
        }
    }

    @Test("cada ejecucion empieza en un contexto limpio")
    func contextoLimpio() async throws {
        let registro = Registro()
        let paquete = paquete("globalThis.vueltas = (globalThis.vueltas || 0) + 1; escriba.log(String(vueltas))")

        try await ejecutar(paquete, puente(registro))
        try await ejecutar(paquete, puente(registro))

        #expect(registro.values == ["log 1", "log 1"])
    }

    @Test("la receta no ve red, temporizadores ni el puente interno")
    func sandbox() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("escriba.log([typeof fetch, typeof setTimeout, typeof __puente].join(' '))"),
            puente(registro))

        #expect(registro.values == ["log undefined undefined undefined"])
    }

    @Test("las opciones de transcribir y resumir llegan a Swift tal cual las escribe la receta")
    func opciones() async throws {
        let pedidos = Registro()
        let bridge = puente(
            Registro(),
            transcribe: { pedido in
                pedidos.append("\(pedido)")
                return nota()
            },
            summarize: { pedido in
                pedidos.append("\(pedido)")
                return nota()
            })

        try await ejecutar(
            paquete("""
                const nota = await escriba.transcribir(audio, { stt: "Groq", idioma: null, hablantes: { detectar: true, cuantos: 2 } })
                await escriba.transcribir(audio)
                await nota.resumir({ llm: "apple", prompt: "breve" })
                """),
            bridge)

        #expect(pedidos.values == [
            "\(RecipeTranscription(stt: "Groq", language: .automatic, speakers: .init(detect: true, count: 2)))",
            "\(RecipeTranscription())",
            "\(RecipeSummaryRequest(llm: "apple", prompt: "breve"))",
        ])
    }

    @Test("unas opciones mal escritas fallan diciendo que capacidad las recibio")
    func opcionesMalEscritas() async throws {
        do {
            try await ejecutar(paquete("await escriba.transcribir(audio, { hablantes: 'dos' })"), puente(Registro()))
            Issue.record("la receta debia fallar")
        } catch RecipeError.failed(let message) {
            #expect(message.contains("las opciones de transcribir no son válidas"))
        }
    }

    @Test("la receta ve los STT, los LLM y los conectores, y pide un conector por su nombre")
    func catalogo() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                escriba.log(escriba.stts.map((s) => s.clave).join(","))
                escriba.log(escriba.llms.map((l) => l.nombre).join(","))
                const conector = escriba.conector("NOTION TRABAJO")
                escriba.log(`${conector.clave} ${conector.tipo}`)
                await escriba.transcribir(audio)
                await conector.publicar()
                """),
            puente(registro, connectors: ["Notion trabajo"]))

        #expect(registro.values == [
            "log whisper,U1", "log Apple Intelligence", "log Notion trabajo archivo", "transcribe",
            "publica NOTION TRABAJO",
        ])
    }

    @Test("console escribe en el log con su nivel; los objetos como JSON y los errores con su nombre")
    func consola() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                console.log("hola", 1, { a: [1, 2] })
                console.info("info")
                console.warn(new Error("cuidado"))
                console.error("mal")
                console.debug("detalle")
                const ciclo = {}
                ciclo.yo = ciclo
                console.log(ciclo)
                """),
            puente(registro))

        #expect(registro.values == [
            "log hola 1 {\n  \"a\": [\n    1,\n    2\n  ]\n}", "log info", "log warn Error: cuidado", "log error mal",
            "log debug detalle", "log [object Object]",
        ])
    }

    @Test("la receta ve las recetas y pasa la grabacion a otra por su nombre")
    func otraReceta() async throws {
        let registro = Registro()

        try await ejecutar(
            paquete("""
                escriba.log(escriba.recetas.map((r) => `${r.clave}:${r.tipo}`).join(","))
                const otra = escriba.receta("REUNIONES")
                escriba.log(`${otra.clave} ${otra.nombre} ${otra.tipo}`)
                await otra.procesar(audio)
                """),
            puente(registro, recetas: [
                RecipeInfo(key: "F1", name: "Reuniones", kind: .form),
                RecipeInfo(key: "ideas", name: "Ideas", kind: .code),
            ]))

        #expect(registro.values == [
            "log F1:formulario,ideas:codigo", "log F1 Reuniones formulario", "procesa REUNIONES",
        ])
    }

    @Test("de punta a punta: una receta de codigo pasa la grabacion a la de formulario, cada una en su maquina")
    func pasaDeVerdad() async throws {
        let registro = Registro()
        let reparto = RecipeTarget(
            key: "reparto", name: "Reparto", kind: .code,
            package: paquete("""
                escriba.log(`soy ${escriba.parametros === null ? "codigo" : "formulario"}`)
                await escriba.receta("Reuniones").procesar(audio)
                """))
        let reuniones = RecipeTarget(
            key: "F1", name: "Reuniones", kind: .form,
            package: RecipePackage(
                key: "F1", source: RecipePackage.defaultRecipe.source,
                fingerprint: RecipePackage.defaultRecipe.fingerprint),
            values: dataText(formRecipeValues(formulario(resumir: false))))
        let shelf = RecipeShelf(
            recipes: { [reparto.info, reuniones.info] },
            target: { query in
                guard let query else { return reparto }
                return query == "Reuniones" ? reuniones : reparto
            })
        let hechas = Mutex<[String]>([])
        let eventos = Mutex<[PipelineEvent]>([])
        let transcribe = TranscriptionBackend(name: "falso") { _ in
            registro.append("transcribe")
            return Transcript(text: "hola")
        }

        try await Pipeline(
            source: RecordingSource(name: "prueba", locations: []) { [grabacion] },
            ledger: LedgerPort(
                settledKeys: { Set(hechas.withLock { $0 }) },
                markDone: { key, _, _ in hechas.withLock { $0.append(key) } },
                markFailed: { key, _, error in registro.append("falla \(key): \(error)") }),
            backend: transcribe,
            sink: { note in
                registro.append("guarda")
                return URL(fileURLWithPath: "/salida/\(note.recording.key)")
            },
            recipe: Recipe(
                shelf: shelf, runtime: javaScriptCoreRuntime(timeLimit: 10), publishers: [:],
                catalog: RecipeCatalog(
                    stts: [RecipeResolver(key: "whisper", name: "Whisper en este Mac", isLocal: true)],
                    llms: [RecipeResolver(key: "apple", name: "Apple Intelligence", isLocal: true)],
                    transcriber: { _, _ in transcribe })),
            onEvent: { evento in eventos.withLock { $0.append(evento) } }
        ).runOnce()

        let traza = eventos.withLock { $0 }.compactMap { evento in
            if case .traced(_, let trace) = evento { trace } else { nil }
        }.first
        #expect(hechas.withLock { $0 } == ["a"])
        #expect(registro.values == ["transcribe", "guarda"])
        #expect(traza?.logs.map(\.text) == ["soy codigo"])
        #expect(traza?.steps.map(\.title).last == "receta · Reuniones")
        #expect(traza?.steps.dropLast().allSatisfy { $0.origin == "Reuniones" } == true)
    }

    @Test("todo lo que declara escriba-recetas.d.ts existe en lo que recibe la receta")
    func contrato() async throws {
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tipos = try String(contentsOf: raiz.appending(path: "recetas/escriba-recetas.d.ts"), encoding: .utf8)
        let declarado = miembros(de: ["Audio", "Nota", "Conector", "Receta", "Escriba", "ListasDeEscriba"], en: tipos)
        let json = String(decoding: try JSONEncoder().encode(declarado), as: UTF8.self)
        let registro = Registro()

        try await ejecutar(
            paquete("""
                const nota = await escriba.transcribir(audio)
                const vistos = {
                  Audio: audio, Nota: nota, Conector: escriba.conector('x'), Receta: escriba.receta('x'), Escriba: escriba,
                  ListasDeEscriba: escriba,
                }
                const declarado = \(json)
                const faltan = Object.keys(vistos).flatMap((tipo) =>
                  declarado[tipo].filter((nombre) => !(nombre in vistos[tipo])).map((nombre) => `${tipo}.${nombre}`))
                escriba.log(`faltan: ${faltan.join(', ')}`)
                """),
            puente(registro))

        #expect(declarado.values.allSatisfy { !$0.isEmpty })
        #expect(registro.values.last == "log faltan: ")
    }
}

private func miembros(de tipos: [String], en declaraciones: String) -> [String: [String]] {
    var resultado: [String: [String]] = [:]
    for tipo in tipos {
        guard
            let inicio = declaraciones.range(of: "interface \(tipo)[ <][^{]*\\{", options: .regularExpression),
            let fin = declaraciones[inicio.upperBound...].range(of: "\n}")
        else { continue }
        resultado[tipo] = declaraciones[inicio.upperBound..<fin.lowerBound]
            .split(separator: "\n")
            .compactMap { linea in
                linea.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "readonly ", with: "")
                    .split(whereSeparator: { $0 == ":" || $0 == "(" || $0 == "<" })
                    .first.map(String.init)
            }
            .filter { !$0.isEmpty }
    }
    return resultado
}
