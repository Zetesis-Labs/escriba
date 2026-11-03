import Foundation
import Testing

@testable import EscribaWhisper

@Suite("Catálogo de modelos de Whisper")
struct ModelCatalogTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "escriba-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func repository(_ root: URL) -> URL {
        root.appending(path: "models/argmaxinc/whisperkit-coreml")
    }

    private func metadata(_ variant: String, in root: URL) -> URL {
        repository(root).appending(path: ".cache/huggingface/download/\(variant)")
    }

    private func install(_ variant: String, in root: URL, bytes: Int = 1) throws {
        for component in WhisperKitBackend.modelComponents {
            let dir = repository(root).appending(path: "\(variant)/\(component)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0, count: bytes).write(to: dir.appending(path: "coremldata.bin"))
        }
        let cache = metadata(variant, in: root)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: cache.appending(path: "config.json.metadata"))
    }

    @Test("el catálogo ofrece el de serie primero y los mismos modelos que Linux")
    func modelos() throws {
        let catalog = WhisperKitBackend.catalog(modelsRoot: try makeRoot())

        #expect(catalog.map(\.label) == ["large-v3-turbo", "tiny", "base", "small", "medium", "large-v3"])
        #expect(catalog.first?.variant == WhisperKitBackend.defaultVariant)
        #expect(catalog.allSatisfy { !$0.installed && $0.bytes > 0 })
    }

    @Test("un modelo instalado da su tamaño real en disco")
    func instalado() throws {
        let root = try makeRoot()
        try install("openai_whisper-tiny", in: root, bytes: 1000)

        let tiny = WhisperKitBackend.catalog(modelsRoot: root).first { $0.variant == "openai_whisper-tiny" }

        #expect(tiny?.installed == true)
        #expect(tiny?.bytes == 3000)
    }

    @Test("borrar un modelo quita su carpeta y sus metadatos y deja los demás")
    func borrar() throws {
        let root = try makeRoot()
        try install("openai_whisper-tiny", in: root)
        try install("openai_whisper-base", in: root)

        #expect(try WhisperKitBackend.deleteModel(variant: "openai_whisper-tiny", modelsRoot: root))

        #expect(WhisperKitBackend.installedModelFolder(variant: "openai_whisper-tiny", modelsRoot: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: metadata("openai_whisper-tiny", in: root).path(percentEncoded: false)))
        #expect(WhisperKitBackend.installedModelFolder(variant: "openai_whisper-base", modelsRoot: root) != nil)
        #expect(FileManager.default.fileExists(atPath: metadata("openai_whisper-base", in: root).path(percentEncoded: false)))
    }

    @Test("borrar un modelo que no está descargado no toca nada")
    func borrarAusente() throws {
        let root = try makeRoot()
        try install("openai_whisper-base", in: root)

        #expect(try WhisperKitBackend.deleteModel(variant: "openai_whisper-tiny", modelsRoot: root) == false)
        #expect(WhisperKitBackend.installedModelFolder(variant: "openai_whisper-base", modelsRoot: root) != nil)
    }
}
