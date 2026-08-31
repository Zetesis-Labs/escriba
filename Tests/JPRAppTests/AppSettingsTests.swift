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
