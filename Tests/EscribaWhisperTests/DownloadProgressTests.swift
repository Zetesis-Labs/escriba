import Synchronization
import Testing

@testable import EscribaWhisper

@Suite("Progreso de la descarga de un modelo")
struct DownloadProgressTests {
    @Test("avanza por bytes aunque WhisperKit cuente ficheros")
    func porBytes() {
        let fraction = WhisperKitBackend.downloadFraction(files: 0.45, bytes: 2_000, expected: 3_000)
        #expect(abs(fraction - 2.0 / 3.0) < 0.0001)
    }

    @Test("sin tamaño conocido se queda con lo que dice WhisperKit")
    func sinTamano() {
        #expect(WhisperKitBackend.downloadFraction(files: 0.45, bytes: 2_000, expected: nil) == 0.45)
    }

    @Test("por bytes no llega al final hasta que WhisperKit termina")
    func noTerminaPorBytes() {
        #expect(WhisperKitBackend.downloadFraction(files: 0.9, bytes: 9_000, expected: 3_000) == 0.99)
        #expect(WhisperKitBackend.downloadFraction(files: 1, bytes: 9_000, expected: 3_000) == 1)
    }

    @Test("el progreso que se comunica nunca retrocede")
    func noRetrocede() {
        let sent = Mutex<[Double]>([])
        let progress = DownloadProgress(expected: 1_000) { fraction in sent.withLock { $0.append(fraction) } }

        progress.bytes(500)
        progress.files(0.2)
        progress.bytes(400)
        progress.files(1)

        #expect(sent.withLock { $0 } == [0.5, 1])
    }
}
