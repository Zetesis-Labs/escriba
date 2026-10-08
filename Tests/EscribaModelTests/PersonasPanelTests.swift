import Foundation
import Synchronization
import Testing

@testable import EscribaModel
@testable import EscribaCore
import EscribaEngine
@testable import EscribaStore

nonisolated private let modelo = "pyannote-v3"

@MainActor
private final class Microfono {
    var eventos: [String] = []
    var permiso = true
    var antesDeResponder: () async -> Void = {}

    var port: AudioRecorder {
        AudioRecorder(
            requestPermission: {
                await self.antesDeResponder()
                return self.permiso
            },
            start: { url in
                try Data("audio".utf8).write(to: url)
                self.eventos.append("empieza")
            },
            stop: { self.eventos.append("para") },
            cancel: { self.eventos.append("cancela") },
            decibels: { -30 },
            elapsed: { 0 })
    }
}

@MainActor
private struct Sandbox {
    let base: URL
    let store: Store
    let microfono = Microfono()
    let muestras: URL

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "escriba-personas-panel-\(UUID().uuidString)")
        muestras = base.appending(path: "muestras")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = try Store(root: base.appending(path: "library"))
    }

    func personas(
        oye habla: TimeInterval, huellas: Bool = true, falla: Bool = false, analizadas: Analizadas = Analizadas()
    ) -> PeopleModel {
        PeopleModel(
            store: store, recorder: microfono.port,
            printer: { audio in
                analizadas.urls.withLock { $0.append(audio) }
                if falla { throw CocoaError(.fileReadCorruptFile) }
                return VoiceDiarization(
                    voices: huellas ? [SpeakerVoice(speaker: "Speaker 1", embedding: [1, 0], model: modelo)] : [],
                    spans: [SpeakerSpan(speaker: "Speaker 1", start: 0, end: habla)])
            },
            samples: muestras)
    }
}

private final class Analizadas: Sendable {
    let urls = Mutex<[URL]>([])
}

@MainActor
@Suite("Sección Personas")
struct PersonasPanelTests {
    @Test("registrar la voz de alguien graba una muestra aparte, saca su huella, la guarda con su nombre y borra el audio")
    func registrar() async throws {
        let sandbox = try Sandbox()
        let analizadas = Analizadas()
        let personas = sandbox.personas(oye: 45, analizadas: analizadas)

        await personas.startSample(for: "Rubén")
        #expect(personas.sample == .recording(person: "Rubén"))
        await personas.stopSample()

        #expect(sandbox.microfono.eventos == ["empieza", "para"])
        #expect(personas.sample == .idle)
        #expect(personas.people.map(\.name) == ["Rubén"])
        #expect(personas.people.first?.voices.map(\.source) == ["muestra de voz"])
        let audio = try #require(analizadas.urls.withLock { $0.first })
        #expect(audio.path.hasPrefix(sandbox.muestras.path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("si en la muestra se habla menos de lo necesario, no guarda nada y pide hablar más")
    func corta() async throws {
        let sandbox = try Sandbox()
        let personas = sandbox.personas(oye: 12)

        await personas.startSample(for: "Rubén")
        await personas.stopSample()

        #expect(personas.sample == .failed(
            "Solo se oyen 12 s de voz y hacen falta \(Int(PeopleModel.minimumSampleSpeech)) s. Habla un rato más."))
        #expect(personas.people.isEmpty)
    }

    @Test("sin nombre o sin permiso del micrófono no se graba")
    func noEmpieza() async throws {
        let sandbox = try Sandbox()
        let personas = sandbox.personas(oye: 45)

        await personas.startSample(for: "  ")
        #expect(personas.sample == .idle)
        sandbox.microfono.permiso = false
        await personas.startSample(for: "Rubén")

        #expect(sandbox.microfono.eventos.isEmpty)
        #expect(personas.sample == .failed("Escriba no tiene permiso para usar el micrófono."))
    }

    @Test("si sacar la huella falla, lo dice, no guarda nada y borra el audio igual")
    func fallaLaHuella() async throws {
        let sandbox = try Sandbox()
        let analizadas = Analizadas()
        let personas = sandbox.personas(oye: 45, falla: true, analizadas: analizadas)

        await personas.startSample(for: "Rubén")
        await personas.stopSample()

        guard case .failed = personas.sample else {
            Issue.record("debería fallar: \(personas.sample)")
            return
        }
        #expect(personas.people.isEmpty)
        let audio = try #require(analizadas.urls.withLock { $0.first })
        #expect(!FileManager.default.fileExists(atPath: audio.path))
    }

    @Test("si se oye voz de sobra pero el motor no da su huella, no lo achaca a hablar poco")
    func sinHuella() async throws {
        let sandbox = try Sandbox()
        let personas = sandbox.personas(oye: 45, huellas: false)

        await personas.startSample(for: "Rubén")
        await personas.stopSample()

        #expect(personas.sample == .failed("El motor no ha dado la huella de esa voz. Prueba otra vez."))
    }

    @Test("mientras se pide permiso al micrófono no se puede empezar otra muestra, y cancelar ahí no deja el micro abierto")
    func pidiendoPermiso() async throws {
        let sandbox = try Sandbox()
        let personas = sandbox.personas(oye: 45)
        sandbox.microfono.antesDeResponder = {
            #expect(personas.sample == .requesting(person: "Rubén"))
            await personas.startSample(for: "Otra")
            personas.cancelSample()
        }

        await personas.startSample(for: "Rubén")

        #expect(sandbox.microfono.eventos.isEmpty)
        #expect(personas.sample == .idle)
    }

    @Test("al arrancar se borran las muestras que quedaron de una vez que la app se cerró a medias")
    func huerfanas() async throws {
        let sandbox = try Sandbox()
        try FileManager.default.createDirectory(at: sandbox.muestras, withIntermediateDirectories: true)
        let vieja = sandbox.muestras.appending(path: "vieja.m4a")
        try Data("audio".utf8).write(to: vieja)

        _ = sandbox.personas(oye: 45)

        #expect(!FileManager.default.fileExists(atPath: vieja.path))
    }

    @Test("descartar la muestra no guarda nada")
    func descartar() async throws {
        let sandbox = try Sandbox()
        let personas = sandbox.personas(oye: 45)

        await personas.startSample(for: "Rubén")
        personas.cancelSample()

        #expect(sandbox.microfono.eventos == ["empieza", "cancela"])
        #expect(personas.sample == .idle)
        #expect(personas.people.isEmpty)
    }

    @Test("desde la lista se renombra, se fusiona, se quita una huella y se borra a alguien")
    func lista() async throws {
        let sandbox = try Sandbox()
        let personas = sandbox.personas(oye: 45)
        let voz = SpeakerVoice(speaker: "x", embedding: [1, 0], model: modelo)
        try await sandbox.store.addVoices([voz, voz], to: "Ruben", source: "a")
        try await sandbox.store.addVoices([voz], to: "Rubén", source: "b")
        try await sandbox.store.addVoices([voz], to: "Ana", source: "c")
        try personas.reload()

        try await personas.rename("Ruben", to: "Rubén")
        try await personas.removeVoice(try #require(personas.people.last?.voices.first?.id))
        try await personas.remove("Ana")

        #expect(personas.people.map(\.name) == ["Rubén"])
        #expect(personas.people.first?.voices.map(\.source) == ["a", "b"])
    }
}
