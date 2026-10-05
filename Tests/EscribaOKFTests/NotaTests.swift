import Foundation
import Testing
import EscribaCore

@testable import EscribaOKF

@Suite("Nota OKF de una grabacion")
struct NotaTests {
    @Test("con la plantilla basica y la transcripcion aparte, la nota lleva el resumen y enlaza la transcripcion")
    func notaCompleta() throws {
        let ficheros = escritos(publicar().changes)

        let nota = try #require(ficheros["notas/2025-09-16-backups-de-cortes.md"])
        #expect(nota == """
            ---
            type: Nota de voz
            title: "Backups de cortes"
            description: "Se revisa el restore."
            tags: [backups, talos-linux]
            recorded_at: 2025-09-16T11:00:00+02:00
            duration: 187
            speakers: ["Ruben", "Aritz"]
            escriba_key: "llamada"
            generated: { by: "escriba/1.0", at: 2026-10-05T17:00:00Z }
            ---

            # Resumen

            Se revisa el restore. Luego se habla de MinIO.

            # Transcripción

            [Transcripción completa](/transcripciones/2025-09-16-backups-de-cortes.md)

            """)
    }

    @Test("la transcripcion aparte es su propio concepto y enlaza de vuelta a la nota")
    func transcripcionAparte() throws {
        let ficheros = escritos(publicar().changes)

        let transcripcion = try #require(ficheros["transcripciones/2025-09-16-backups-de-cortes.md"])
        #expect(transcripcion == """
            ---
            type: Transcripción
            title: "Transcripción: Backups de cortes"
            description: "Transcripción completa de «Backups de cortes»."
            recorded_at: 2025-09-16T11:00:00+02:00
            duration: 187
            speakers: ["Ruben", "Aritz"]
            escriba_key: "llamada"
            generated: { by: "escriba/1.0", at: 2026-10-05T17:00:00Z }
            ---

            De la nota [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md).

            **Ruben:** Hola.

            **Aritz:** Dime.

            """)
    }

    @Test("todo junto: la transcripcion va dentro de la nota y no hay carpeta de transcripciones")
    func todoJunto() throws {
        let ficheros = escritos(publicar(como: exportacion(separada: false)).changes)

        let nota = try #require(ficheros["notas/2025-09-16-backups-de-cortes.md"])
        #expect(cuerpo(nota).hasSuffix("# Transcripción\n\n**Ruben:** Hola.\n\n**Aritz:** Dime."))
        #expect(!ficheros.keys.contains { $0.hasPrefix("transcripciones/") })
    }

    @Test("sin /transcripcion en la plantilla sale solo el resumen, aunque el interruptor este encendido")
    func soloResumen() throws {
        let plantilla = BodyTemplate([.summary])
        let ficheros = escritos(publicar(como: exportacion(plantilla, separada: true)).changes)

        let nota = try #require(ficheros["notas/2025-09-16-backups-de-cortes.md"])
        #expect(cuerpo(nota) == "Se revisa el restore. Luego se habla de MinIO.")
        #expect(!ficheros.keys.contains { $0.hasPrefix("transcripciones/") })
    }

    @Test("los bloques salen en el orden de la plantilla, cada uno con su forma en Markdown")
    func bloques() throws {
        let plantilla = BodyTemplate([
            .heading("Datos"), .field(.date), .field(.speakers), .field(.duration), .field(.tags),
            .text("Notas:\nrevisar"), .audio, .transcript(.timestamps),
        ])
        let ficheros = escritos(publicar(como: exportacion(plantilla, separada: false)).changes)

        let nota = try #require(ficheros["notas/2025-09-16-backups-de-cortes.md"])
        let partes = cuerpo(nota).components(separatedBy: "\n\n")
        #expect(partes[0] == "# Datos")
        #expect(partes[1].hasPrefix("**Fecha de la grabación:** "))
        #expect(partes[1].contains("2025"))
        #expect(partes[2] == "**Hablantes:** Ruben, Aritz")
        #expect(partes[3] == "**Duración (segundos):** 03:07")
        #expect(partes[4] == "**Etiquetas:** backups, talos linux")
        #expect(partes[5] == "Notas:\nrevisar")
        #expect(partes[6] == "[Audio](file:///Notas/llamada.m4a)")
        #expect(partes[7] == "**[00:00] Ruben:** Hola.")
        #expect(partes[8] == "**[00:12] Aritz:** Dime.")
    }

    @Test("un dato vacio, un texto vacio o un resumen ausente no dejan huecos")
    func huecos() throws {
        let plana = Note(recording: grabacion, transcript: Transcript(text: "Solo texto"))
        let plantilla = BodyTemplate([.summary, .field(.speakers), .text(""), .field(.tags), .transcript(.speakers)])
        let ficheros = escritos(publicar(plana, como: exportacion(plantilla, separada: false)).changes)

        let nota = try #require(ficheros.first { $0.key.hasPrefix("notas/2025") }?.value)
        #expect(cuerpo(nota) == "Solo texto")
    }

    @Test("un encabezado sin texto no se escribe")
    func encabezadoSinTexto() throws {
        let ficheros = escritos(publicar(como: exportacion(BodyTemplate([.heading(" "), .summary]))).changes)

        let nota = try #require(ficheros["notas/2025-09-16-backups-de-cortes.md"])
        #expect(cuerpo(nota) == "Se revisa el restore. Luego se habla de MinIO.")
    }

    @Test("un encabezado que se queda sin nada debajo no se escribe")
    func encabezadoVacio() throws {
        let plana = Note(recording: grabacion, transcript: Transcript(text: "Solo texto"))
        let ficheros = escritos(publicar(plana, como: exportacion(separada: false)).changes)

        let nota = try #require(ficheros.first { $0.key.hasPrefix("notas/2025") }?.value)
        #expect(cuerpo(nota) == "# Transcripción\n\nSolo texto")
    }

    @Test("sin resumen el titulo sale del texto, la descripcion de la fecha y no hay etiquetas")
    func sinResumen() throws {
        let plana = Note(recording: grabacion, transcript: Transcript(text: "Llamo para hablar del envio de mañana"))
        let ficheros = escritos(publicar(plana).changes)

        let ruta = "notas/2025-09-16-llamo-para-hablar-del-envio-de-manana.md"
        let cabecera = frontmatter(try #require(ficheros[ruta]))
        #expect(cabecera.contains("title: \"Llamo para hablar del envio de mañana\""))
        #expect(cabecera.contains { $0.hasPrefix("description: \"Grabación del ") && $0.contains("2025") })
        #expect(!cabecera.contains { $0.hasPrefix("tags:") })
        #expect(!cabecera.contains { $0.hasPrefix("speakers:") })
    }

    @Test("la descripcion es la primera frase del resumen, recortada si es muy larga")
    func descripcion() {
        #expect(okfDescription(summary: "Primera. Segunda.") == "Primera.")
        #expect(okfDescription(summary: "¿Pregunta? Respuesta.") == "¿Pregunta?")
        #expect(okfDescription(summary: "Una linea\nOtra linea") == "Una linea")
        #expect(okfDescription(summary: "  ") == nil)
        let larga = String(repeating: "palabra ", count: 60)
        let recortada = okfDescription(summary: larga)
        #expect(recortada?.hasSuffix("…") == true)
        #expect((recortada?.count ?? 0) <= okfDescriptionLimit + 1)
    }

    @Test("las comillas, barras y saltos de linea del titulo no rompen el YAML")
    func escapado() throws {
        let rara = Digest(title: "Dijo \"vale\" \\ y\nsiguió", summary: "Algo.", tags: [])
        let ficheros = escritos(publicar(Note(recording: grabacion, transcript: diarizada, digest: rara)).changes)

        let nota = try #require(ficheros.first { $0.key.hasPrefix("notas/2025") }?.value)
        #expect(frontmatter(nota).contains(#"title: "Dijo \"vale\" \\ y siguió""#))
    }

    @Test("las etiquetas salen en minusculas y con guiones, sin tildes")
    func etiquetas() {
        #expect(okfTags(["talos linux", "Gestión", "backups", ""]) == ["talos-linux", "gestion", "backups"])
        #expect(okfTags(["a  b", "a b"]) == ["a-b"])
    }
}
