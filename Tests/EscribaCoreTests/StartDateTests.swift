import Foundation
import Testing

@testable import EscribaCore

@Suite("Fecha de inicio desde la clave")
struct StartDateTests {
    @Test("una clave JPR contiene su fecha")
    func claveJPR() throws {
        let date = try #require(RecordingParser.startDate(fromKey: "2026-08-31/04-59-05"))
        let componentes = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)

        #expect(componentes.year == 2026)
        #expect(componentes.month == 8)
        #expect(componentes.day == 31)
        #expect(componentes.hour == 4)
        #expect(componentes.minute == 59)
        #expect(componentes.second == 5)
    }

    @Test("el prefijo de carpeta no molesta")
    func conPrefijo() {
        #expect(RecordingParser.startDate(fromKey: "reuniones/2026-08-31/04-59-05") != nil)
    }

    @Test("una clave sin fecha devuelve nil")
    func sinFecha() {
        #expect(RecordingParser.startDate(fromKey: "reuniones/nota-3") == nil)
        #expect(RecordingParser.startDate(fromKey: "suelta") == nil)
        #expect(RecordingParser.startDate(fromKey: "2026-13-40/99-99-99") == nil)
    }
}
