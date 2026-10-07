import Testing

@testable import EscribaCore

@Suite("Criterios de transcripcion")
struct TranscriptionOptionsTests {
    @Test("el numero de hablantes solo cuenta si se diariza")
    func hablantesSinDiarizar() {
        #expect(TranscriptionOptions(diarize: false, speakerCount: 3).speakerCount == nil)
        #expect(TranscriptionOptions(diarize: true, speakerCount: 3).speakerCount == 3)
    }

    @Test("sin criterios propios manda el idioma de los ajustes, no la deteccion automatica")
    func idiomaHablado() {
        #expect(spokenLanguage(nil, fallback: "es") == "es")
        #expect(spokenLanguage(TranscriptionOptions(language: "en"), fallback: "es") == "en")
        #expect(spokenLanguage(TranscriptionOptions(language: nil), fallback: "es") == nil)
    }

    @Test("la etiqueta resume idioma y hablantes de forma legible")
    func etiqueta() {
        #expect(TranscriptionOptions().label == "idioma automático · sin hablantes")
        #expect(TranscriptionOptions(language: "es").label == "ES · sin hablantes")
        #expect(TranscriptionOptions(language: "en", diarize: true).label == "EN · hablantes automáticos")
        #expect(TranscriptionOptions(language: "es", diarize: true, speakerCount: 2).label == "ES · 2 hablantes")
    }

    @Test("dos criterios iguales son el mismo, para no duplicar versiones sin querer")
    func igualdad() {
        #expect(TranscriptionOptions(language: "es", diarize: true, speakerCount: 2)
            == TranscriptionOptions(language: "es", diarize: true, speakerCount: 2))
        #expect(TranscriptionOptions(language: "es") != TranscriptionOptions(language: "en"))
    }

    @Test("lo ya transcrito solo vale si salio del mismo motor con los mismos criterios")
    func mismasEntradas() {
        let entradas = TranscriptionInputs(backend: "whisperkit", options: TranscriptionOptions(language: "es"))

        #expect(entradas.matches(backend: "whisperkit", options: TranscriptionOptions(language: "es")))
        #expect(!entradas.matches(backend: "Groq · whisper-large-v3", options: TranscriptionOptions(language: "es")))
        #expect(!entradas.matches(backend: "whisperkit", options: TranscriptionOptions(language: "en")))
        #expect(!entradas.matches(backend: "whisperkit", options: TranscriptionOptions(language: "es", diarize: true)))
    }

    @Test("una version guardada sin criterios, de antes de guardarlos, no cuenta como hecha")
    func criteriosDesconocidos() {
        let entradas = TranscriptionInputs(backend: "whisperkit", options: .automatic)

        #expect(!entradas.matches(backend: "whisperkit", options: nil))
    }
}
