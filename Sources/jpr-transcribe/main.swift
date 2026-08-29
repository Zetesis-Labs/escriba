import Foundation
import JPRCore
import JPRKit

let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents")
let defaultOutput = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Documents/Transcripciones JPR")
let defaultState = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".local/state/jpr-transcribe/ledger.db")
let lockPath = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".local/state/jpr-transcribe/instance.lock")

struct Options {
    var command = ""
    var root = defaultRoot
    var output = defaultOutput
    var state = defaultState
    var language = "es"
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
        case "--language": options.language = value("--language")
        case "--model": options.model = value("--model")
        case "-v", "--verbose": Log.verbose = true
        case "watch", "once", "status": options.command = argument
        case "-h", "--help":
            print("""
                uso: jpr-transcribe <watch|once|status> [opciones]

                  watch    vigila la carpeta y transcribe segun llegan grabaciones
                  once     hace una pasada y sale
                  status   muestra que hay en disco y que se ha transcrito

                opciones:
                  --root <ruta>      carpeta de Just Press Record
                  --output <ruta>    donde escribir las transcripciones
                  --state <ruta>     fichero SQLite del ledger
                  --language <cod>   idioma ISO 639-1 (por defecto: es)
                  --model <id>       modelo de MacWhisper (engine:model-id)
                  -v, --verbose      log detallado
                """)
            exit(0)
        default: fail("opcion desconocida: \(argument)")
        }
    }

    if options.command.isEmpty { fail("falta el comando: watch, once o status") }
    return options
}

let options = parseOptions()

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(
    atPath: options.root.path(percentEncoded: false), isDirectory: &isDirectory),
    isDirectory.boolValue
else {
    fail("no existe la carpeta de Just Press Record: \(options.root.path(percentEncoded: false))")
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
        print("salida               : \(options.output.path(percentEncoded: false))")
        for failure in try ledger.failures().prefix(10) {
            print("  ! \(failure.key) (intentos: \(failure.attempts)) \(failure.error.prefix(120))")
        }
        exit(0)
    }

    guard let instanceLock = InstanceLock(path: lockPath) else {
        fail(
            "ya hay \(InstanceLock.holderDescription(path: lockPath)) trabajando sobre el mismo ledger."
            + " Cierra JPR Transcribe (o el otro proceso) antes de seguir.")
    }
    defer { _ = instanceLock }

    let pipeline = Pipeline(
        root: options.root,
        ledger: ledger,
        backend: MacWhisperBackend.make(language: options.language, model: options.model),
        sink: sidecarTextSink(outputRoot: options.output)
    )

    if options.command == "once" {
        try pipeline.runOnce()
    } else {
        DaemonController(pipeline: pipeline).runBlocking()
    }
} catch {
    fail("\(error)")
}
