#if canImport(FoundationModels)
import FoundationModels
import Testing

@testable import EscribaEngine
@testable import EscribaIntelligence

@Suite("Apple Intelligence como resumidor")
struct DisponibilidadTests {
    @Test("cada motivo de indisponibilidad se explica en castellano")
    func motivos() {
        #expect(reason(.available) == .ready)
        #expect(reason(.unavailable(.deviceNotEligible)).problem?.contains("no admite") == true)
        #expect(reason(.unavailable(.appleIntelligenceNotEnabled)).problem?.contains("apagado") == true)
        #expect(reason(.unavailable(.modelNotReady)).problem?.contains("descargando") == true)
    }

    @Test("el resumidor declara su nombre y cuanto texto acepta de una vez")
    func capacidad() {
        let resumidor = AppleIntelligence.summarizer()

        #expect(resumidor.name == "Apple Intelligence")
        #expect(resumidor.capacity == 3500)
        #expect(resumidor.availability() == AppleIntelligence.availability())
    }
}
#endif
