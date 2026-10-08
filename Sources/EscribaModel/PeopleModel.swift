import Foundation
import Observation
import EscribaCore
import EscribaEngine
import EscribaStore

@Observable
public final class PeopleModel {
    public enum Sample: Equatable {
        case idle
        case requesting(person: String)
        case recording(person: String)
        case analyzing(person: String)
        case failed(String)
    }

    public static let minimumSampleSpeech: TimeInterval = 30
    public static let sampleSource = "muestra de voz"

    public private(set) var people: [Person] = []
    public private(set) var sample: Sample = .idle

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let recorder: AudioRecorder
    @ObservationIgnored private let printer: @Sendable (URL) async throws -> VoiceDiarization
    @ObservationIgnored private let samples: URL
    @ObservationIgnored private var file: URL?

    public init(
        store: Store, recorder: AudioRecorder, printer: @escaping @Sendable (URL) async throws -> VoiceDiarization,
        samples: URL = FileManager.default.temporaryDirectory.appending(path: "escriba-muestras-de-voz")
    ) {
        self.store = store
        self.recorder = recorder
        self.printer = printer
        self.samples = samples
        sweep()
    }

    public func reload() throws {
        people = try store.people()
    }

    public func rename(_ name: String, to newName: String) async throws {
        let wanted = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return }
        try await store.renamePerson(name, to: wanted)
        try reload()
    }

    public func removeVoice(_ id: Int64) async throws {
        try await store.removeVoice(id)
        try reload()
    }

    public func remove(_ name: String) async throws {
        try await store.removePerson(name)
        try reload()
    }

    public func startSample(for name: String) async {
        let person = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !person.isEmpty, sample == .idle || isProblem else { return }
        sample = .requesting(person: person)
        let allowed = await recorder.requestPermission()
        guard sample == .requesting(person: person) else { return }
        guard allowed else {
            sample = .failed("Escriba no tiene permiso para usar el micrófono.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
            let url = samples.appending(path: "\(UUID().uuidString).m4a")
            try recorder.start(url)
            file = url
            sample = .recording(person: person)
        } catch {
            sample = .failed("No se pudo empezar a grabar: \(error.localizedDescription)")
        }
    }

    public func stopSample() async {
        guard case .recording(let person) = sample, let file else { return }
        recorder.stop()
        self.file = nil
        sample = .analyzing(person: person)
        defer { discard(file) }
        do {
            let heard = try await printer(file)
            let seconds = speechBySpeaker(heard.spans).values.max() ?? 0
            guard seconds >= Self.minimumSampleSpeech else {
                sample = .failed(
                    "Solo se oyen \(Int(seconds)) s de voz y hacen falta \(Int(Self.minimumSampleSpeech)) s. Habla un rato más.")
                return
            }
            guard let dominant = dominantVoice(heard.voices, spans: heard.spans, minimumSpeech: Self.minimumSampleSpeech)
            else {
                Log.error("la muestra de voz tiene \(Int(seconds)) s de habla pero el motor no dio su huella")
                sample = .failed("El motor no ha dado la huella de esa voz. Prueba otra vez.")
                return
            }
            try await store.addVoices([dominant], to: person, source: Self.sampleSource)
        } catch {
            sample = .failed("No se pudo sacar la huella de la muestra: \(error)")
            return
        }
        sample = .idle
        do {
            try reload()
        } catch {
            Log.error("la huella de \(person) se guardó pero no se pudo releer la lista: \(error)")
        }
    }

    public func cancelSample() {
        switch sample {
        case .requesting:
            sample = .idle
        case .recording:
            recorder.cancel()
            file.map(discard)
            file = nil
            sample = .idle
        case .idle, .analyzing, .failed:
            break
        }
    }

    public func dismissProblem() {
        if isProblem { sample = .idle }
    }

    private var isProblem: Bool {
        if case .failed = sample { return true }
        return false
    }

    private func sweep() {
        guard let stale = try? FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
        else { return }
        stale.forEach(discard)
    }

    private func discard(_ file: URL) {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Log.error("no se pudo borrar la muestra de voz \(file.lastPathComponent): \(error)")
        }
    }
}
