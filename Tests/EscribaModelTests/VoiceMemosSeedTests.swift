import Foundation
import Testing

@testable import EscribaModel

@Suite("Siembra de Notas de Voz")
struct VoiceMemosSeedTests {
    private let root = URL(fileURLWithPath: "/Recordings")
    private let jpr = WatchedFolder(path: "/JPR", style: .justPressRecord)

    @Test("se anade sola la primera vez, junto a las que ya hubiera")
    func primeraVez() {
        let result = seeding([jpr], alreadySeeded: false, exists: true)

        #expect(result.map(\.style) == [.justPressRecord, .voiceMemos])
        #expect(result.last?.path == "/Recordings")
    }

    @Test("si el usuario la borro, borrada se queda")
    func noResiembra() {
        #expect(seeding([jpr], alreadySeeded: true, exists: true) == [jpr])
    }

    @Test("no se duplica si ya estaba puesta")
    func noDuplica() {
        let puesta = WatchedFolder(path: "/Recordings", style: .voiceMemos)

        #expect(seeding([puesta], alreadySeeded: false, exists: true) == [puesta])
    }

    @Test("sin Notas de Voz en el sistema no se siembra nada")
    func sinContenedor() {
        #expect(seeding([jpr], alreadySeeded: false, exists: false) == [jpr])
    }

    private func seeding(
        _ folders: [WatchedFolder], alreadySeeded: Bool, exists: Bool
    ) -> [WatchedFolder] {
        seededWithVoiceMemos(folders, root: exists ? root : nil, alreadySeeded: alreadySeeded)
    }
}
