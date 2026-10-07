import Foundation
import Synchronization
import Testing

@testable import EscribaModel
@testable import EscribaCore
import EscribaEngine

nonisolated final class VigilanteDeRecetas: Sendable {
    private let avisos = Mutex<[@Sendable () -> Void]>([])
    private let paradas = Mutex(0)
    private let vigiladas = Mutex<[URL]>([])

    var detenidos: Int { paradas.withLock { $0 } }
    var carpetas: [URL] { vigiladas.withLock { $0 } }
    func cambiar() { avisos.withLock { $0 }.forEach { $0() } }

    var puerto: FolderWatcher {
        { carpeta, aviso in
            self.vigiladas.withLock { $0.append(carpeta) }
            self.avisos.withLock { $0.append(aviso) }
            return FolderWatch(stop: { self.paradas.withLock { $0 += 1 } })
        }
    }
}

nonisolated final class RegistroDeRecetas: Sendable {
    private let valores = Mutex<[String]>([])
    var todo: [String] { valores.withLock { $0 } }
    func apuntar(_ valor: String) { valores.withLock { $0.append(valor) } }
}

nonisolated private func informe(_ clave: String = "mi-receta") -> RecipeBuildReport {
    RecipeBuildReport(
        builtAt: Date(timeIntervalSince1970: 0),
        recipes: [RecipeStatus(key: clave, name: "Mi receta", active: "abc", activeSince: nil, issues: [])])
}

nonisolated private let carpeta = URL(fileURLWithPath: "/proyectos/recetas")

@MainActor
private func modelo(
    _ registro: RegistroDeRecetas, _ vigilante: VigilanteDeRecetas,
    prepare: @escaping @Sendable () async throws -> Void = {},
    rebuild: (@Sendable (URL) async throws -> RecipeBuildReport)? = nil
) -> RecipeProjectModel {
    RecipeProjectModel(
        prepare: {
            registro.apuntar("prepara")
            try await prepare()
        },
        create: { url in registro.apuntar("crea \(url.lastPathComponent)") },
        rebuild: { url in
            registro.apuntar("compila \(url.lastPathComponent)")
            return try await (rebuild ?? { _ in informe() })(url)
        },
        watcher: vigilante.puerto,
        debounce: .milliseconds(50))
}

@MainActor
@Suite("El modelo del proyecto de recetas")
struct RecetasModelTests {
    @Test("abrir una carpeta prepara las herramientas, crea el proyecto si falta, compila, ensena el estado y vigila; los cambios solo compilan")
    func abrir() async {
        let registro = RegistroDeRecetas()
        let vigilante = VigilanteDeRecetas()
        let recetas = modelo(registro, vigilante)

        await recetas.open(carpeta)

        #expect(registro.todo == ["prepara", "crea recetas", "compila recetas"])
        #expect(recetas.report == informe())
        #expect(recetas.phase == .ready)
        #expect(vigilante.carpetas == [carpeta])
    }

    @Test("varios cambios seguidos compilan una sola vez")
    func cambiosSeguidos() async throws {
        let registro = RegistroDeRecetas()
        let vigilante = VigilanteDeRecetas()
        let recetas = modelo(registro, vigilante)
        await recetas.open(carpeta)

        vigilante.cambiar()
        vigilante.cambiar()
        vigilante.cambiar()
        try await Task.sleep(for: .milliseconds(300))

        #expect(registro.todo == ["prepara", "crea recetas", "compila recetas", "compila recetas"])
    }

    @Test("si no se puede compilar, se dice por que y el ultimo estado se queda")
    func falla() async throws {
        let registro = RegistroDeRecetas()
        let vigilante = VigilanteDeRecetas()
        let veces = Mutex(0)
        let recetas = modelo(registro, vigilante, rebuild: { _ in
            if veces.withLock({ $0 += 1; return $0 }) > 1 { throw CocoaError(.fileReadNoSuchFile) }
            return informe()
        })
        await recetas.open(carpeta)

        vigilante.cambiar()
        try await Task.sleep(for: .milliseconds(300))

        #expect(recetas.report == informe())
        guard case .failed(let motivo) = recetas.phase else {
            Issue.record("debia quedar fallido, esta en \(recetas.phase)")
            return
        }
        #expect(!motivo.isEmpty)
    }

    @Test("si no se puede bajar el compilador, no se compila y se dice")
    func sinCompilador() async {
        let registro = RegistroDeRecetas()
        let recetas = modelo(registro, VigilanteDeRecetas(), prepare: { throw URLError(.notConnectedToInternet) })

        await recetas.open(carpeta)

        #expect(registro.todo == ["prepara"])
        guard case .failed(let motivo) = recetas.phase else {
            Issue.record("debia quedar fallido")
            return
        }
        #expect(motivo.contains("compilador"))
    }

    @Test("abrir otra carpeta deja de vigilar la anterior")
    func otraCarpeta() async {
        let vigilante = VigilanteDeRecetas()
        let recetas = modelo(RegistroDeRecetas(), vigilante)

        await recetas.open(carpeta)
        await recetas.open(URL(fileURLWithPath: "/proyectos/otras"))

        #expect(vigilante.detenidos == 1)
        #expect(recetas.folder == URL(fileURLWithPath: "/proyectos/otras"))
    }
}
