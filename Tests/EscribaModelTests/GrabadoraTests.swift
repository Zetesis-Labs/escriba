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
    var despierto = 0
    var elecciones: [String: ResolverChoice] = [:]

    var eleccionesGuardadas: ChoiceStore {
        ChoiceStore(
            read: { ruta in MainActor.assumeIsolated { self.elecciones[ruta] } },
            write: { ruta, eleccion in
                MainActor.assumeIsolated {
                    self.eventos.append("elige:\(URL(fileURLWithPath: ruta).lastPathComponent)=\(eleccion.map { "\($0.stt?.uuidString.prefix(4) ?? "-")/\($0.llm?.uuidString.prefix(4) ?? "-")" } ?? "nada")")
                    self.elecciones[ruta] = eleccion
                }
            })
    }

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
        recorder: registro.grabadora, inbox: registro.bandeja, choices: registro.eleccionesGuardadas,
        wake: { registro.despertado += 1 },
        keepAwake: {
            registro.despierto += 1
            return { registro.despierto -= 1 }
        },
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
@Suite("Grabadora en segundo plano")
struct GrabadoraEnSegundoPlanoTests {
    @Test("mientras graba, el Mac no se duerme ni la app se pausa; al acabar se suelta")
    func despierto() async {
        let registro = Registro()
        let modelo = grabadora(registro)

        await modelo.start()
        #expect(registro.despierto == 1)
        modelo.stop()
        #expect(registro.despierto == 0)

        await modelo.start()
        modelo.cancel()
        #expect(registro.despierto == 0)
    }

    @Test("si no llega a grabar, no deja el Mac despierto")
    func sinGrabar() async {
        let registro = Registro()
        registro.fallaAlEmpezar = true
        let modelo = grabadora(registro)

        await modelo.start()

        #expect(registro.despierto == 0)
    }

    @Test("al salir de la app, una grabacion en curso se guarda en vez de perderse")
    func alSalir() async {
        let registro = Registro()
        let modelo = grabadora(registro)
        await modelo.start()

        modelo.prepareForQuit()

        #expect(registro.eventos.last?.hasPrefix("guarda:") == true)
        #expect(!modelo.isRecording)
        modelo.prepareForQuit()
        #expect(registro.eventos.filter { $0.hasPrefix("guarda:") }.count == 1)
    }
}

@MainActor
@Suite("Añadir audios a la bandeja")
struct AnadirAudioTests {
    @Test("solo entra el audio, con nombres que no pisan lo que ya hay, y se despierta al motor")
    func anade() {
        let registro = Registro()
        registro.nombres = ["Llamada.m4a"]
        let modelo = InboxModel(inbox: registro.bandeja, choices: registro.eleccionesGuardadas, wake: { registro.despertado += 1 })

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
        let modelo = InboxModel(inbox: registro.bandeja, choices: registro.eleccionesGuardadas, wake: { registro.despertado += 1 })

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

private let groq = UUID(uuidString: "6A0C0000-0000-4000-8000-000000000000")!
private let openAI = UUID(uuidString: "0FE10000-0000-4000-8000-000000000000")!

@MainActor
@Suite("Elegir con que se procesa una grabacion o un audio añadido")
struct EleccionAlGrabarTests {
    @Test("sin elegir nada, la grabacion no deja eleccion y usa lo de la bandeja")
    func sinElegir() async {
        let registro = Registro()
        let modelo = grabadora(registro)
        await modelo.start()

        modelo.stop()

        #expect(registro.elecciones.isEmpty)
        #expect(!registro.eventos.contains { $0.hasPrefix("elige:") })
    }

    @Test("lo elegido se guarda para el fichero final antes de que aparezca, y la siguiente vuelve a no elegir nada")
    func eligeAntesDeGuardar() async {
        let registro = Registro()
        let modelo = grabadora(registro)
        modelo.choice = ResolverChoice(stt: groq, llm: openAI)
        await modelo.start()

        modelo.stop()

        #expect(registro.eventos.suffix(2) == [
            "elige:Grabación 2026-10-05 19.00.00.m4a=6A0C/0FE1",
            "guarda:temporal.m4a->Grabación 2026-10-05 19.00.00.m4a@1791219600",
        ])
        #expect(registro.elecciones["/bandeja/Grabación 2026-10-05 19.00.00.m4a"] == ResolverChoice(stt: groq, llm: openAI))
        #expect(modelo.choice == ResolverChoice())
    }

    @Test("si la grabacion no se puede guardar, su eleccion no se queda huerfana")
    func fallaAlGuardar() async {
        let registro = Registro()
        registro.fallaAlTerminar = true
        let modelo = grabadora(registro)
        modelo.choice = ResolverChoice(llm: openAI)
        await modelo.start()

        modelo.stop()

        #expect(registro.elecciones.isEmpty)
    }

    @Test("los audios añadidos llevan lo elegido, cada uno con su nombre final, antes de copiarse")
    func anadirConEleccion() {
        let registro = Registro()
        registro.nombres = ["Llamada.m4a"]
        let modelo = InboxModel(inbox: registro.bandeja, choices: registro.eleccionesGuardadas, wake: {})
        modelo.choice = ResolverChoice(stt: groq)

        modelo.add([
            URL(fileURLWithPath: "/x/Llamada.m4a"), URL(fileURLWithPath: "/x/acta.pdf"),
            URL(fileURLWithPath: "/x/roto.m4a"),
        ])

        #expect(registro.elecciones == ["/bandeja/Llamada 2.m4a": ResolverChoice(stt: groq)])
        #expect(registro.eventos.first == "elige:Llamada 2.m4a=6A0C/-")
        #expect(modelo.choice == ResolverChoice())
    }
}

@Suite("Elecciones guardadas por grabacion")
struct EleccionesGuardadasTests {
    @Test("se guardan en un fichero, por ruta, y una eleccion vacia o nula se borra")
    func fichero() throws {
        let fichero = FileManager.default.temporaryDirectory.appending(path: "escriba-elecciones-\(UUID().uuidString)/elecciones.json")
        let elecciones = fileChoiceStore(fichero)

        elecciones.write("/bandeja/a.m4a", ResolverChoice(stt: groq))
        elecciones.write("/bandeja/b.m4a", ResolverChoice(llm: openAI))
        #expect(fileChoiceStore(fichero).read("/bandeja/./a.m4a") == ResolverChoice(stt: groq))

        elecciones.write("/bandeja/a.m4a", ResolverChoice())
        elecciones.write("/bandeja/b.m4a", nil)
        #expect(fileChoiceStore(fichero).read("/bandeja/a.m4a") == nil)
        #expect(fileChoiceStore(fichero).read("/bandeja/b.m4a") == nil)
    }

    @Test("lo elegido para una grabacion manda sobre lo de su origen, papel a papel")
    func mandaSobreElOrigen() {
        let elecciones = ChoiceStore.inMemory()
        elecciones.write("/bandeja/a.m4a", ResolverChoice(llm: openAI))
        var stt = ResolverSet(role: .stt)
        stt.add(Resolver(id: groq, name: "Groq", kind: .remote, baseURL: "https://api.groq.com/openai/v1", model: "w"))
        var llm = ResolverSet(role: .llm)
        llm.add(Resolver(id: openAI, name: "OpenAI", kind: .remote, baseURL: "https://api.openai.com/v1", model: "g"))
        let rutas = ResolverRouting(
            stt: stt, llm: llm, folders: [], inbox: "/bandeja", inboxChoice: ResolverChoice(stt: groq), overrides: elecciones)

        #expect(rutas.choice(forSource: "/bandeja/a.m4a") == ResolverChoice(stt: groq, llm: openAI))
        #expect(rutas.resolver(.llm, forSource: "/bandeja/a.m4a").id == openAI)
        #expect(rutas.resolver(.llm, forSource: "/bandeja/b.m4a").kind == .local)
        #expect(rutas.resolver(.stt, forSource: "/bandeja/b.m4a").id == groq)
    }
}
