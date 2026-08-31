import Testing

@testable import EscribaCore

private let salidaReal = """
  ID                                            NAME                 SIZE  
▸ whisperkit:openai_whisper-large-v3-v20240930  Large v3 Turbo       -     
  parakeet-pro:nvidia_parakeet-v3_494MB         Parakeet v3 (494MB)  494 MB
  whisper-cpp:ggml-model-whisper-large-v3       Large (V3)           3 GB  
"""

@Suite("Lectura de los modelos de MacWhisper")
struct ModelsTests {
    @Test("extrae los identificadores y descarta la cabecera")
    func extraeIdentificadores() {
        let listing = parseModelListing(salidaReal)
        #expect(
            listing.identifiers == [
                "whisperkit:openai_whisper-large-v3-v20240930",
                "parakeet-pro:nvidia_parakeet-v3_494MB",
                "whisper-cpp:ggml-model-whisper-large-v3",
            ])
    }

    @Test("reconoce cual esta seleccionado por el marcador")
    func reconoceSeleccionado() {
        #expect(parseModelListing(salidaReal).selected == "whisperkit:openai_whisper-large-v3-v20240930")
    }

    @Test("una salida sin modelos no inventa ninguno")
    func salidaVacia() {
        #expect(parseModelListing("").isEmpty)
        #expect(parseModelListing("  ID    NAME    SIZE").isEmpty)
    }

    @Test("sin marcador de seleccion no se inventa uno")
    func sinSeleccionado() {
        let listing = parseModelListing("  whisperkit:algo  Nombre  1 GB")
        #expect(listing.identifiers == ["whisperkit:algo"])
        #expect(listing.selected == nil)
    }

    @Test("los nombres con espacios y parentesis no rompen el parseo")
    func nombresConEspacios() {
        let listing = parseModelListing("  parakeet-pro:nvidia_parakeet-v3_494MB  Parakeet v3 (494MB)  494 MB")
        #expect(listing.identifiers == ["parakeet-pro:nvidia_parakeet-v3_494MB"])
    }
}
