import Foundation
import Testing

@testable import EscribaWhisper

@Suite("Deteccion del modelo en disco")
struct ModelDetectionTests {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "jpr-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeModel(
        at folder: URL, components: [String] = WhisperKitBackend.modelComponents
    ) throws {
        for component in components {
            let dir = folder.appending(path: component)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appending(path: "coremldata.bin"))
        }
    }

    @Test("un modelo completo se encuentra")
    func completo() throws {
        let root = try makeRoot()
        let variant = root.appending(path: "models/argmaxinc/whisperkit-coreml/mi-modelo")
        try writeModel(at: variant)

        #expect(WhisperKitBackend.installedModelFolder(variant: "mi-modelo", modelsRoot: root) != nil)
    }

    @Test("una descarga a medias no se da por buena")
    func incompleto() throws {
        let root = try makeRoot()
        let variant = root.appending(path: "models/argmaxinc/whisperkit-coreml/mi-modelo")
        try writeModel(at: variant, components: ["AudioEncoder.mlmodelc"])

        #expect(WhisperKitBackend.installedModelFolder(variant: "mi-modelo", modelsRoot: root) == nil)
    }

    @Test("un mlmodelc sin pesos tampoco cuenta")
    func sinPesos() throws {
        let root = try makeRoot()
        let variant = root.appending(path: "models/mi-modelo")
        for component in WhisperKitBackend.modelComponents {
            try FileManager.default.createDirectory(
                at: variant.appending(path: component), withIntermediateDirectories: true)
        }

        #expect(WhisperKitBackend.installedModelFolder(variant: "mi-modelo", modelsRoot: root) == nil)
    }

    @Test("la copia de metadatos en .cache no se confunde con el modelo")
    func ignoraCache() throws {
        let root = try makeRoot()
        let cache = root.appending(path: "models/argmaxinc/whisperkit-coreml/.cache/mi-modelo")
        try writeModel(at: cache)

        #expect(WhisperKitBackend.installedModelFolder(variant: "mi-modelo", modelsRoot: root) == nil)
    }
}
