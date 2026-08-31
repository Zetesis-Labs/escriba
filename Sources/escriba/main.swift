import Foundation
import EscribaCore
import EscribaKit
import EscribaStore
import EscribaWhisper

let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents")
let defaultOutput = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Documents/Transcripciones JPR")
let defaultState = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".local/state/escriba/ledger.db")
let defaultLibrary = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/escriba/library")

struct Options {
    var command = ""
    var root = defaultRoot
    var output = defaultOutput
    var state = defaultState
    var library = defaultLibrary
    var language = "es"
    var diarize = false
    var backend = "whisperkit"
    var source = "jpr"
    var speakerCount: Int?
    var model: String? = MacWhisperBackend.defaultModel
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())

    while let argument = arguments.first {
        arguments.removeFirst()

        func value(_ name: String) -> String {
            guard let next = arguments.first else { fail("falta el valor de \(name)") }
            arguments.removeFirst()
            return next
        }

        switch argument {
        case "--root": options.root = URL(fileURLWithPath: value("--root"))
        case "--output": options.output = URL(fileURLWithPath: value("--output"))
        case "--state": options.state = URL(fileURLWithPath: value("--state"))
        case "--library": options.library = URL(fileURLWithPath: value("--library"))
        case "--language": options.language = value("--language")
        case "--speakers": options.diarize = true
        case "--backend": options.backend = value("--backend")
        case "--source": options.source = value("--source")
        case "--speakers-count":
            guard let count = Int(value("--speakers-count")), count > 0 else {
                fail("--speakers-count necesita un entero positivo")
            }
            options.speakerCount = count
            options.diarize = true
        case "--model": options.model = value("--model")
        case "-v", "--verbose": Log.verbose = true
        case "watch", "once", "status", "download": options.command = argument
        case "-h", "--help":
            print("""
                uso: escriba <watch|once|status> [opciones]

                  watch    vigila la carpeta y transcribe segun llegan grabaciones
                  once     hace una pasada y sale
                  status   muestra que hay en disco y que se ha transcrito
                  download descarga el modelo de WhisperKit

                opciones:
                  --root <ruta>      carpeta de Just Press Record
                  --output <ruta>    donde escribir las transcripciones
                  --state <ruta>     fichero SQLite del ledger
                  --library <ruta>   biblioteca: SQLite con las transcripciones y copia del audio
                  --language <cod>   idioma ISO 639-1 (por defecto: es)
                  --model <id>       modelo de MacWhisper (engine:model-id)
                  --speakers         detecta hablantes (diarizacion)
                  --speakers-count N si sabes cuantos hablan, fijalo
                  --backend <nombre> whisperkit (por defecto) o macwhisper
                  --source <nombre>  jpr (por defecto) o folder (cualquier audio)
                  -v, --verbose      log detallado
                """)
            exit(0)
        default: fail("opcion desconocida: \(argument)")
        }
    }

    if options.command.isEmpty { fail("falta el comando: watch, once, status o download") }
    guard ["macwhisper", "whisperkit"].contains(options.backend) else {
        fail("backend desconocido: \(options.backend). Usa macwhisper o whisperkit")
    }
    guard ["jpr", "folder"].contains(options.source) else {
        fail("fuente desconocida: \(options.source). Usa jpr o folder")
    }
    return options
}

let options = parseOptions()
LegacyMigration.run()

func makeSource(_ options: Options) -> RecordingSource {
    switch options.source {
    case "folder": folderSource(name: "carpeta", root: options.root)
    default: justPressRecordSource(root: options.root)
    }
}

func makeBackend(_ options: Options) -> TranscriptionBackend {
    switch options.backend {
    case "whisperkit":
        WhisperKitBackend.make(
            language: options.language, diarize: options.diarize,
            speakerCount: options.speakerCount)
    case "macwhisper":
        MacWhisperBackend.make(
            language: options.language, model: options.model, diarize: options.diarize)
    default: fail("backend desconocido: \(options.backend)")
    }
}

if options.command == "download" {
    let destino = WhisperKitBackend.defaultModelsRoot.path(percentEncoded: false)
    print("descargando \(WhisperKitBackend.defaultVariant)")
    print("destino: \(destino)")
    do {
        let folder = try await WhisperKitBackend.downloadModel { fraction in
            FileHandle.standardError.write(Data("\rprogreso: \(Int(fraction * 100))%".utf8))
        }
        print("\nmodelo listo en \(folder.path(percentEncoded: false))")
        exit(0)
    } catch {
        fail("\nno se pudo descargar: \(error)")
    }
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(
    atPath: options.root.path(percentEncoded: false), isDirectory: &isDirectory),
    isDirectory.boolValue
else {
    fail("no existe la carpeta: \(options.root.path(percentEncoded: false))")
}

do {
    let ledger = try Ledger(path: options.state)

    if options.command == "status" {
        let recordings = try FileSystem.scan(root: options.root)
        let counts = try ledger.counts()
        print("grabaciones en disco : \(recordings.count)")
        print("transcritas          : \(counts["done"] ?? 0)")
        print("fallidas             : \(counts["failed"] ?? 0)")
        print("MacWhisper corriendo : \(MacWhisperBackend.isRunning() ? "si" : "no")")

        let modelo = options.model ?? "(el seleccionado en la app)"
        let disponible = (try? MacWhisperBackend.verifyModelAvailable(options.model)) != nil
        print("modelo               : \(modelo)\(disponible ? "" : "  ← NO INSTALADO")")
        let wkFolder = WhisperKitBackend.installedModelFolder()
        print("whisperkit           : \(wkFolder == nil ? "modelo NO descargado (escriba download)" : "listo")")
        print("salida               : \(options.output.path(percentEncoded: false))")
        let library = try Store(root: options.library)
        print("biblioteca           : \(try library.count()) grabaciones en \(options.library.path(percentEncoded: false))")
        for failure in try ledger.failures().prefix(10) {
            print("  ! \(failure.key) (intentos: \(failure.attempts)) \(failure.error.prefix(120))")
        }
        exit(0)
    }

    let lockPath = options.state.deletingLastPathComponent().appending(path: "instance.lock")
    guard let instanceLock = InstanceLock(path: lockPath) else {
        fail(
            "ya hay \(InstanceLock.holderDescription(path: lockPath)) trabajando sobre el mismo ledger."
            + " Cierra Escriba (o el otro proceso) antes de seguir.")
    }

    let backend = makeBackend(options)
    let library = try Store(root: options.library)
    let pipeline = Pipeline(
        source: makeSource(options),
        ledger: ledger,
        backend: backend,
        sink: sinks(
            primary: sidecarTextSink(outputRoot: options.output),
            also: library.sink(backend: backend.name))
    )

    if options.command == "once" {
        try await pipeline.runOnce()
    } else {
        DaemonController(pipeline: pipeline).runBlocking()
    }
    _ = consume instanceLock
} catch {
    fail("\(error)")
}
