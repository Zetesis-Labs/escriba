import Foundation
import Testing

@testable import EscribaKit

@Suite("Invocacion de procesos externos")
struct ShellTests {
    @Test("captura la salida entera aunque supere el buffer de la tuberia")
    func salidaGrandeCompleta() throws {
        let lineas = 30_000
        let result = try Shell.run(
            "/bin/sh",
            arguments: ["-c", "i=1; while [ $i -le \(lineas) ]; do echo \"linea $i\"; i=$((i+1)); done"],
            timeout: 60)

        let recibidas = result.output.split(separator: "\n")
        #expect(result.status == 0)
        #expect(recibidas.count == lineas)
        #expect(recibidas.last == "linea \(lineas)")
    }

    @Test("preserva los acentos y la enie del castellano")
    func conservaUTF8() throws {
        let texto = "Grabación de mañana: ¿qué año?… ñ á é í ó ú ü"
        let result = try Shell.run("/bin/echo", arguments: [texto], timeout: 10)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == texto)
    }

    @Test("no confunde stderr con stdout")
    func separaLosFlujos() throws {
        let result = try Shell.run(
            "/bin/sh", arguments: ["-c", "echo fuera; echo dentro >&2"], timeout: 10)

        #expect(result.output.contains("fuera"))
        #expect(!result.output.contains("dentro"))
        #expect(result.errorOutput.contains("dentro"))
    }

    @Test("propaga el codigo de salida del proceso")
    func codigoDeSalida() throws {
        let result = try Shell.run("/bin/sh", arguments: ["-c", "exit 42"], timeout: 10)
        #expect(result.status == 42)
    }

    @Test("un proceso colgado se corta por timeout y no queda vivo")
    func timeoutMataElProceso() throws {
        let started = Date()
        #expect(throws: TranscriptionError.self) {
            try Shell.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: 2)
        }
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test("un ejecutable que no existe da un error entendible")
    func ejecutableInexistente() {
        #expect(throws: TranscriptionError.self) {
            try Shell.run("/usr/local/bin/no-existe-esto", arguments: [], timeout: 10)
        }
    }
}
