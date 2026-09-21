#if canImport(FoundationModels)
import Foundation
import Testing
import EscribaCore

@testable import EscribaEngine
@testable import EscribaIntelligence

@Suite("Resumir de verdad con el modelo del sistema", .serialized)
struct EnVivoTests {
    @Test("resume una transcripcion larga de verdad, troceando y reduciendo")
    func resumeUnaLarga() async throws {
        let entorno = ProcessInfo.processInfo.environment
        guard let ruta = entorno["ESCRIBA_RESUMEN_TEXTO"] else { return }
        let texto = try String(contentsOf: URL(fileURLWithPath: ruta), encoding: .utf8)
        let resumidor = AppleIntelligence.summarizer()
        guard resumidor.availability().isReady else { return }

        let trozos = digestChunks(of: texto, maxCharacters: resumidor.capacity)
        print("caracteres: \(texto.count) | trozos: \(trozos.count) | mayor: \(trozos.map(\.count).max() ?? 0)")
        print("instrucciones: \(DigestPrompt.instructions(language: "es").count) caracteres")

        let espia = Summarizer(
            name: resumidor.name, capacity: resumidor.capacity,
            availability: resumidor.availability
        ) { request throws(SummaryError) in
            print("peticion: \(request.prompt.count) caracteres")
            return try await resumidor.run(request)
        }

        let empezado = Date()
        let digest = try await espia.digest(of: texto, language: "es")
        print("resumen en \(Int(Date().timeIntervalSince(empezado)))s: \(digest.title) | \(digest.tags)")
        print(digest.summary)

        #expect(!digest.isEmpty)
    }
}
#endif
