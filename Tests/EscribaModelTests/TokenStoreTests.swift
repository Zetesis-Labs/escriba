import Foundation
import Synchronization
import Testing

@testable import EscribaModel

private func carpeta() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "escriba-tokens-\(UUID().uuidString)")
}

private func permisos(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int ?? -1
}

@Suite("Token en fichero")
struct FileTokenStoreTests {
    @Test("guarda y devuelve el token, en un fichero que solo puede leer el usuario")
    func idaYVuelta() throws {
        let dir = carpeta()
        let store = fileTokenStore(directory: dir, account: "c1")

        store.write("ntn_secreto")

        #expect(store.read() == "ntn_secreto")
        #expect(try permisos(dir.appending(path: "c1.token")) == 0o600)
        #expect(try permisos(dir) == 0o700)
    }

    @Test("sin fichero no hay token, y escribir nil lo borra")
    func borrado() {
        let dir = carpeta()
        let store = fileTokenStore(directory: dir, account: "c1")
        #expect(store.read() == nil)

        store.write("x")
        store.write(nil)

        #expect(store.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "c1.token").path(percentEncoded: false)))
    }

    @Test("cada cuenta tiene su fichero")
    func porCuenta() {
        let dir = carpeta()
        fileTokenStore(directory: dir, account: "a").write("uno")
        fileTokenStore(directory: dir, account: "b").write("dos")

        #expect(fileTokenStore(directory: dir, account: "a").read() == "uno")
        #expect(fileTokenStore(directory: dir, account: "b").read() == "dos")
    }
}

@Suite("Migracion del token desde el Llavero")
struct MigratingTokenStoreTests {
    @Test("la primera lectura copia el token antiguo al fichero y lo retira del Llavero")
    func migra() {
        let fichero = TokenStore.inMemory()
        let llavero = TokenStore.inMemory("ntn_viejo")
        let store = migratingTokenStore(primary: fichero, legacy: llavero)

        #expect(store.read() == "ntn_viejo")
        #expect(fichero.read() == "ntn_viejo")
        #expect(llavero.read() == nil)
    }

    @Test("si el fichero ya tiene token, el Llavero ni se consulta")
    func noConsulta() {
        let fichero = TokenStore.inMemory("ntn_nuevo")
        let consultas = Mutex(0)
        let llavero = TokenStore(
            read: {
                consultas.withLock { $0 += 1 }
                return "otro"
            }, write: { _ in })
        let store = migratingTokenStore(primary: fichero, legacy: llavero)

        #expect(store.read() == "ntn_nuevo")
        #expect(consultas.withLock { $0 } == 0)
    }

    @Test("escribir va al fichero y limpia el Llavero")
    func escribe() {
        let fichero = TokenStore.inMemory()
        let llavero = TokenStore.inMemory("ntn_viejo")
        let store = migratingTokenStore(primary: fichero, legacy: llavero)

        store.write("ntn_nuevo")

        #expect(fichero.read() == "ntn_nuevo")
        #expect(llavero.read() == nil)
    }
}

@Test("guardar una credencial propaga un fallo de disco sin borrar la credencial antigua")
func credencialNoFingeGuardado() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appending(path: "account.token"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = TokenStore.inMemory("anterior")
    let store = migratingTokenStore(primary: fileTokenStore(directory: root, account: "account"), legacy: legacy)
    #expect(throws: (any Error).self) { try store.save("nueva") }
    #expect(legacy.read() == "anterior")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["account.token"])
}
