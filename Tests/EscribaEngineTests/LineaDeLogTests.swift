import Testing

@testable import EscribaEngine

@Suite("Lineas del log de la app")
struct LineaDeLogTests {
    @Test("una linea del log se parte en hora, nivel y mensaje")
    func partes() {
        let info = parseLogLine("2026-10-07 23:31:13 INFO   Escriba arrancando")
        let error = parseLogLine("2026-10-07 20:01:09 ERROR  no se pudo arrancar el pipeline: database is locked")

        #expect(info == LogEntry(time: "2026-10-07 23:31:13", level: .info, message: "Escriba arrancando"))
        #expect(error.level == .error)
        #expect(error.message == "no se pudo arrancar el pipeline: database is locked")
    }

    @Test("lo que no tiene el formato se guarda entero, sin nivel")
    func otra() {
        #expect(parseLogLine("algo suelto") == LogEntry(time: nil, level: .other, message: "algo suelto"))
    }
}
