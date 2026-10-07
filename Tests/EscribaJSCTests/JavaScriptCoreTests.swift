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

private func paquete(_ cuerpo: String) -> RecipePackage {
    RecipePackage(
        key: "prueba",
        source: "var __receta = { receta: { nombre: \"Prueba\" }, flujo: async (audio, escriba) => {\n\(cuerpo)\n} };",
        fingerprint: "prueba")
}

private func nota(_ texto: String = "hola", digest: Digest? = nil) -> RecipeNote {
    RecipeNote(key: "a", version: 1, transcript: Transcript(text: texto), digest: digest)
}

private func puente(
    _ registro: Registro,
    connectors: [String] = [],
    transcribe: @escaping @Sendable () async throws -> RecipeNote = { nota() },
    summarize: @escaping @Sendable () async throws -> RecipeNote = { nota() }
) -> RecipeBridge {
    RecipeBridge(
        audio: recipeAudio(grabacion),
        connectors: connectors,
        transcribe: {
            registro.append("transcribe")
            return try await transcribe()
        },
        summarize: {
            registro.append("resume")
            return try await summarize()
        },
        save: { registro.append("guarda") },
        publish: { registro.append("publica \($0)") },
        log: { registro.append("log \($0)") })
}

private func ejecutar(_ package: RecipePackage, _ bridge: RecipeBridge, limite: Double = 10) async throws {
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
        let lento: @Sendable () async throws -> RecipeNote = {
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

        try await ejecutar(.defaultRecipe, puente(registro, transcribe: lento, summarize: lento))
        latido.cancel()

        #expect(registro.values == ["transcribe", "resume", "guarda"])
        #expect(latidos.withLock { $0 } > 10)
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
            puente(registro, summarize: { nota(digest: Digest(title: "Saludo", summary: "s", tags: [])) }))

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
        let lento: @Sendable () async throws -> RecipeNote = {
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
        let bridge = puente(Registro(), transcribe: { throw TranscriptionError.backendUnavailable("sin clave") })

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
        let bridge = puente(registro, transcribe: { throw TranscriptionError.backendUnavailable("sin clave") })

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

    @Test("todo lo que declara escriba-recetas.d.ts existe en lo que recibe la receta")
    func contrato() async throws {
        let raiz = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let tipos = try String(contentsOf: raiz.appending(path: "recetas/escriba-recetas.d.ts"), encoding: .utf8)
        let declarado = miembros(de: ["Audio", "Nota", "Conector", "Escriba"], en: tipos)
        let json = String(decoding: try JSONEncoder().encode(declarado), as: UTF8.self)
        let registro = Registro()

        try await ejecutar(
            paquete("""
                const nota = await escriba.transcribir(audio)
                const vistos = { Audio: audio, Nota: nota, Conector: escriba.conector('x'), Escriba: escriba }
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
            let inicio = declaraciones.range(of: "interface \(tipo) {"),
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
