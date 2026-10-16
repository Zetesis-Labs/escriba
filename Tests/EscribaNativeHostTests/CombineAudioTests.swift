import AVFoundation
import Foundation
import Testing
import EscribaCore
@testable import EscribaNativeHost

@Suite("Native host combineAudio")
struct CombineAudioTests {
    private func silence(seconds: Double, in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(16_000 * seconds))!
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private func request(_ id: String, _ inputs: [URL], output: URL, gap: Double? = nil) -> String {
        let list = inputs.map { "\"\($0.path)\"" }.joined(separator: ",")
        let gapField = gap.map { ",\"gapSeconds\":\($0)" } ?? ""
        return "{\"id\":\"\(id)\",\"method\":\"combineAudio\",\"params\":{\"inputs\":[\(list)]\(gapField),\"outputPath\":\"\(output.path)\"}}"
    }

    @Test func uneLasPiezasEnOrdenConUnSegundoDeSilencioYMideCadaTramo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("combine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try silence(seconds: 1, in: directory, name: "primera.caf")
        let second = try silence(seconds: 2, in: directory, name: "segunda.caf")
        let output = directory.appendingPathComponent("mezcla.m4a")
        let host = NativeHost()
        let reply = try parseData(await host.handle(request("c1", [second, first], output: output)))
        #expect(reply["error"] == nil)
        let parts = reply["result"]?["parts"]
        guard case .array(let items)? = parts, items.count == 2 else {
            Issue.record("faltan las piezas: \(String(describing: parts))")
            return
        }
        func seconds(_ value: DataValue?) -> Double { if case .number(let number)? = value { return number }; return -1 }
        #expect(abs(seconds(items[0]["start"]) - 0) < 0.05)
        #expect(abs(seconds(items[0]["end"]) - 2) < 0.05)
        #expect(abs(seconds(items[1]["start"]) - 3) < 0.05)
        #expect(abs(seconds(items[1]["end"]) - 4) < 0.05)
        #expect(abs(seconds(reply["result"]?["duration"]) - 4) < 0.05)
        let written = try AVAudioFile(forReading: output)
        #expect(abs(Double(written.length) / written.processingFormat.sampleRate - 4) < 0.1)
    }

    @Test func unaPiezaIlegibleFallaNombrandoSuRutaSinEscribirNada() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("combine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = try silence(seconds: 1, in: directory, name: "buena.caf")
        let bad = directory.appendingPathComponent("rota.ogg")
        try "esto no es audio".write(to: bad, atomically: true, encoding: .utf8)
        let output = directory.appendingPathComponent("mezcla.m4a")
        let host = NativeHost()
        let reply = try parseData(await host.handle(request("c2", [good, bad], output: output)))
        #expect(reply["error"]?["code"] == .string("unreadable_audio"))
        #expect(reply["error"]?["message"]?.text?.contains(bad.path) == true)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let few = try parseData(await host.handle(request("c3", [good], output: output)))
        #expect(few["error"]?["code"] == .string("invalid_params"))
    }
}
