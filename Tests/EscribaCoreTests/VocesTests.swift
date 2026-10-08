import Foundation
import Testing

@testable import EscribaCore

private let modelo = "pyannote-v3"

private func voz(_ hablante: String, _ huella: [Float], modelo: String = modelo) -> SpeakerVoice {
    SpeakerVoice(speaker: hablante, embedding: huella, model: modelo)
}

private func conocida(_ persona: String, _ huella: [Float], modelo: String = modelo) -> KnownVoice {
    KnownVoice(person: persona, embedding: huella, model: modelo)
}

@Suite("Huellas de voz: distancia y reconocimiento")
struct VocesTests {
    @Test("la distancia de coseno va de 0 (misma dirección) a 2 (opuesta) y no compara huellas de otra forma")
    func distancia() throws {
        #expect(cosineDistance([1, 0], [2, 0]) == 0)
        #expect(cosineDistance([1, 0], [0, 3]) == 1)
        #expect(cosineDistance([1, 0], [-1, 0]) == 2)
        #expect(try #require(cosineDistance([1, 1], [1, 0])) - 0.2929 < 0.001)
        #expect(cosineDistance([1, 0], [1, 0, 0]) == nil)
        #expect(cosineDistance([], []) == nil)
        #expect(cosineDistance([0, 0], [1, 0]) == nil)
    }

    @Test("cada hablante se compara con la huella más cercana de cada persona y solo se nombra si queda dentro del umbral")
    func masCercana() {
        let conocidas = [
            conocida("Rubén", [1, 0, 0]), conocida("Rubén", [0, 1, 0]),
            conocida("Nuria", [0, 0, 1]),
        ]

        let reconocidos = recognize(
            [voz("Speaker 1", [0.1, 1, 0]), voz("Speaker 2", [1, 1, 1])], known: conocidas, threshold: 0.3)

        #expect(reconocidos.map(\.speaker) == ["Speaker 1"])
        #expect(reconocidos.map(\.person) == ["Rubén"])
        #expect(reconocidos[0].distance < 0.01)
    }

    @Test("dos hablantes de la misma nota nunca son la misma persona: gana el más cercano y el otro se queda sin nombre")
    func unoAUno() {
        let reconocidos = recognize(
            [voz("Speaker 1", [1, 0.2]), voz("Speaker 2", [1, 0.05])],
            known: [conocida("Rubén", [1, 0])], threshold: 0.3)

        #expect(reconocidos.map { "\($0.speaker) \($0.person)" } == ["Speaker 2 Rubén"])
    }

    @Test("si dos personas quieren al mismo hablante, se reparten por cercanía")
    func reparto() {
        let reconocidos = recognize(
            [voz("Speaker 1", [1, 0.1]), voz("Speaker 2", [0.1, 1])],
            known: [conocida("Rubén", [1, 0]), conocida("Nuria", [0, 1]), conocida("Ana", [1, 0.12])],
            threshold: 0.3)

        #expect(Set(reconocidos.map { "\($0.speaker) \($0.person)" }) == ["Speaker 1 Ana", "Speaker 2 Nuria"])
    }

    @Test("una huella de otro modelo o de otra longitud no se compara")
    func otroModelo() {
        let conocidas = [conocida("Rubén", [1, 0], modelo: "otro"), conocida("Nuria", [1, 0, 0])]

        #expect(recognize([voz("Speaker 1", [1, 0])], known: conocidas, threshold: 0.5).isEmpty)
    }

    @Test("un hablante fusionado lleva varias huellas y vale la más cercana")
    func variasDelHablante() {
        let reconocidos = recognize(
            [voz("Speaker 1", [0, 1]), voz("Speaker 1", [1, 0])], known: [conocida("Rubén", [1, 0.01])],
            threshold: 0.3)

        #expect(reconocidos.map(\.person) == ["Rubén"])
    }

    @Test("de una muestra de voz vale el hablante que más habla, si habla lo bastante")
    func muestra() {
        let voces = [voz("Speaker 1", [1, 0]), voz("Speaker 2", [0, 1])]
        let tramos = [
            SpeakerSpan(speaker: "Speaker 1", start: 0, end: 2),
            SpeakerSpan(speaker: "Speaker 2", start: 2, end: 6),
            SpeakerSpan(speaker: "Speaker 1", start: 6, end: 7),
        ]

        #expect(dominantVoice(voces, spans: tramos, minimumSpeech: 3) == voz("Speaker 2", [0, 1]))
        #expect(dominantVoice(voces, spans: tramos, minimumSpeech: 5) == nil)
        #expect(dominantVoice([], spans: tramos, minimumSpeech: 1) == nil)
    }

    @Test("los tramos de una diarización nueva se cruzan con los hablantes guardados por el que más solapa")
    func cruce() {
        let guardada = Transcript(segments: [
            TranscriptSegment(start: 0, end: 10, speaker: "Rubén", text: "a"),
            TranscriptSegment(start: 10, end: 14, speaker: "Nuria", text: "b"),
            TranscriptSegment(start: 14, end: 20, speaker: "Rubén", text: "c"),
        ])
        let tramos = [
            SpeakerSpan(speaker: "Speaker 2", start: 0, end: 9),
            SpeakerSpan(speaker: "Speaker 1", start: 9, end: 15),
            SpeakerSpan(speaker: "Speaker 2", start: 15, end: 20),
            SpeakerSpan(speaker: "Speaker 3", start: 30, end: 31),
        ]

        #expect(storedSpeakers(of: tramos, in: guardada) == ["Speaker 1": "Nuria", "Speaker 2": "Rubén"])
    }
}

private let conversacion = Transcript(
    segments: [
        TranscriptSegment(start: 0, end: 5, speaker: "Speaker 1", text: "hola"),
        TranscriptSegment(start: 5, end: 9, speaker: "Speaker 2", text: "qué tal"),
    ],
    voices: [voz("Speaker 1", [1, 0]), voz("Speaker 2", [0, 1])])

private let nuria = Recognition(speaker: "Speaker 2", person: "Nuria", distance: 0.2)

@Suite("Las huellas siguen a los hablantes de la transcripción")
struct HuellasDeLaTranscripcionTests {
    @Test("renombrar y fusionar llevan las huellas al nombre nuevo")
    func renombrar() {
        let renombrada = conversacion.renaming("Speaker 1", to: "Rubén")
        let fusionada = renombrada.merging(["Speaker 2"], into: "Rubén")

        #expect(renombrada.voices.map(\.speaker) == ["Rubén", "Speaker 2"])
        #expect(fusionada.voices.map(\.speaker) == ["Rubén", "Rubén"])
        #expect(fusionada.speakers == ["Rubén"])
    }

    @Test("reconocer pone el nombre y lo marca; deshacerlo vuelve a la etiqueta de antes")
    func reconocer() {
        let reconocida = conversacion.recognizing([nuria])

        #expect(reconocida.speakers == ["Speaker 1", "Nuria"])
        #expect(reconocida.recognitions == [nuria])
        #expect(reconocida.voices.map(\.speaker) == ["Speaker 1", "Nuria"])
        #expect(reconocida.forgettingRecognition(of: "Nuria") == conversacion)
        #expect(reconocida.forgettingRecognition(of: "Speaker 1") == reconocida)
    }

    @Test("renombrar o fusionar a quien se reconoció quita la marca: desde ahí lo dice el usuario")
    func corregirReconocido() {
        let reconocida = conversacion.recognizing([nuria])

        #expect(reconocida.renaming("Nuria", to: "Ana").recognitions.isEmpty)
        #expect(reconocida.renaming("Nuria", to: "Ana").speakers == ["Speaker 1", "Ana"])
        #expect(reconocida.merging(["Speaker 1"], into: "Nuria").recognitions.isEmpty)
        #expect(reconocida.renaming("Speaker 1", to: "Rubén").recognitions == [nuria])
    }

    @Test("una transcripción sin hablantes no cambia al reconocer")
    func sinHablantes() {
        let plana = Transcript(text: "hola")

        #expect(plana.recognizing([nuria]) == plana)
    }
}

@Suite("Las huellas no salen del Mac")
struct HuellasPrivadasTests {
    private let huella: [Float] = [0.123456, -0.654321]
    private var nota: Transcript {
        Transcript(
            segments: [TranscriptSegment(start: 0, end: 1, speaker: "Rubén", text: "hola")],
            voices: [voz("Rubén", huella)],
            recognitions: [Recognition(speaker: "Speaker 1", person: "Rubén", distance: 0.1)])
    }

    @Test("ni la receta ni la exportación ven huellas ni distancias")
    func noSalen() throws {
        let receta = String(
            decoding: try JSONEncoder().encode(RecipeNote(key: "a", version: 1, transcript: nota, digest: nil)),
            as: UTF8.self)
        let exportada = transcriptExport(
            key: "a", startedAt: Date(), source: URL(fileURLWithPath: "/a.m4a"), backend: nil, transcript: nota
        ).json()

        for texto in [receta, exportada] {
            #expect(texto.contains("Rubén"))
            #expect(!texto.contains("0.12345"))
            #expect(!texto.contains("embedding"))
            #expect(!texto.contains(modelo))
        }
    }
}

@Suite("Reconocer sin pisar a otros hablantes")
struct ReconocerSinChocarTests {
    @Test("no se reconoce a alguien cuyo nombre ya lleva otro hablante de la nota")
    func nombreOcupado() {
        let nota = Transcript(
            segments: [
                TranscriptSegment(start: 0, end: 5, speaker: "Speaker 1", text: "hola"),
                TranscriptSegment(start: 5, end: 9, speaker: "Nuria", text: "qué tal"),
            ],
            voices: [voz("Speaker 1", [1, 0])])

        #expect(nota.recognizing([Recognition(speaker: "Speaker 1", person: "Nuria", distance: 0.1)]) == nota)
    }
}
