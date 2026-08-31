import Foundation
import Testing

@testable import JPRApp

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
        let settings = AppSettings(defaults: freshDefaults())

        #expect(settings.language == "es")
        #expect(settings.diarization == .off)
        #expect(settings.notifyEveryNote)
        #expect(settings.writeTxt)
        #expect(settings.txtFolderPath.hasSuffix("Transcripciones JPR"))
        #expect(settings.watchedFolders.isEmpty)
    }

    @Test("lo cambiado sobrevive a una instancia nueva")
    func persiste() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.language = "en"
        settings.diarization = .fixed(2)
        settings.notifyEveryNote = false
        settings.writeTxt = false
        settings.txtFolderPath = "/tmp/salida"
        settings.watchedFolders = [WatchedFolder(path: "/tmp/llamadas", speakers: 2)]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.language == "en")
        #expect(reloaded.diarization == .fixed(2))
        #expect(reloaded.notifyEveryNote == false)
        #expect(reloaded.writeTxt == false)
        #expect(reloaded.txtFolderPath == "/tmp/salida")
        #expect(reloaded.watchedFolders == [WatchedFolder(path: "/tmp/llamadas", speakers: 2)])
    }

    @Test("el idioma auto se traduce a nil para el motor")
    func idiomaAuto() {
        let settings = AppSettings(defaults: freshDefaults())

        settings.language = "auto"
        #expect(settings.languageCode == nil)

        settings.language = "es"
        #expect(settings.languageCode == "es")
    }

    @Test("la diarizacion viaja entera por su valor de almacen")
    func diarizacion() {
        #expect(Diarization(storageValue: -1) == .off)
        #expect(Diarization(storageValue: 0) == .auto)
        #expect(Diarization(storageValue: 3) == .fixed(3))
        #expect(Diarization.off.storageValue == -1)
        #expect(Diarization.auto.storageValue == 0)
        #expect(Diarization.fixed(3).storageValue == 3)
    }
}

@Suite("La carpeta por defecto viene de fuera, no del codigo")
struct DefaultRecorderRootTests {
    private let home = URL(fileURLWithPath: "/Users/prueba")

    @Test("precedencia: argumento > entorno > Info.plist")
    func precedencia() {
        let all = defaultRecorderRoot(
            argument: "/de/argumento", environment: ["JPR_TRANSCRIBE_ROOT": "/de/entorno"],
            bundle: "/de/plist", home: home)
        #expect(all?.path(percentEncoded: false) == "/de/argumento")

        let sinArgumento = defaultRecorderRoot(
            argument: nil, environment: ["JPR_TRANSCRIBE_ROOT": "/de/entorno"],
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
            defaults: freshDefaults(), recorderRoot: URL(fileURLWithPath: "/tmp/jpr"))

        #expect(settings.watchedFolders == [
            WatchedFolder(path: "/tmp/jpr", style: .justPressRecord)
        ])
    }

    @Test("si el usuario la borro, borrada se queda: no se resiembra")
    func noResiembra() {
        let defaults = freshDefaults()
        let root = URL(fileURLWithPath: "/tmp/jpr")

        let primera = AppSettings(defaults: defaults, recorderRoot: root)
        primera.watchedFolders = []

        let segunda = AppSettings(defaults: defaults, recorderRoot: root)
        #expect(segunda.watchedFolders.isEmpty)
    }

    @Test("las carpetas guardadas sin estilo se leen como carpetas normales")
    func compatibilidad() {
        let defaults = freshDefaults()
        defaults.set(Data(#"[{"path":"/tmp/viejas"}]"#.utf8), forKey: "watchedFolders")

        let settings = AppSettings(defaults: defaults, recorderRoot: nil)
        #expect(settings.watchedFolders == [WatchedFolder(path: "/tmp/viejas", style: .any)])
    }
}
