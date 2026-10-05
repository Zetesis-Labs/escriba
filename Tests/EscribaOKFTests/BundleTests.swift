import Foundation
import Testing
import EscribaCore

@testable import EscribaOKF

private let rutaNota = "notas/2025-09-16-backups-de-cortes.md"
private let rutaTranscripcion = "transcripciones/2025-09-16-backups-de-cortes.md"
private let dia = TimeInterval(86_400)

private func otraNota(_ clave: String, _ titulo: String, _ cuando: Date) -> Note {
    Note(
        recording: Recording(url: URL(fileURLWithPath: "/Notas/\(clave).m4a"), startedAt: cuando, key: clave),
        transcript: diarizada,
        digest: Digest(title: titulo, summary: "Otra cosa.", tags: []))
}

@Suite("Bundle OKF: indices, registro, regenerar y borrar")
struct BundleTests {
    @Test("la primera publicacion deja un bundle conforme: documentos, indices y registro")
    func primera() throws {
        let ficheros = escritos(publicar().changes)

        #expect(Set(ficheros.keys) == [
            rutaNota, rutaTranscripcion, "notas/index.md", "transcripciones/index.md", "index.md", "log.md",
        ])
        #expect(try #require(ficheros["index.md"]) == """
            # Notas de voz

            * [notas](notas/) - Nota
            * [transcripciones](transcripciones/) - Transcripción

            """)
        #expect(try #require(ficheros["notas/index.md"]) == """
            # Septiembre de 2025

            * [Backups de cortes](2025-09-16-backups-de-cortes.md) - Se revisa el restore.

            """)
        #expect(try #require(ficheros["log.md"]) == """
            # Registro

            ## 2026-10-05

            * **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)

            """)
    }

    @Test("ni los indices ni el registro llevan frontmatter, las fechas son AAAA-MM-DD y todo concepto tiene type")
    func conformidad() throws {
        let ficheros = escritos(publicar().changes)

        for (ruta, contenido) in ficheros {
            if ruta.hasSuffix("index.md") || ruta == "log.md" {
                #expect(contenido.hasPrefix("# "), "\(ruta) no empieza por un encabezado")
            } else {
                #expect(frontmatter(contenido).first?.hasPrefix("type: ") == true, "\(ruta) sin type")
            }
        }
        let fechas = try #require(ficheros["log.md"]).components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(fechas.allSatisfy { $0.wholeMatch(of: /## \d{4}-\d{2}-\d{2}/) != nil })
    }

    @Test("regenerar con otro titulo mueve todos los documentos de la nota y los indices solo listan los nuevos")
    func cambioDeTitulo() throws {
        let antes = aplicar(publicar().changes, a: [:])
        let corregida = Note(
            recording: grabacion, transcript: diarizada,
            digest: Digest(title: "Restore de cortes", summary: "Se prueba el restore.", tags: []))

        let publicacion = publicar(corregida, en: antes)
        let despues = aplicar(publicacion.changes, a: antes)

        #expect(publicacion.paths == ["notas/2025-09-16-restore-de-cortes.md", "transcripciones/2025-09-16-restore-de-cortes.md"])
        #expect(Set(borrados(publicacion.changes)).isSuperset(of: [rutaNota, rutaTranscripcion]))
        let indice = try #require(despues["notas/index.md"])
        #expect(indice.contains("[Restore de cortes](2025-09-16-restore-de-cortes.md) - Se prueba el restore."))
        #expect(!indice.contains("Backups"))
    }

    @Test("quitar un documento del conector borra sus ficheros al regenerar, y su carpeta deja de tener indice")
    func documentoQuitado() throws {
        let antes = aplicar(publicar().changes, a: [:])
        let soloNota = exportacion([estandar[0]])

        let despues = aplicar(publicar(como: soloNota, en: antes).changes, a: antes)

        #expect(despues[rutaTranscripcion] == nil)
        #expect(despues["transcripciones/index.md"] == nil)
        #expect(!(try #require(despues["index.md"])).contains("transcripciones"))
    }

    @Test("regenerar otro dia anota una actualizacion encima, y el mismo dia no repite la entrada")
    func registro() throws {
        let primero = aplicar(publicar().changes, a: [:])
        let mismoDia = aplicar(publicar(en: primero).changes, a: primero)
        #expect(mismoDia["log.md"] == primero["log.md"])

        let otroDia = aplicar(publicar(en: mismoDia, cuando: ahora + dia).changes, a: mismoDia)
        #expect(try #require(otroDia["log.md"]) == """
            # Registro

            ## 2026-10-06

            * **Actualización**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)

            ## 2026-10-05

            * **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)

            """)
    }

    @Test("varias notas el mismo dia van bajo la misma fecha del registro, la ultima arriba")
    func variasElMismoDia() throws {
        let primera = aplicar(publicar().changes, a: [:])
        let ambas = aplicar(
            publicar(otraNota("otra", "Plan de octubre", grabacion.startedAt + dia), en: primera).changes, a: primera)

        let registro = try #require(ambas["log.md"]).components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(registro == [
            "# Registro", "## 2026-10-05",
            "* **Alta**: [Plan de octubre](/notas/2025-09-17-plan-de-octubre.md)",
            "* **Alta**: [Backups de cortes](/notas/2025-09-16-backups-de-cortes.md)",
        ])
    }

    @Test("el indice agrupa por mes, lo mas reciente arriba, e incluye lo que el usuario dejo en la carpeta")
    func indicePorMeses() throws {
        var ficheros = aplicar(publicar(otraNota("agosto", "Arranque", grabacion.startedAt - 30 * dia)).changes, a: [:])
        ficheros["notas/idea-suelta.md"] = "---\ntype: Idea\ntitle: Idea suelta\n---\n\nAlgo."
        ficheros = aplicar(publicar(en: ficheros).changes, a: ficheros)

        #expect(try #require(ficheros["notas/index.md"]) == """
            # Septiembre de 2025

            * [Backups de cortes](2025-09-16-backups-de-cortes.md) - Se revisa el restore.

            # Agosto de 2025

            * [Arranque](2025-08-17-arranque.md) - Otra cosa.

            # Otras

            * [Idea suelta](idea-suelta.md)

            """)
    }

    @Test("una carpeta solo con ficheros del usuario no recibe indice de Escriba")
    func carpetaAjena() {
        let suyos = ["apuntes/mio.md": "---\ntype: Idea\n---\n"]

        let cambios = publicar(en: suyos).changes

        #expect(!cambios.contains { if case .write(let ruta, _) = $0 { ruta.hasPrefix("apuntes/") } else { false } })
        #expect(!borrados(cambios).contains { $0.hasPrefix("apuntes/") })
    }

    @Test("las rutas con subcarpetas tienen su indice donde estan los ficheros")
    func subcarpetas() throws {
        let doc = documento(ruta: "notas/{{dia}}/{{titulo}}.md", propiedades: [("type", "Nota"), ("title", "{{titulo}}")])

        let ficheros = escritos(publicar(como: exportacion([doc])).changes)

        #expect(ficheros["notas/2025-09-16/index.md"]?.contains("[Backups de cortes](backups-de-cortes.md)") == true)
        #expect(ficheros["index.md"]?.contains("* [notas/2025-09-16](notas/2025-09-16/)") == true)
    }

    @Test("borrar quita todos los documentos de la nota, anota la baja y rehace los indices")
    func borrar() throws {
        let antes = aplicar(publicar().changes, a: [:])

        let cambios = okfRemoval(of: rutaNota, in: bundleState(from: antes), now: ahora + dia, timeZone: madrid)
        let despues = aplicar(cambios, a: antes)

        #expect(despues[rutaNota] == nil)
        #expect(despues[rutaTranscripcion] == nil)
        #expect(despues["notas/index.md"] == nil)
        #expect(despues["index.md"] == nil)
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

    @Test("lee de vuelta titulo, descripcion y clave de un documento")
    func leer() throws {
        let ficheros = escritos(publicar().changes)

        #expect(bundleEntry(path: rutaNota, contents: try #require(ficheros[rutaNota])) == BundleEntry(
            path: rutaNota, title: "Backups de cortes", description: "Se revisa el restore.", key: "llamada"))
        #expect(bundleEntry(path: "x.md", contents: "sin frontmatter") ==
            BundleEntry(path: "x.md", title: nil, description: nil, key: nil))
        #expect(bundleEntry(path: "y.md", contents: "---\ntitle: 'Simple'\nescriba_key: abc\n---\n") ==
            BundleEntry(path: "y.md", title: "Simple", description: nil, key: "abc"))
    }

    @Test("el estado del bundle recorre todas las carpetas pero nunca cuenta indices ni registros")
    func estado() {
        let estado = bundleState(from: [
            "a.md": "", "x/b.md": "", "x/y/c.md": "", "index.md": "", "x/index.md": "", "x/log.md": "", "log.md": "L",
            "x/nota.txt": "",
        ])

        #expect(estado.entries.map(\.path) == ["a.md", "x/b.md", "x/y/c.md"])
        #expect(estado.log == "L")
    }
}
