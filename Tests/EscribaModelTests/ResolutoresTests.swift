import Foundation
import Synchronization
import Testing
import EscribaCore

@testable import EscribaModel

private func ajustes(_ defaults: UserDefaults = nuevos()) -> AppSettings {
    AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
}

private func nuevos() -> UserDefaults {
    UserDefaults(suiteName: "escriba-resolutores-\(UUID().uuidString)")!
}

private let openAI = remotePresets(for: .llm).first { $0.name == "OpenAI" }!
private let groq = remotePresets(for: .stt).first { $0.name == "Groq" }!

@Suite("Resolutores: la lista y lo que usa cada origen")
struct ResolutoresTests {
    @Test("de serie cada papel tiene su resolutor local")
    func deSerie() {
        let settings = ajustes()

        #expect(settings.resolvers(.stt).resolvers.map(\.name) == ["Whisper en este Mac"])
        #expect(settings.resolvers(.llm).resolvers.map(\.name) == ["Apple Intelligence"])
        #expect(settings.resolvers(.stt).resolver(nil).kind == .local)
        #expect(settings.resolvers(.llm).resolver(nil).id == ResolverRole.llm.localID)
        #expect(ResolverRole.stt.localID != ResolverRole.llm.localID)
    }

    @Test("el resolutor local no se puede quitar")
    func quitar() {
        var lista = ResolverSet(role: .llm)
        let remoto = Resolver.remote(openAI, role: .llm, name: "OpenAI")
        lista.add(remoto)

        lista.remove(ResolverRole.llm.localID)
        #expect(lista.resolvers.count == 2)

        lista.remove(remoto.id)
        #expect(lista.resolvers.map(\.kind) == [.local])
    }

    @Test("lo que no se elige, o ya no existe, va al local")
    func resolucion() {
        var lista = ResolverSet(role: .stt)
        let remoto = Resolver.remote(groq, role: .stt, name: "Groq")
        lista.add(remoto)

        #expect(lista.resolver(nil).kind == .local)
        #expect(lista.resolver(remoto.id) == remoto)
        #expect(lista.resolver(UUID()).kind == .local)
    }

    @Test("una lista guardada sin el local lo recupera al leerla, y el favorito de antes solo se lee para migrar")
    func lecturaTolerante() throws {
        let remoto = Resolver.remote(openAI, role: .llm, name: "OpenAI")
        let guardada = #"{"role":"llm","resolvers":[\#(String(decoding: try JSONEncoder().encode(remoto), as: UTF8.self))],"favorite":"\#(remoto.id.uuidString)"}"#

        let leida = try JSONDecoder().decode(ResolverSet.self, from: Data(guardada.utf8))
        let reescrita = String(decoding: try JSONEncoder().encode(leida), as: UTF8.self)

        #expect(leida.resolvers.map(\.kind) == [.local, .remote])
        #expect(leida.legacyFavorite == remoto.id)
        #expect(leida.resolver(nil).kind == .local)
        #expect(!reescrita.contains("favorite"))
    }

    @Test("los nombres de los que se añaden no se repiten")
    func nombres() {
        var lista = ResolverSet(role: .llm)
        lista.add(Resolver.remote(openAI, role: .llm, name: nextResolverName(openAI.name, in: lista)))
        lista.add(Resolver.remote(openAI, role: .llm, name: nextResolverName(openAI.name, in: lista)))

        #expect(lista.resolvers.map(\.name) == ["Apple Intelligence", "OpenAI", "OpenAI 2"])
    }

    @Test("los atajos de servicio rellenan la URL y, si se sabe, el modelo; los de STT solo transcriben")
    func atajos() {
        #expect(groq.baseURL == "https://api.groq.com/openai/v1")
        #expect(!groq.model.isEmpty)
        #expect(remotePresets(for: .llm).map(\.name).contains("Ollama"))
        #expect(!remotePresets(for: .stt).map(\.name).contains("Ollama"))
        #expect(remotePresets(for: .llm).allSatisfy { $0.baseURL.isEmpty || $0.baseURL.hasSuffix("/v1") })
    }

    @Test("una carpeta vigilada guardada antes de los resolutores se lee sin eleccion")
    func carpetaAntigua() throws {
        let antigua = #"{"path":"/tmp/llamadas","speakers":2,"style":"any"}"#

        let carpeta = try JSONDecoder().decode(WatchedFolder.self, from: Data(antigua.utf8))

        #expect(carpeta.resolvers == ResolverChoice())
    }

    @Test("lo que usa cada grabacion se decide por su origen: la bandeja, su carpeta o ninguno")
    func porOrigen() {
        let settings = ajustes()
        let deGroq = UUID()
        let deOpenAI = UUID()
        settings.watchedFolders = [
            WatchedFolder(path: "/notas/llamadas", resolvers: ResolverChoice(stt: deGroq)),
            WatchedFolder(path: "/notas"),
        ]
        settings.inboxResolvers = ResolverChoice(llm: deOpenAI)

        #expect(settings.resolverChoice(forSource: "/notas/llamadas/a.m4a", inbox: "/bandeja") == ResolverChoice(stt: deGroq))
        #expect(settings.resolverChoice(forSource: "/notas/b.m4a", inbox: "/bandeja") == ResolverChoice())
        #expect(settings.resolverChoice(forSource: "/bandeja/c.m4a", inbox: "/bandeja") == ResolverChoice(llm: deOpenAI))
        #expect(settings.resolverChoice(forSource: "/otra/d.m4a", inbox: "/bandeja") == ResolverChoice())
    }

    @Test("resolutores y eleccion de cada origen sobreviven a una instancia nueva")
    func persiste() {
        let defaults = nuevos()
        let settings = ajustes(defaults)
        var lista = settings.resolvers(.stt)
        let remoto = Resolver.remote(groq, role: .stt, name: "Groq")
        lista.add(remoto)
        settings.setResolvers(lista, for: .stt)
        settings.inboxResolvers = ResolverChoice(stt: ResolverRole.stt.localID)
        settings.watchedFolders = [WatchedFolder(path: "/notas", resolvers: ResolverChoice(llm: UUID()))]

        let otra = ajustes(defaults)

        #expect(otra.resolvers(.stt) == lista)
        #expect(otra.inboxResolvers == settings.inboxResolvers)
        #expect(otra.watchedFolders == settings.watchedFolders)
    }
}

private nonisolated final class Servicios: Sendable {
    let modelos = Mutex<Result<[String], ResolverTestError>>(.success(["gpt-b", "gpt-a"]))
    let llamadas = Mutex<[String]>([])

    var servicios: ResolverServices {
        ResolverServices(
            models: { resolver, clave in
                self.llamadas.withLock { $0.append("modelos:\(resolver.baseURL):\(clave ?? "-")") }
                return try self.modelos.withLock { $0 }.get()
            },
            summarize: { resolver, clave, texto in
                self.llamadas.withLock { $0.append("resume:\(resolver.model):\(clave ?? "-"):\(resolver.prompt ?? "serie")") }
                guard texto.contains("lanzamiento") else { throw ResolverTestError.otro }
                return Digest(title: "Lanzamiento", summary: "Se aplaza.", tags: ["plan"])
            },
            transcribe: { resolver, clave in
                self.llamadas.withLock { $0.append("transcribe:\(resolver.model):\(clave ?? "-")") }
                return ""
            },
            localProblem: { role in role == .llm ? "el modelo del sistema aún se está descargando" : nil })
    }
}

private nonisolated final class Claves: Sendable {
    let valores = Mutex<[UUID: String]>([:])

    subscript(id: UUID) -> String? {
        get { valores.withLock { $0[id] } }
        set { valores.withLock { $0[id] = newValue } }
    }
}

private nonisolated enum ResolverTestError: Error, CustomStringConvertible {
    case sinSaldo
    case otro

    var description: String { self == .sinSaldo ? "El servicio está limitando las peticiones" : "otro" }
}

@MainActor
@Suite("Editar resolutores desde su panel")
struct PanelDeResolutoresTests {
    private func panel(_ role: ResolverRole, _ settings: AppSettings = ajustes(), _ servicios: Servicios = Servicios(),
                       claves: Claves = Claves()) -> ResolversModel {
        ResolversModel(
            role: role, settings: settings,
            tokens: { id in
                TokenStore(
                    read: { claves[id] },
                    write: { valor in claves[id] = valor })
            },
            services: servicios.servicios)
    }

    @Test("añadir un servicio lo deja en la lista con su URL y su modelo")
    func anadir() {
        let settings = ajustes()
        let modelo = panel(.stt, settings)

        let nuevo = modelo.add(groq)

        #expect(settings.resolvers(.stt).resolvers.last == nuevo)
        #expect(nuevo.kind == .remote)
        #expect(nuevo.baseURL == groq.baseURL)
        #expect(nuevo.model == groq.model)
    }

    @Test("quitar un resolutor borra su clave, suelta a los origenes que lo usaban y devuelve al local a la receta")
    func quitar() {
        let settings = ajustes()
        let claves = Claves()
        let modelo = panel(.llm, settings, claves: claves)
        let nuevo = modelo.add(openAI)
        claves[nuevo.id] = "sk-1"
        settings.watchedFolders = [WatchedFolder(path: "/notas", resolvers: ResolverChoice(stt: UUID(), llm: nuevo.id))]
        settings.inboxResolvers = ResolverChoice(llm: nuevo.id)
        settings.defaultRecipe.llm = nuevo.recipeKey(role: .llm)

        modelo.remove(nuevo.id)

        #expect(settings.resolvers(.llm).resolvers.count == 1)
        #expect(claves[nuevo.id] == nil)
        #expect(settings.watchedFolders[0].resolvers.llm == nil)
        #expect(settings.watchedFolders[0].resolvers.stt != nil)
        #expect(settings.inboxResolvers.llm == nil)
        #expect(settings.defaultRecipe.llm == "apple")
    }

    @Test("el editor trabaja sobre un borrador: guardar escribe resolutor y clave, descartar vuelve atras")
    func borrador() {
        let settings = ajustes()
        let claves = Claves()
        let modelo = panel(.llm, settings, claves: claves)
        let nuevo = modelo.add(openAI)
        let editor = modelo.editor(for: nuevo.id)

        editor.name = "Mi OpenAI"
        editor.model = "gpt-a"
        editor.key = "  sk-1 "
        #expect(editor.isDirty)
        #expect(settings.resolvers(.llm).resolver(nuevo.id).name == "OpenAI")

        editor.save()
        #expect(!editor.isDirty)
        #expect(settings.resolvers(.llm).resolver(nuevo.id).name == "Mi OpenAI")
        #expect(settings.resolvers(.llm).resolver(nuevo.id).model == "gpt-a")
        #expect(claves[nuevo.id] == "sk-1")

        editor.baseURL = "https://otro.example.com/v1"
        editor.discard()
        #expect(editor.baseURL == openAI.baseURL)
        #expect(!editor.isDirty)
    }

    @Test("el prompt muestra el de serie; tocarlo lo guarda y restaurarlo vuelve a seguir al de serie")
    func prompt() {
        let settings = ajustes()
        let editor = panel(.llm, settings).editor(for: ResolverRole.llm.localID)

        #expect(editor.prompt == DigestPrompt.standard)
        #expect(editor.usesStandardPrompt)

        editor.prompt = "Resume como un acta."
        editor.save()
        #expect(settings.resolvers(.llm).local.prompt == "Resume como un acta.")
        #expect(!editor.usesStandardPrompt)

        editor.restoreStandardPrompt()
        editor.save()
        #expect(settings.resolvers(.llm).local.prompt == nil)

        editor.prompt = DigestPrompt.standard + "\n"
        #expect(!editor.isDirty)
    }

    @Test("lo que falta para usar un resolutor se dice antes de guardar")
    func pendiente() {
        let modelo = panel(.llm)
        let local = modelo.editor(for: ResolverRole.llm.localID)
        let remoto = modelo.editor(for: modelo.add(remotePresets(for: .llm).first { $0.baseURL.isEmpty }!).id)

        #expect(local.readiness == "el modelo del sistema aún se está descargando")
        #expect(remoto.readiness == "Escribe la URL de la API.")
        remoto.baseURL = "http://api.example.com/v1"
        #expect(remoto.readiness == "Usa https:// para un servicio fuera de tu red.")
        remoto.baseURL = "http://localhost:11434/v1"
        #expect(remoto.readiness == "Elige el modelo.")
        remoto.model = "llama3"
        #expect(remoto.readiness == nil)
        #expect(panel(.stt).editor(for: ResolverRole.stt.localID).readiness == nil)
    }

    @Test("cargar modelos usa la URL y la clave del borrador y los deja ordenados para elegir")
    func modelos() async {
        let servicios = Servicios()
        let modelo = panel(.llm, ajustes(), servicios)
        let editor = modelo.editor(for: modelo.add(openAI).id)
        editor.key = "sk-borrador"

        await editor.loadModels()

        #expect(editor.models == ["gpt-a", "gpt-b"])
        #expect(servicios.llamadas.withLock { $0 } == ["modelos:\(openAI.baseURL):sk-borrador"])
        #expect(editor.phase == .idle)
    }

    @Test("si cargar modelos falla, el motivo queda a la vista y la lista se vacia")
    func modelosFallan() async {
        let servicios = Servicios()
        servicios.modelos.withLock { $0 = .failure(.sinSaldo) }
        let modelo = panel(.llm, ajustes(), servicios)
        let editor = modelo.editor(for: modelo.add(openAI).id)

        await editor.loadModels()

        #expect(editor.models.isEmpty)
        #expect(editor.phase == .failed("El servicio está limitando las peticiones"))
    }

    @Test("probar un LLM resume la nota de ejemplo con el borrador, sin guardar nada")
    func probarLLM() async {
        let settings = ajustes()
        let servicios = Servicios()
        let modelo = panel(.llm, settings, servicios)
        let editor = modelo.editor(for: modelo.add(openAI).id)
        editor.model = "gpt-a"
        editor.prompt = "Acta."
        editor.key = "sk-1"

        await editor.tryIt()

        #expect(editor.trial == .digest(Digest(title: "Lanzamiento", summary: "Se aplaza.", tags: ["plan"])))
        #expect(servicios.llamadas.withLock { $0 } == ["resume:gpt-a:sk-1:Acta."])
        #expect(settings.resolvers(.llm).resolver(editor.id).model == openAI.model)
    }

    @Test("probar un STT transcribe un audio de prueba con el borrador")
    func probarSTT() async {
        let servicios = Servicios()
        let modelo = panel(.stt, ajustes(), servicios)
        let editor = modelo.editor(for: modelo.add(groq).id)
        editor.key = "gsk-1"

        await editor.tryIt()

        #expect(editor.trial == .transcript(""))
        #expect(servicios.llamadas.withLock { $0 } == ["transcribe:\(groq.model):gsk-1"])
    }
}
