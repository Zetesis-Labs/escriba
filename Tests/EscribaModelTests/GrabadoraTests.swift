import Foundation
import Testing
import EscribaCore
import EscribaSystemKit

@testable import EscribaModel

@MainActor
private final class Registro {
    var eventos: [String] = []
    var permiso = true
    var fallaAlEmpezar = false
    var fallaAlTerminar = false
    var decibelios: Float = -30
    var segundos: TimeInterval = 0
    var nombres: Set<String> = []
    var copiados: [(URL, String)] = []
    var despertado = 0

    var grabadora: AudioRecorder {
        AudioRecorder(
            requestPermission: { self.permiso },
            start: { url in
                if self.fallaAlEmpezar { throw CocoaError(.fileWriteNoPermission) }
                self.eventos.append("empieza:\(url.lastPathComponent)")
            },
            stop: { self.eventos.append("para") },
            cancel: { self.eventos.append("cancela") },
            decibels: { self.decibelios },
            elapsed: { self.segundos })
    }

    var bandeja: Inbox {
        Inbox(
            root: URL(fileURLWithPath: "/bandeja"),
            names: { MainActor.assumeIsolated { self.nombres } },
            importFile: { origen, nombre in
                try MainActor.assumeIsolated {
                    if origen.lastPathComponent.hasPrefix("roto") { throw CocoaError(.fileReadNoPermission) }
                    self.copiados.append((origen, nombre))
                }
            },
            recordingURL: { URL(fileURLWithPath: "/bandeja/.grabando/temporal.m4a") },
            finishRecording: { temporal, nombre, inicio in
                try MainActor.assumeIsolated {
                    if self.fallaAlTerminar { throw CocoaError(.fileWriteOutOfSpace) }
                    self.eventos.append("guarda:\(temporal.lastPathComponent)->\(nombre)@\(Int(inicio.timeIntervalSince1970))")
                }
            },
            discardRecording: { temporal in
                MainActor.assumeIsolated { self.eventos.append("borra:\(temporal.lastPathComponent)") }
            })
    }
}

private let inicio = Date(timeIntervalSince1970: 1_791_219_600)
private let madrid = TimeZone(identifier: "Europe/Madrid")!

@MainActor
private func grabadora(_ registro: Registro) -> RecorderModel {
    RecorderModel(
        recorder: registro.grabadora, inbox: registro.bandeja, wake: { registro.despertado += 1 },
        now: { inicio }, timeZone: madrid, ticks: false)
}

@MainActor
@Suite("Grabadora")
struct GrabadoraTests {
    @Test("con permiso, grabar empieza en el fichero temporal de la bandeja")
    func empieza() async {
        let registro = Registro()
        let modelo = grabadora(registro)

        await modelo.start()

        #expect(modelo.state == .recording(inicio))
        #expect(modelo.isRecording)
        #expect(registro.eventos == ["empieza:temporal.m4a"])
    }

    @Test("detener guarda la grabacion con su hora de inicio y despierta al motor para transcribirla")
    func detiene() async {
        let registro = Registro()
        let modelo = grabadora(registro)
        await modelo.start()

        modelo.stop()

        #expect(modelo.state == .idle)
        #expect(registro.eventos == [
            "empieza:temporal.m4a", "para", "guarda:temporal.m4a->Grabación 2026-10-05 19.00.00.m4a@1791219600",
        ])
        #expect(registro.despertado == 1)
    }

    @Test("descartar para y borra el temporal, sin guardar ni transcribir nada")
    func descarta() async {
        let registro = Registro()
        let modelo = grabadora(registro)
        await modelo.start()

        modelo.cancel()

        #expect(modelo.state == .idle)
        #expect(registro.eventos == ["empieza:temporal.m4a", "cancela", "borra:temporal.m4a"])
        #expect(registro.despertado == 0)
    }

    @Test("sin permiso del micrófono no graba y lo dice")
    func sinPermiso() async {
        let registro = Registro()
        registro.permiso = false
        let modelo = grabadora(registro)

        await modelo.start()

        #expect(modelo.state == .denied)
        #expect(registro.eventos.isEmpty)
        #expect(modelo.problem?.contains("Micrófono") == true)
    }

    @Test("si no puede empezar o no puede guardar, queda el motivo a la vista")
    func fallos() async {
        let empezar = Registro()
        empezar.fallaAlEmpezar = true
        let noEmpieza = grabadora(empezar)
        await noEmpieza.start()
        #expect(noEmpieza.problem?.hasPrefix("No se pudo empezar a grabar") == true)
        #expect(!noEmpieza.isRecording)

        let guardar = Registro()
        guardar.fallaAlTerminar = true
        let noGuarda = grabadora(guardar)
        await noGuarda.start()
        noGuarda.stop()
        #expect(noGuarda.problem?.hasPrefix("No se pudo guardar la grabación") == true)
        #expect(guardar.despertado == 0)

        noGuarda.dismissProblem()
        #expect(noGuarda.state == .idle)
    }

    @Test("pulsar grabar mientras ya graba no abre otra grabacion")
    func unaSola() async {
        let registro = Registro()
        let modelo = grabadora(registro)
        await modelo.start()

        await modelo.start()

        #expect(registro.eventos == ["empieza:temporal.m4a"])
    }

    @Test("mientras graba, el nivel y el tiempo siguen al micrófono")
    func nivel() async {
        let registro = Registro()
        let modelo = grabadora(registro)
        await modelo.start()
        registro.decibelios = 0
        registro.segundos = 75

        modelo.refresh()

        #expect(modelo.level == 1)
        #expect(modelo.elapsed == 75)
        #expect(modelo.clock == "01:15")
    }
}

@MainActor
@Suite("Añadir audios a la bandeja")
struct AnadirAudioTests {
    @Test("solo entra el audio, con nombres que no pisan lo que ya hay, y se despierta al motor")
    func anade() {
        let registro = Registro()
        registro.nombres = ["Llamada.m4a"]
        let modelo = InboxModel(inbox: registro.bandeja, wake: { registro.despertado += 1 })

        let resultado = modelo.add([
            URL(fileURLWithPath: "/x/Llamada.m4a"), URL(fileURLWithPath: "/x/acta.pdf"),
        ])

        #expect(registro.copiados.map(\.1) == ["Llamada 2.m4a"])
        #expect(resultado == ImportOutcome(added: ["Llamada 2.m4a"], rejected: ["acta.pdf"], failed: []))
        #expect(registro.despertado == 1)
        #expect(modelo.notice == "«Llamada 2.m4a» añadida; se transcribe enseguida. «acta.pdf» no es un audio que Escriba sepa leer.")
    }

    @Test("si nada entra no se despierta al motor, y un fallo al copiar se cuenta")
    func nadaEntra() {
        let registro = Registro()
        let modelo = InboxModel(inbox: registro.bandeja, wake: { registro.despertado += 1 })

        let resultado = modelo.add([URL(fileURLWithPath: "/x/roto.m4a")])

        #expect(resultado.failed == ["roto.m4a"])
        #expect(registro.despertado == 0)
        #expect(modelo.notice == "No se pudo copiar «roto.m4a».")
    }

    @Test("el aviso resume cuando son varios")
    func avisos() {
        #expect(importNotice(ImportOutcome(added: ["a.m4a", "b.m4a", "c.m4a"], rejected: [], failed: []))
            == "3 grabaciones añadidas; se transcriben enseguida.")
        #expect(importNotice(ImportOutcome(added: [], rejected: ["a.pdf", "b.doc"], failed: []))
            == "2 ficheros no son audio que Escriba sepa leer.")
        #expect(importNotice(ImportOutcome(added: [], rejected: [], failed: [])) == nil)
    }
}
