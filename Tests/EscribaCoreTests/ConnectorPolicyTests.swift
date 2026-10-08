import Testing
import EscribaCore

@Test func huellaConectorCoincideConVectoresSHA256() {
    #expect(connectorFingerprint("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(connectorFingerprint("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func rutasConectorSoloAdmitenComponentesRelativos() {
    #expect(validConnectorRelativePath("carpeta/nota.md"))
    for path in ["", "/etc/passwd", "../nota", "a/../nota", "a//nota", "a/./nota", "a\\nota", "a\0b"] {
        #expect(!validConnectorRelativePath(path))
    }
}
