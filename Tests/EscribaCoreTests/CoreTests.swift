import Foundation
import Testing

@testable import EscribaCore

private let root = URL(fileURLWithPath: "/icloud/Documents")

private func recordingURL(_ relative: String) -> URL {
    root.appending(path: relative)
}

private func probe(
    size: Int64 = 1000,
    blocks: Int64 = 8,
    flags: UInt32 = 0,
    modifiedAt: TimeInterval = 100,
    observedAt: TimeInterval = 200
) -> Probe {
    Probe(
        size: size,
        blocks: blocks,
        flags: flags,
        modifiedAt: Date(timeIntervalSince1970: modifiedAt),
        observedAt: Date(timeIntervalSince1970: observedAt)
    )
}

@Suite("Parseo del esquema de nombres de Just Press Record")
struct ParsingTests {
    @Test("extrae fecha, hora y clave del esquema YYYY-MM-DD/HH-MM-SS.m4a")
    func extraeFechaYHora() throws {
        let parsed = try #require(
            RecordingParser.parse(recordingURL("2026-08-28/01-12-19.m4a"), root: root))

        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 28
        components.hour = 1
        components.minute = 12
        components.second = 19
        let esperado = Calendar(identifier: .gregorian).date(from: components)

        #expect(parsed.key == "2026-08-28/01-12-19")
        #expect(parsed.startedAt == esperado)
    }

    @Test("la clave identifica la grabacion de forma estable")
    func claveEstable() throws {
        let parsed = try #require(
            RecordingParser.parse(recordingURL("2026-05-15/18-17-28.m4a"), root: root))
        #expect(parsed.key == "2026-05-15/18-17-28")
    }

    @Test(
        "rechaza lo que no encaja en el esquema",
        arguments: [
            "2026-08-28/notas.m4a",
            "2026-08-28/01-12-19.txt",
            "suelto.m4a",
            "2026-08-28/subdir/01-12-19.m4a",
            "no-es-fecha/01-12-19.m4a",
            "2026-13-45/01-12-19.m4a",
            "2026-02-30/01-12-19.m4a",
            "2026-08-28/25-00-00.m4a",
            "2026-8-28/01-12-19.m4a",
        ])
    func rechazaLoQueNoEncaja(ruta: String) {
        #expect(RecordingParser.parse(recordingURL(ruta), root: root) == nil)
    }

    @Test("acepta la extension en mayusculas")
    func aceptaMayusculas() {
        #expect(RecordingParser.parse(recordingURL("2026-08-28/01-12-19.M4A"), root: root) != nil)
    }
}

@Suite("Cuando una grabacion esta lista para transcribir")
struct ReadinessTests {
    @Test("dataless mientras iCloud no la ha materializado")
    func datalessSinMaterializar() {
        let p = probe(size: 64798, blocks: 0, flags: SF_DATALESS)
        #expect(classify(probe: p, previous: nil, settleSeconds: 15) == .dataless)
    }

    @Test("dataless tiene prioridad sobre cualquier otra senal")
    func datalessManda() {
        let p = probe(size: 0, blocks: 0, flags: SF_DATALESS, modifiedAt: 0)
        #expect(classify(probe: p, previous: nil, settleSeconds: 15) == .dataless)
    }

    @Test("vacia cuando el placeholder todavia no tiene contenido")
    func vacia() {
        #expect(classify(probe: probe(size: 0), previous: nil, settleSeconds: 15) == .empty)
    }

    @Test("un fichero de 0 bytes sin cambios desde hace mas de una hora es una grabacion vacia, no una que se esta escribiendo")
    func vaciaParaSiempre() {
        let reciente = probe(size: 0, modifiedAt: 0, observedAt: 3_000)
        let abandonada = probe(size: 0, modifiedAt: 0, observedAt: 3_700)

        #expect(classify(probe: reciente, previous: nil, settleSeconds: 15) == .empty)
        #expect(classify(probe: abandonada, previous: nil, settleSeconds: 15) == .abandoned)
    }

    @Test("creciendo mientras la grabacion se sigue escribiendo")
    func creciendo() {
        let antes = probe(size: 1000, observedAt: 190)
        let ahora = probe(size: 2000, observedAt: 200)
        #expect(classify(probe: ahora, previous: antes, settleSeconds: 15) == .growing)
    }

    @Test("creciendo si acaba de modificarse aunque no haya observacion previa")
    func reciénModificada() {
        let p = probe(modifiedAt: 195, observedAt: 200)
        #expect(classify(probe: p, previous: nil, settleSeconds: 15) == .growing)
    }

    @Test("lista cuando lleva quieta el tiempo de asentamiento")
    func listaTrasAsentarse() {
        let p = probe(modifiedAt: 100, observedAt: 200)
        #expect(classify(probe: p, previous: nil, settleSeconds: 15) == .ready)
    }

    @Test("el tamano estable no basta si se modifico hace un instante")
    func tamanoEstablePeroRecien() {
        let antes = probe(size: 2000, observedAt: 199)
        let ahora = probe(size: 2000, modifiedAt: 199.5, observedAt: 200)
        #expect(classify(probe: ahora, previous: antes, settleSeconds: 15) == .growing)
    }
}

@Suite("Seleccion de grabaciones pendientes")
struct PendingTests {
    private func recording(_ key: String) throws -> Recording {
        try #require(RecordingParser.parse(recordingURL("\(key).m4a"), root: root))
    }

    @Test("devuelve solo lo que no esta en el ledger")
    func soloLoNoHecho() throws {
        let todas = [try recording("2026-08-28/01-12-19"), try recording("2026-08-28/02-24-42")]
        let pendientes = selectPending(todas, done: ["2026-08-28/01-12-19"])
        #expect(pendientes.map(\.key) == ["2026-08-28/02-24-42"])
    }

    @Test("ordena de la mas antigua a la mas reciente")
    func ordenCronologico() throws {
        let todas = [try recording("2026-08-28/02-24-42"), try recording("2026-05-15/18-17-28")]
        #expect(
            selectPending(todas, done: []).map(\.key) == [
                "2026-05-15/18-17-28", "2026-08-28/02-24-42",
            ])
    }

    @Test("reprocesar es idempotente: no repite lo ya hecho")
    func idempotente() throws {
        let todas = [try recording("2026-08-28/01-12-19")]
        var done: Set<String> = []
        done.formUnion(selectPending(todas, done: done).map(\.key))
        #expect(selectPending(todas, done: done).isEmpty)
    }
}

@Suite("Ritmo del bucle de vigilancia")
struct PacingTests {
    @Test("una grabacion que aun se esta escribiendo se reintenta enseguida, no en el ciclo largo")
    func reintentoCortoConTrabajoEnCurso() {
        let outcome = PassOutcome(processed: 0, deferred: 1)
        #expect(
            nextWakeInterval(after: outcome, retryInterval: 15, reconcileInterval: 300) == 15)
    }

    @Test("sin nada en vuelo se espera al ciclo largo de reconciliacion")
    func cicloLargoSinTrabajo() {
        let outcome = PassOutcome(processed: 3, deferred: 0)
        #expect(
            nextWakeInterval(after: outcome, retryInterval: 15, reconcileInterval: 300) == 300)
    }

    @Test("haber transcrito algo no cancela el reintento corto de lo que sigue pendiente")
    func mezclaDeAmbos() {
        let outcome = PassOutcome(processed: 2, deferred: 1)
        #expect(
            nextWakeInterval(after: outcome, retryInterval: 15, reconcileInterval: 300) == 15)
    }
}
