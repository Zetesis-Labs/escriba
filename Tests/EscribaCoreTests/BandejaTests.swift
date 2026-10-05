import Foundation
import Testing

@testable import EscribaCore

@Suite("Bandeja: nombres, ficheros soltados y grabaciones")
struct BandejaTests {
    @Test("un fichero conserva su nombre si esta libre; si no, lleva numero, sin distinguir mayusculas")
    func nombres() {
        #expect(inboxName(for: "Reunión.m4a", taken: []) == "Reunión.m4a")
        #expect(inboxName(for: "Reunión.m4a", taken: ["reunión.M4A"]) == "Reunión 2.m4a")
        #expect(inboxName(for: "Reunión.m4a", taken: ["Reunión.m4a", "Reunión 2.m4a"]) == "Reunión 3.m4a")
        #expect(inboxName(for: "sin-extension", taken: ["sin-extension"]) == "sin-extension 2")
    }

    @Test("al soltar varios, solo entra el audio y cada uno con un nombre distinto")
    func soltar() {
        let plan = dropPlan(
            [
                URL(fileURLWithPath: "/a/Llamada.m4a"), URL(fileURLWithPath: "/b/Llamada.m4a"),
                URL(fileURLWithPath: "/c/acta.pdf"), URL(fileURLWithPath: "/d/Notas"),
                URL(fileURLWithPath: "/e/Entrevista.MP3"),
            ],
            taken: ["Entrevista.mp3"])

        #expect(plan.accepted.map(\.name) == ["Llamada.m4a", "Llamada 2.m4a", "Entrevista 2.MP3"])
        #expect(plan.accepted.map(\.source.lastPathComponent) == ["Llamada.m4a", "Llamada.m4a", "Entrevista.MP3"])
        #expect(plan.rejected.map(\.lastPathComponent) == ["acta.pdf", "Notas"])
    }

    @Test("lo que no es un fichero local no entra")
    func remotos() {
        let plan = dropPlan([URL(string: "https://example.com/a.m4a")!], taken: [])

        #expect(plan.accepted.isEmpty)
        #expect(plan.rejected.count == 1)
    }

    @Test("una grabacion se llama por su hora de inicio en la zona del usuario, sin dos puntos")
    func nombreDeGrabacion() {
        let inicio = Date(timeIntervalSince1970: 1_791_219_605)

        #expect(recordingName(startedAt: inicio, timeZone: TimeZone(identifier: "Europe/Madrid")!)
            == "Grabación 2026-10-05 19.00.05.m4a")
        #expect(recordingName(startedAt: inicio, timeZone: TimeZone(identifier: "UTC")!)
            == "Grabación 2026-10-05 17.00.05.m4a")
    }

    @Test("el medidor va de 0 en silencio a 1 en el maximo, sin salirse")
    func medidor() {
        #expect(meterLevel(decibels: -160) == 0)
        #expect(meterLevel(decibels: -60) == 0)
        #expect(meterLevel(decibels: -30) == 0.5)
        #expect(meterLevel(decibels: 0) == 1)
        #expect(meterLevel(decibels: 6) == 1)
        #expect(meterLevel(decibels: .nan) == 0)
    }
}
