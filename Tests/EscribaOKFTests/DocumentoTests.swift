import Foundation
import Testing
import EscribaCore

@testable import EscribaOKF

private let rutaNota = "notas/2025-09-16-backups-de-cortes.md"
private let rutaTranscripcion = "transcripciones/2025-09-16-backups-de-cortes.md"

@Suite("Documento OKF: propiedades y cuerpo")
struct DocumentoTests {
    @Test("la plantilla de partida da una nota con el resumen que enlaza su transcripcion")
    func notaEstandar() throws {
        #expect(try #require(fichero(rutaNota, como: exportacion())) == """
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

            [Transcripción: Backups de cortes](/transcripciones/2025-09-16-backups-de-cortes.md)

            """)
    }

    @Test("y la transcripcion, su propio documento, enlaza de vuelta a la nota")
    func transcripcionEstandar() throws {
        #expect(try #require(fichero(rutaTranscripcion, como: exportacion())) == """
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

    @Test("una propiedad mezcla texto fijo y datos como el usuario quiera")
    func propiedadesLibres() throws {
        let doc = documento(propiedades: [
            ("type", "Acta"), ("cliente", "Acme"), ("asunto", "Llamada de {{hablantes}} el {{dia}}"),
        ])

        let cabecera = frontmatter(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(cabecera.prefix(3) == ["type: Acta", "cliente: \"Acme\"", "asunto: \"Llamada de Ruben, Aritz el 2025-09-16\""])
    }

    @Test("un dato de lista, numero o fecha solo va como YAML de su tipo; mezclado con texto, como cadena")
    func tiposYAML() throws {
        let doc = documento(propiedades: [
            ("type", "Nota"), ("quien", "{{hablantes}}"), ("segundos", "{{segundos}}"),
            ("largo", "{{segundos}} s"), ("cuando", "{{fecha-iso}}"), ("temas", " {{etiquetas}} "),
        ])

        let cabecera = frontmatter(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(cabecera.contains("quien: [\"Ruben\", \"Aritz\"]"))
        #expect(cabecera.contains("segundos: 187"))
        #expect(cabecera.contains("largo: \"187 s\""))
        #expect(cabecera.contains("cuando: 2025-09-16T11:00:00+02:00"))
        #expect(cabecera.contains("temas: [backups, talos-linux]"))
    }

    @Test("una propiedad que se queda sin valor no se escribe, salvo type")
    func propiedadVacia() throws {
        let plana = Note(recording: grabacion, transcript: Transcript(text: "Solo texto"))
        let doc = documento(propiedades: [("type", "Nota"), ("tags", "{{etiquetas}}"), ("resumen", "{{resumen}}"), ("vacia", "")])

        let cabecera = frontmatter(try #require(fichero("docs/2025-09-16-solo-texto.md", de: plana, como: exportacion([doc]))))

        #expect(cabecera.first == "type: Nota")
        #expect(!cabecera.contains { $0.hasPrefix("tags:") || $0.hasPrefix("resumen:") || $0.hasPrefix("vacia:") })
    }

    @Test("sin type, el documento lleva uno generico para seguir siendo OKF")
    func sinType() throws {
        let doc = documento(propiedades: [("title", "{{titulo}}")])

        let cabecera = frontmatter(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(cabecera.first == "type: Documento")
    }

    @Test("escriba_key y generated los pone Escriba: si el usuario los define, se ignoran")
    func reservadas() throws {
        let doc = documento(propiedades: [("type", "Nota"), ("escriba_key", "otra"), ("generated", "yo")])

        let cabecera = frontmatter(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(cabecera.filter { $0.hasPrefix("escriba_key:") } == ["escriba_key: \"llamada\""])
        #expect(cabecera.filter { $0.hasPrefix("generated:") }.count == 1)
        #expect(!cabecera.contains("generated: \"yo\""))
    }

    @Test("una clave con espacios o dos puntos va entre comillas; una clave vacia no se escribe")
    func claves() throws {
        let doc = documento(propiedades: [("type", "Nota"), ("mi clave: rara", "x"), ("  ", "y")])

        let cabecera = frontmatter(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(cabecera.contains("\"mi clave: rara\": \"x\""))
        #expect(!cabecera.contains { $0.contains("\"y\"") })
    }

    @Test("el texto libre del cuerpo se respeta tal cual, Markdown incluido")
    func cuerpoLibre() throws {
        let doc = documento(cuerpo: "**Ojo:** revisar\n\n- uno\n- dos\n\n> cita")

        let texto = try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc])))

        #expect(cuerpo(texto) == "**Ojo:** revisar\n\n- uno\n- dos\n\n> cita")
    }

    @Test("los datos dentro de una frase se sustituyen en su sitio")
    func enLinea() throws {
        let doc = documento(cuerpo: "Participan {{hablantes}} ({{duracion}}), el {{fecha}}.\n\n{{audio}}")

        let texto = cuerpo(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(texto == "Participan Ruben, Aritz (03:07), el 16 de septiembre de 2025, 11:00.\n\n[Audio](file:///Notas/llamada.m4a)")
    }

    @Test("la transcripcion sale en el estilo de su dato")
    func estilos() throws {
        let doc = documento(cuerpo: "{{transcripcion-tiempos}}\n\n---\n\n{{transcripcion-texto}}")

        let texto = cuerpo(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(texto == "**[00:00] Ruben:** Hola.\n\n**[00:12] Aritz:** Dime.\n\n---\n\nHola.\n\nDime.")
    }

    @Test("una linea que solo tenia datos vacios desaparece, y el encabezado que se queda sin nada tambien")
    func huecos() throws {
        let plana = Note(recording: grabacion, transcript: Transcript(text: "Solo texto"))
        let doc = documento(cuerpo: "# Resumen\n\n{{resumen}}\n\n{{etiquetas}}\n\n# Texto\n\n{{transcripcion}}\n\n#\n")

        let texto = cuerpo(try #require(fichero("docs/2025-09-16-solo-texto.md", de: plana, como: exportacion([doc]))))

        #expect(texto == "# Texto\n\nSolo texto")
    }

    @Test("un enlace lleva el titulo del documento enlazado; en una propiedad, su ruta")
    func enlaces() throws {
        let a = documento("A", id: "a", ruta: "a/{{titulo}}.md", propiedades: [("type", "A"), ("ver", "{{enlace:b}}")], cuerpo: "Ver {{enlace:b}}")
        let b = documento("B", id: "b", ruta: "b/{{titulo}}.md", propiedades: [("type", "B"), ("title", "Otra cosa: {{titulo}}")])

        let texto = try #require(fichero("a/backups-de-cortes.md", como: exportacion([a, b])))

        #expect(frontmatter(texto).contains("ver: \"/b/backups-de-cortes.md\""))
        #expect(cuerpo(texto) == "Ver [Otra cosa: Backups de cortes](/b/backups-de-cortes.md)")
    }

    @Test("un enlace a un documento que ya no existe no deja rastro")
    func enlaceRoto() throws {
        let doc = documento(cuerpo: "Arriba\n\n{{enlace:borrado}}\n\nAbajo")

        let texto = cuerpo(try #require(fichero("docs/2025-09-16-backups-de-cortes.md", como: exportacion([doc]))))

        #expect(texto == "Arriba\n\nAbajo")
    }

    @Test("sin resumen, la descripcion sale de la fecha")
    func descripcionSinResumen() throws {
        let plana = Note(recording: grabacion, transcript: Transcript(text: "Solo texto"))
        let doc = documento(propiedades: [("type", "Nota"), ("description", "{{descripcion}}")])

        let cabecera = frontmatter(try #require(fichero("docs/2025-09-16-solo-texto.md", de: plana, como: exportacion([doc]))))

        #expect(cabecera.contains("description: \"Grabación del 16 de septiembre de 2025, 11:00.\""))
    }

    @Test("la descripcion es la primera frase del resumen, recortada si es muy larga")
    func descripcion() {
        #expect(noteDescription(summary: "Primera. Segunda.") == "Primera.")
        #expect(noteDescription(summary: "¿Pregunta? Respuesta.") == "¿Pregunta?")
        #expect(noteDescription(summary: "Una linea\nOtra linea") == "Una linea")
        #expect(noteDescription(summary: "  ") == nil)
        let recortada = noteDescription(summary: String(repeating: "palabra ", count: 60))
        #expect(recortada?.hasSuffix("…") == true)
        #expect((recortada?.count ?? 0) <= noteDescriptionLimit + 1)
    }

    @Test("las comillas, barras y saltos de linea no rompen el YAML")
    func escapado() throws {
        let rara = Digest(title: "Dijo \"vale\" \\ y\nsiguió", summary: "Algo.", tags: [])
        let doc = documento(ruta: "docs/x.md", propiedades: [("type", "Nota"), ("title", "{{titulo}}")])

        let texto = try #require(fichero("docs/x.md", de: Note(recording: grabacion, transcript: diarizada, digest: rara), como: exportacion([doc])))

        #expect(frontmatter(texto).contains(#"title: "Dijo \"vale\" \\ y siguió""#))
    }

    @Test("las etiquetas del frontmatter salen en minusculas y con guiones, sin tildes")
    func etiquetas() {
        #expect(okfTags(["talos linux", "Gestión", "backups", ""]) == ["talos-linux", "gestion", "backups"])
        #expect(okfTags(["a  b", "a b"]) == ["a-b"])
    }
}

@Suite("Ruta de cada documento")
struct RutaTests {
    @Test("la ruta toma el dia en la zona del usuario y el titulo sin tildes ni signos")
    func ruta() throws {
        let casiMedianoche = Recording(
            url: grabacion.url, startedAt: Date(timeIntervalSince1970: 1_758_065_400), key: "llamada")
        let rara = Note(
            recording: casiMedianoche, transcript: diarizada,
            digest: Digest(title: "¿Qué tal, Iñaki? (parte 2)", summary: "", tags: []))

        #expect(publicar(rara, como: exportacion([documento()])).paths == ["docs/2025-09-17-que-tal-inaki-parte-2.md"])
    }

    @Test("sin .md se le añade, y nunca se sale de la carpeta del bundle")
    func saneada() {
        #expect(publicar(como: exportacion([documento(ruta: "{{titulo}}")])).paths == ["backups-de-cortes.md"])
        #expect(publicar(como: exportacion([documento(ruta: "/../x//{{clave}}")])).paths == ["x/llamada.md"])
        #expect(publicar(como: exportacion([documento(ruta: "")])).paths == ["nota.md"])
    }

    @Test("un titulo sin letras ni numeros da un nombre generico, y uno muy largo se corta por palabra")
    func slugs() {
        #expect(slug("¿?¡!…") == "nota")
        let corto = slug(String(repeating: "transcripcion ", count: 20))
        #expect(corto.count <= okfSlugLimit)
        #expect(corto.split(separator: "-").allSatisfy { $0 == "transcripcion" })
    }

    @Test("si otra grabacion o el usuario ya ocupan el nombre, la nueva lleva sufijo")
    func colision() {
        let otra = Note(
            recording: Recording(url: URL(fileURLWithPath: "/Notas/otra.m4a"), startedAt: grabacion.startedAt, key: "otra"),
            transcript: diarizada, digest: resumen)
        let ocupado = aplicar(publicar(otra).changes, a: [:])

        #expect(publicar(en: ocupado).paths.first == "notas/2025-09-16-backups-de-cortes-2.md")
        #expect(publicar(en: ["notas/2025-09-16-backups-de-cortes.md": "---\ntype: Idea\n---\n"]).paths.first
            == "notas/2025-09-16-backups-de-cortes-2.md")
    }

    @Test("la misma grabacion conserva sus nombres al regenerarse")
    func misma() {
        let primera = publicar()
        let ficheros = aplicar(primera.changes, a: [:])

        #expect(publicar(en: ficheros).paths == primera.paths)
    }

    @Test("dos documentos de la misma nota que caen en la misma ruta no se pisan")
    func mismaRuta() {
        let a = documento("A", id: "a", ruta: "x/{{titulo}}.md")
        let b = documento("B", id: "b", ruta: "x/{{titulo}}.md")

        #expect(publicar(como: exportacion([a, b])).paths == ["x/backups-de-cortes.md", "x/backups-de-cortes-2.md"])
    }
}
