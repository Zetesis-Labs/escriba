import Foundation
import Testing

@testable import EscribaCore

private let madrid = TimeZone(identifier: "Europe/Madrid")!

private func fecha(_ texto: String) -> Date {
    let formato = DateFormatter()
    formato.dateFormat = "yyyy-MM-dd HH:mm"
    formato.timeZone = madrid
    return formato.date(from: texto)!
}

@Suite("Como se presenta cada grabacion en la biblioteca")
struct BibliotecaLegibleTests {
    @Test("el titulo sale del resumen; si no hay, de lo que se dijo; y si aun no hay texto, de cuando se grabo")
    func titulo() {
        let resumen = Digest(title: "Prueba numérica", summary: "Se cuenta hasta tres.", tags: [])

        #expect(recordingTitle(digest: resumen, preview: "Probando", startedAt: fecha("2026-10-08 00:18"), timeZone: madrid)
            == "Prueba numérica")
        #expect(recordingTitle(
            digest: nil, preview: "Probando, probando. Un, dos, tres, un, dos, tres y seguimos contando sin parar nunca",
            startedAt: fecha("2026-10-08 00:18"), timeZone: madrid)
            == "Probando, probando. Un, dos, tres, un, dos, tres y seguimos…")
        #expect(recordingTitle(digest: nil, preview: "  ", startedAt: fecha("2026-10-08 00:18"), timeZone: madrid)
            == "Grabación del 8 de octubre de 2026, 00:18")
    }

    @Test("el extracto es la primera frase del resumen, o el principio de lo que se dijo")
    func extracto() {
        let resumen = Digest(title: "T", summary: "Se cuenta hasta tres. Y luego nada.", tags: [])

        #expect(recordingExcerpt(digest: resumen, preview: "Probando") == "Se cuenta hasta tres.")
        #expect(recordingExcerpt(digest: nil, preview: "Probando, probando.\nUn, dos, tres.") == "Probando, probando. Un, dos, tres.")
        #expect(recordingExcerpt(digest: nil, preview: nil) == nil)
    }

    @Test("la fecha se dice como la diria una persona: hoy, ayer, el dia, y el año solo si no es este")
    func cuando() {
        let ahora = fecha("2026-10-08 01:30")

        #expect(recordingWhen(fecha("2026-10-08 00:18"), now: ahora, timeZone: madrid) == "hoy, 00:18")
        #expect(recordingWhen(fecha("2026-10-07 20:01"), now: ahora, timeZone: madrid) == "ayer, 20:01")
        #expect(recordingWhen(fecha("2026-10-05 09:32"), now: ahora, timeZone: madrid) == "5 oct, 09:32")
        #expect(recordingWhen(fecha("2025-08-15 23:50"), now: ahora, timeZone: madrid) == "15 ago 2025")
    }

    @Test("las etiquetas se ensenan hasta tres y el resto se cuenta")
    func etiquetas() {
        #expect(visibleTags(["a", "b"]) == (["a", "b"], 0))
        #expect(visibleTags(["a", "b", "c", "d", "e"]) == (["a", "b", "c"], 2))
    }
}
