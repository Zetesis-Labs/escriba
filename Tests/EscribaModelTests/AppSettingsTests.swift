import Foundation
import Testing

@testable import EscribaModel
import EscribaCore

private func freshDefaults() -> UserDefaults {
    let name = "jpr-settings-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Ajustes persistentes")
struct AppSettingsTests {
    @Test("los valores por defecto son los que la app tiene hoy clavados")
    func porDefecto() {
        let settings = AppSettings(defaults: freshDefaults(), voiceMemos: nil)

        #expect(settings.notifyEveryNote)
        #expect(settings.watchedFolders.isEmpty)
    }

    @Test("la primera vez, el libro nace con una receta de formulario «Por defecto» con los ajustes de hoy y se guarda")
    func libroMigradoDeLosAjustes() {
        let defaults = freshDefaults()
        defaults.set("en", forKey: "language")
        defaults.set(2, forKey: "diarization")
        defaults.set(true, forKey: "summarize")

        let ahora = AppSettings(defaults: defaults, voiceMemos: nil)

        #expect(ahora.recipeBook.forms.map(\.name) == ["Por defecto"])
        #expect(ahora.recipeBook.forms.first.flatMap { ahora.recipeBook.values[$0.key] } == dataText(formRecipeValues(
            DefaultRecipeSettings(
                stt: "whisper", language: "en", detectSpeakers: true, speakerCount: 2, summarize: true, llm: "apple",
                prompt: nil, connectors: []))))
        #expect(ahora.recipeBook.defaultKey == ahora.recipeBook.forms.first?.key)
        #expect(defaults.data(forKey: "recipeBook") != nil)
    }

    @Test("si ya habia receta por defecto guardada, el libro nace de ella")
    func libroMigradoDeLaRecetaPorDefecto() throws {
        let defaults = freshDefaults()
        let guardada = DefaultRecipeSettings(
            stt: "whisper", language: nil, detectSpeakers: true, speakerCount: 3, summarize: true, llm: "apple",
            prompt: "Breve", connectors: [])
        defaults.set(try JSONEncoder().encode(guardada), forKey: "defaultRecipe")

        let settings = AppSettings(defaults: defaults, voiceMemos: nil)

        #expect(settings.recipeBook.forms.map { settings.recipeBook.values[$0.key] } == [dataText(formRecipeValues(guardada))])
    }

    @Test("lo que se cambia en las recetas sobrevive a una instancia nueva")
    func libroPersiste() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults, voiceMemos: nil)
        let nueva = settings.recipeBook.add(key: "F2", name: "Reuniones")
        settings.recipeBook.makeDefault(nueva.key)

        let otra = AppSettings(defaults: defaults, voiceMemos: nil)

        #expect(otra.recipeBook == settings.recipeBook)
        #expect(otra.recipeBook.defaultKey == "F2")
    }

    @Test("la clave de un resolutor para las recetas: fija en los locales, su id en los remotos")
    func claveDeResolutor() {
        let remoto = Resolver(name: "Groq", kind: .remote)

        #expect(Resolver.local(.stt).recipeKey(role: .stt) == "whisper")
        #expect(Resolver.local(.llm).recipeKey(role: .llm) == "apple")
        #expect(remoto.recipeKey(role: .llm) == remoto.id.uuidString)
    }

    @Test("lo cambiado sobrevive a una instancia nueva")
    func persiste() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults, voiceMemos: nil)

        settings.notifyEveryNote = false
        settings.watchedFolders = [WatchedFolder(path: "/tmp/llamadas")]

        let reloaded = AppSettings(defaults: defaults, voiceMemos: nil)
        #expect(reloaded.notifyEveryNote == false)
        #expect(reloaded.watchedFolders == [WatchedFolder(path: "/tmp/llamadas")])
    }

    @Test("una carpeta vigilada guardada con los campos de antes se lee igual")
    func carpetaAntigua() throws {
        let antigua = #"{"path":"/tmp/llamadas","speakers":2,"style":"any","resolvers":{"stt":"6A0C0FE1-0000-0000-0000-000000000000"}}"#

        let carpeta = try JSONDecoder().decode(WatchedFolder.self, from: Data(antigua.utf8))

        #expect(carpeta == WatchedFolder(path: "/tmp/llamadas"))
    }
}

@Suite("La carpeta por defecto viene de fuera, no del codigo")
struct DefaultRecorderRootTests {
    private let home = URL(fileURLWithPath: "/Users/prueba")

    @Test("precedencia: argumento > entorno > Info.plist")
    func precedencia() {
        let all = defaultRecorderRoot(
            argument: "/de/argumento", environment: ["ESCRIBA_ROOT": "/de/entorno"],
            bundle: "/de/plist", home: home)
        #expect(all?.path(percentEncoded: false) == "/de/argumento")

        let sinArgumento = defaultRecorderRoot(
            argument: nil, environment: ["ESCRIBA_ROOT": "/de/entorno"],
            bundle: "/de/plist", home: home)
        #expect(sinArgumento?.path(percentEncoded: false) == "/de/entorno")

        let soloPlist = defaultRecorderRoot(
            argument: nil, environment: [:], bundle: "/de/plist", home: home)
        #expect(soloPlist?.path(percentEncoded: false) == "/de/plist")
    }

    @Test("una ruta relativa cuelga de home; sin valor no hay carpeta")
    func rutas() {
        let relativa = defaultRecorderRoot(
            argument: nil, environment: [:], bundle: "Library/Grabaciones", home: home)
        #expect(relativa?.path(percentEncoded: false) == "/Users/prueba/Library/Grabaciones")

        #expect(defaultRecorderRoot(argument: nil, environment: [:], bundle: nil, home: home) == nil)
    }
}

@Suite("Siembra de la carpeta por defecto")
struct SeedingTests {
    @Test("primer arranque: la carpeta del grabador aparece como vigilada, estilo JPR")
    func siembra() {
        let settings = AppSettings(
            defaults: freshDefaults(),
            recorderRoot: URL(fileURLWithPath: "/tmp/jpr"),
            voiceMemos: nil)

        #expect(settings.watchedFolders == [
            WatchedFolder(path: "/tmp/jpr", style: .justPressRecord)
        ])
    }

    @Test("si el usuario la borro, borrada se queda: no se resiembra")
    func noResiembra() {
        let defaults = freshDefaults()
        let root = URL(fileURLWithPath: "/tmp/jpr")

        let primera = AppSettings(defaults: defaults, recorderRoot: root, voiceMemos: nil)
        primera.watchedFolders = []

        let segunda = AppSettings(defaults: defaults, recorderRoot: root, voiceMemos: nil)
        #expect(segunda.watchedFolders.isEmpty)
    }

    @Test("quitar una carpeta vigilada por su ruta quita solo esa y sobrevive al siguiente arranque")
    func quitarPorRuta() {
        let defaults = freshDefaults()
        let root = URL(fileURLWithPath: "/tmp/jpr")
        let primera = AppSettings(defaults: defaults, recorderRoot: root, voiceMemos: URL(fileURLWithPath: "/tmp/memos"))
        primera.watchedFolders.append(WatchedFolder(path: "/tmp/llamadas"))

        primera.removeWatchedFolder(path: "/tmp/jpr")

        #expect(primera.watchedFolders.map(\.path) == ["/tmp/memos", "/tmp/llamadas"])
        let segunda = AppSettings(defaults: defaults, recorderRoot: root, voiceMemos: URL(fileURLWithPath: "/tmp/memos"))
        #expect(segunda.watchedFolders.map(\.path) == ["/tmp/memos", "/tmp/llamadas"])
    }

    @Test("las carpetas guardadas sin estilo se leen como carpetas normales")
    func compatibilidad() {
        let defaults = freshDefaults()
        defaults.set(Data(#"[{"path":"/tmp/viejas"}]"#.utf8), forKey: "watchedFolders")

        let settings = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: nil)
        #expect(settings.watchedFolders == [WatchedFolder(path: "/tmp/viejas", style: .any)])
    }
}

@Suite("Notas de Voz llega a las instalaciones que ya existian")
struct VoiceMemosAdoptionTests {
    private let memos = URL(fileURLWithPath: "/tmp/memos")

    @Test("una instalacion con carpetas guardadas la recibe la primera vez")
    func llegaUnaVez() {
        let defaults = freshDefaults()
        _ = AppSettings(
            defaults: defaults, recorderRoot: URL(fileURLWithPath: "/tmp/jpr"), voiceMemos: nil)

        let despues = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: memos)

        #expect(despues.watchedFolders.map(\.style) == [.justPressRecord, .voiceMemos])
    }

    @Test("si el usuario la quita, no vuelve en el siguiente arranque")
    func noVuelve() {
        let defaults = freshDefaults()
        let primera = AppSettings(
            defaults: defaults, recorderRoot: URL(fileURLWithPath: "/tmp/jpr"), voiceMemos: memos)
        primera.watchedFolders.removeAll { $0.style == .voiceMemos }

        let segunda = AppSettings(defaults: defaults, recorderRoot: nil, voiceMemos: memos)

        #expect(segunda.watchedFolders.map(\.style) == [.justPressRecord])
    }
}

@Suite("Carpeta de Notas de Voz")
struct VoiceMemosFolderTests {
    @Test("la ruta cuelga del contenedor compartido de Notas de Voz")
    func ruta() {
        let home = URL(fileURLWithPath: "/Users/prueba")

        #expect(
            voiceMemosRoot(home: home).path(percentEncoded: false)
                == "/Users/prueba/Library/Group Containers/"
                    + "group.com.apple.VoiceMemos.shared/Recordings")
    }

    @Test("el estilo notas de voz sobrevive a guardar y releer")
    func estiloPersiste() throws {
        let folder = WatchedFolder(path: "/x", style: .voiceMemos)

        let leido = try JSONDecoder().decode(
            WatchedFolder.self, from: try JSONEncoder().encode(folder))

        #expect(leido.style == .voiceMemos)
    }
}
