import Foundation
import Testing
import EscribaCore

@testable import EscribaOKF

private let rutaNota = "notas/2025-09-16-backups-de-cortes.md"
private let rutaTranscripcion = "transcripciones/2025-09-16-backups-de-cortes.md"
private let dia = TimeInterval(86_400)

@Suite("Bundle OKF: indices, registro, regenerar y borrar")
struct BundleTests {
    @Test("la primera publicacion deja un bundle conforme: nota, transcripcion, indices y registro")
    func primera() throws {
        let ficheros = escritos(publicar().changes)

        #expect(Set(ficheros.keys) == [
            rutaNota, rutaTranscripcion, "notas/index.md", "transcripciones/index.md", "index.md", "log.md",
        ])
        #expect(try #require(ficheros["index.md"]) == """
            # Notas de voz

            * [Notas](notas/) - Una nota por grabación, con su resumen y sus datos.
            * [Transcripciones](transcripciones/) - La transcripción completa de cada grabación.

            """)
        #expect(try #require(ficheros["notas/index.md"]) == """
            # Septiembre de 2025

            * [Backups de cortes](2025-09-16-backups-de-cortes.md) - Se revisa el restore.

            """)
        #expect(try #require(ficheros["transcripciones/index.md"]) == """
            # Septiembre de 2025

            * [Transcripción: Backups de cortes](2025-09-16-backups-de-cortes.md) - Transcripción completa de «Backups de cortes».

            """)
        #expect(try #require(ficheros["log.md"]) == """
            # Registro

            ## 2026-10-05

            * **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)

            """)
    }

    @Test("ni los indices ni el registro llevan frontmatter, y las fechas del registro son AAAA-MM-DD")
    func conformidad() throws {
        let ficheros = escritos(publicar().changes)

        for reservado in ["index.md", "notas/index.md", "transcripciones/index.md", "log.md"] {
            #expect(try #require(ficheros[reservado]).hasPrefix("# "))
        }
        let fechas = try #require(ficheros["log.md"]).components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(fechas.allSatisfy { $0.wholeMatch(of: /## \d{4}-\d{2}-\d{2}/) != nil })
        for (ruta, contenido) in ficheros where !ruta.hasSuffix("index.md") && ruta != "log.md" {
            #expect(frontmatter(contenido).contains { $0.hasPrefix("type: ") }, "\(ruta) sin type")
        }
    }

    @Test("regenerar con otro titulo mueve la nota y su transcripcion, y el indice solo lista la nueva")
    func cambioDeTitulo() throws {
        let antes = aplicar(publicar().changes, a: [:])
        let corregida = Note(
            recording: grabacion, transcript: diarizada,
            digest: Digest(title: "Restore de cortes", summary: "Se prueba el restore.", tags: []))

        let publicacion = publicar(corregida, en: antes, conocida: rutaNota)
        let despues = aplicar(publicacion.changes, a: antes)

        #expect(publicacion.notePath == "notas/2025-09-16-restore-de-cortes.md")
        #expect(Set(borrados(publicacion.changes)).isSuperset(of: [rutaNota, rutaTranscripcion]))
        #expect(despues[rutaNota] == nil)
        #expect(despues["transcripciones/2025-09-16-restore-de-cortes.md"] != nil)
        let indice = try #require(despues["notas/index.md"])
        #expect(indice.contains("[Restore de cortes](2025-09-16-restore-de-cortes.md) - Se prueba el restore."))
        #expect(!indice.contains("Backups"))
    }

    @Test("regenerar otro dia anota una actualizacion encima, y el mismo dia no repite la entrada")
    func registro() throws {
        let primero = aplicar(publicar().changes, a: [:])
        let mismoDia = aplicar(publicar(en: primero, conocida: rutaNota).changes, a: primero)
        #expect(mismoDia["log.md"] == primero["log.md"])

        let otroDia = aplicar(publicar(en: mismoDia, conocida: rutaNota, cuando: ahora + dia).changes, a: mismoDia)
        #expect(try #require(otroDia["log.md"]) == """
            # Registro

            ## 2026-10-06

            * **Actualización**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)

            ## 2026-10-05

            * **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)

            """)
    }

    @Test("varias notas el mismo dia van en la misma fecha del registro, la ultima arriba")
    func variasElMismoDia() throws {
        let primera = aplicar(publicar().changes, a: [:])
        let otra = Note(
            recording: Recording(
                url: URL(fileURLWithPath: "/Notas/otra.m4a"), startedAt: grabacion.startedAt + dia, key: "otra"),
            transcript: diarizada, digest: Digest(title: "Plan de octubre", summary: "Plan.", tags: []))
        let ambas = aplicar(publicar(otra, en: primera).changes, a: primera)

        let registro = try #require(ambas["log.md"]).components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(registro == [
            "# Registro", "## 2026-10-05",
            "* **Alta**: [Plan de octubre](/notas/2025-09-17-plan-de-octubre.md)",
            "* **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)",
        ])
        let indice = try #require(ambas["notas/index.md"]).components(separatedBy: "\n").filter { $0.hasPrefix("* ") }
        #expect(indice.first?.contains("plan-de-octubre") == true)
    }

    @Test("el indice agrupa por mes, lo mas reciente arriba, e incluye lo que el usuario dejo en la carpeta")
    func indicePorMeses() throws {
        var ficheros = okfNoteFile(key: "agosto", title: "Arranque", recorded: grabacion.startedAt - 30 * dia)
        ficheros["notas/idea-suelta.md"] = "---\ntype: Idea\ntitle: Idea suelta\n---\n\nAlgo."
        ficheros = aplicar(publicar(en: ficheros).changes, a: ficheros)

        let indice = try #require(ficheros["notas/index.md"])
        #expect(indice == """
            # Septiembre de 2025

            * [Backups de cortes](2025-09-16-backups-de-cortes.md) - Se revisa el restore.

            # Agosto de 2025

            * [Arranque](2025-08-17-arranque.md) - Otra cosa.

            # Otras notas

            * [Idea suelta](idea-suelta.md)

            """)
    }

    @Test("apagar la transcripcion aparte borra su fichero, y sin transcripciones desaparece su indice")
    func apagarAparte() throws {
        let antes = aplicar(publicar().changes, a: [:])

        let publicacion = publicar(como: exportacion(separada: false), en: antes, conocida: rutaNota)
        let despues = aplicar(publicacion.changes, a: antes)

        #expect(despues[rutaTranscripcion] == nil)
        #expect(despues["transcripciones/index.md"] == nil)
        #expect(try #require(despues["index.md"]).contains("[Notas](notas/)"))
        #expect(!(try #require(despues["index.md"])).contains("Transcripciones"))
    }

    @Test("sin rastro en la biblioteca, encuentra la nota de la grabacion por su clave")
    func porClave() {
        let antes = okfNoteFile(key: "llamada", title: "Titulo viejo", recorded: grabacion.startedAt)

        let publicacion = publicar(en: antes, conocida: nil)

        #expect(borrados(publicacion.changes).contains("notas/2025-09-16-titulo-viejo.md"))
    }

    @Test("borrar quita la nota y su transcripcion, anota la baja y rehace los indices")
    func borrar() throws {
        let antes = aplicar(publicar().changes, a: [:])

        let cambios = okfRemoval(of: rutaNota, in: bundleState(from: antes), now: ahora + dia, timeZone: madrid)
        let despues = aplicar(cambios, a: antes)

        #expect(despues[rutaNota] == nil)
        #expect(despues[rutaTranscripcion] == nil)
        #expect(despues["notas/index.md"] == nil)
        #expect(despues["transcripciones/index.md"] == nil)
        let registro = try #require(despues["log.md"])
        #expect(registro.contains("## 2026-10-06\n\n* **Baja**: Backups de cortes (notas/2025-09-16-backups-de-cortes.md)"))
        #expect(registro.contains("## 2026-10-05"))
    }

    @Test("un registro escrito a mano se conserva: cabecera y entradas antiguas intactas")
    func registroAjeno() throws {
        let mio = "# Historial del equipo\n\nNotas libres.\n\n## 2026-01-01\n\n* Empezamos.\n"
        let ficheros = aplicar(publicar(en: ["log.md": mio]).changes, a: ["log.md": mio])

        #expect(try #require(ficheros["log.md"]) == """
            # Historial del equipo

            Notas libres.

            ## 2026-10-05

            * **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)

            ## 2026-01-01

            * Empezamos.

            """)
    }

    @Test("lee de vuelta titulo, descripcion y clave de una nota escrita por Escriba")
    func leer() throws {
        let ficheros = escritos(publicar().changes)

        let entrada = bundleEntry(path: rutaNota, contents: try #require(ficheros[rutaNota]))

        #expect(entrada == BundleEntry(
            path: rutaNota, title: "Backups de cortes", description: "Se revisa el restore.", key: "llamada"))
        #expect(bundleEntry(path: "notas/x.md", contents: "sin frontmatter") ==
            BundleEntry(path: "notas/x.md", title: nil, description: nil, key: nil))
        #expect(bundleEntry(path: "notas/y.md", contents: "---\ntitle: 'Simple'\nescriba_key: abc\n---\n") ==
            BundleEntry(path: "notas/y.md", title: "Simple", description: nil, key: "abc"))
    }

    @Test("el estado del bundle solo mira notas y transcripciones, nunca sus indices")
    func estado() {
        let ficheros = escritos(publicar().changes)

        let estado = bundleState(from: ficheros)

        #expect(estado.notes.map(\.path) == [rutaNota])
        #expect(estado.transcripts.map(\.path) == [rutaTranscripcion])
        #expect(estado.log == ficheros["log.md"])
    }
}
