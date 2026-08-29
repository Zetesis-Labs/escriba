import Foundation
import Testing

@testable import JPRCore
@testable import JPRKit

@Suite("Decodificacion del JSON de MacWhisper")
struct MacWhisperDecodeTests {
    private let real = """
        {
          "segments" : [
            {
              "end" : 6500,
              "id" : "A414897B-5C36-4665-832A-3CF4672E4539",
              "start" : 520,
              "text" : "Quiero proponer la idea.",
              "words" : [
                { "end" : 820, "start" : 520, "text" : " Quiero" },
                { "end" : 1100, "start" : 820, "text" : " proponer" }
              ]
            },
            {
              "end" : 16580,
              "id" : "06E0F43C-611B-4590-A3ED-436CBF5ED9BC",
              "start" : 8460,
              "text" : "Entonces ellos definen.",
              "words" : []
            }
          ],
          "text" : "Quiero proponer la idea.\\nEntonces ellos definen."
        }
        """

    @Test("los milisegundos de mw se convierten a segundos")
    func milisegundosASegundos() throws {
        let transcript = try MacWhisperBackend.decode(Data(real.utf8))

        #expect(transcript.segments.count == 2)
        #expect(transcript.segments[0].start == 0.52)
        #expect(transcript.segments[0].end == 6.5)
        #expect(transcript.duration == 16.58)
    }

    @Test("conserva los tiempos por palabra")
    func palabras() throws {
        let transcript = try MacWhisperBackend.decode(Data(real.utf8))

        #expect(transcript.segments[0].words.count == 2)
        #expect(transcript.segments[0].words[0].text == " Quiero")
        #expect(transcript.segments[0].words[0].start == 0.52)
        #expect(transcript.segments[1].words.isEmpty)
    }

    @Test("sin diarizacion los segmentos no tienen hablante")
    func sinHablante() throws {
        let transcript = try MacWhisperBackend.decode(Data(real.utf8))

        #expect(transcript.segments.allSatisfy { $0.speaker == nil })
        #expect(transcript.speakers.isEmpty)
    }

    @Test("si mw anota el hablante, se recoge")
    func conHablante() throws {
        let json = """
            {
              "segments" : [
                { "end" : 1000, "start" : 0, "text" : "hola", "speaker" : "Speaker 1" },
                { "end" : 2000, "start" : 1000, "text" : "que tal", "speaker" : "Speaker 2" }
              ],
              "text" : "hola\\nque tal"
            }
            """

        let transcript = try MacWhisperBackend.decode(Data(json.utf8))

        #expect(transcript.speakers == ["Speaker 1", "Speaker 2"])
    }

    @Test("un audio en silencio devuelve una transcripcion vacia, no un error")
    func audioVacio() throws {
        let transcript = try MacWhisperBackend.decode(Data(#"{"segments":[],"text":""}"#.utf8))

        #expect(transcript.text.isEmpty)
        #expect(transcript.segments.isEmpty)
    }

    @Test("ignora el preambulo que mw imprime antes del JSON")
    func preambulo() throws {
        let salida = "Transcribing 20-23-36.m4a...\n" + real

        let transcript = try MacWhisperBackend.decode(Data(salida.utf8))

        #expect(transcript.segments.count == 2)
    }

    @Test("un JSON que no es el esperado falla como error de transcripcion")
    func jsonInvalido() {
        #expect(throws: TranscriptionError.self) {
            try MacWhisperBackend.decode(Data("no soy json".utf8))
        }
    }
}
