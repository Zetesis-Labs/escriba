import Foundation
import Testing
import EscribaCore
@testable import EscribaNativeHost

@Suite("Native host protocol")
struct ProtocolTests {
    @Test func statusUsesStableEnvelopeAndReportsLiveAvailability() async throws {
        let host = NativeHost()
        let reply = try parseData(await host.handle(#"{"id":"s1","method":"status","params":{}}"#))
        #expect(reply["id"] == .string("s1"))
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["protocolVersion"] == .number(1))
        #expect(reply["result"]?["whisper"]?["modelsPath"]?.text != nil)
        #expect(reply["result"]?["llm"]?["available"] != nil)
        #expect(reply["result"]?["llm"]?["capacity"] == .number(3500))
    }

    @Test func estadoConsultaLaVarianteSolicitadaSinDescargarla() async throws {
        let host = NativeHost()
        let model = "test_model_\(UUID().uuidString)"
        let reply = try parseData(await host.handle(#"{"id":"m1","method":"status","params":{"model":"\#(model)"}}"#))
        #expect(reply["result"]?["whisper"]?["model"] == .string(model))
        #expect(reply["result"]?["whisper"]?["available"] == .bool(false))
        #expect(reply["result"]?["whisper"]?["modelsPath"]?.text != nil)
        let invalid = try parseData(await host.handle(#"{"id":"m2","method":"status","params":{"model":"../other"}}"#))
        #expect(invalid["error"]?["code"] == .string("invalid_params"))
    }

    @Test func transcripcionRechazaIdiomaYNumeroDeHablantesInvalidos() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try syntheticWAV(duration: 0.25).write(to: file)
        let host = NativeHost()
        let language = try parseData(await host.handle(#"{"id":"l1","method":"transcribe","params":{"audioPath":"\#(file.path)","language":42}}"#))
        #expect(language["error"]?["code"] == .string("invalid_params"))
        let speakers = try parseData(await host.handle(#"{"id":"l2","method":"transcribe","params":{"audioPath":"\#(file.path)","speakers":2.5}}"#))
        #expect(speakers["error"]?["code"] == .string("invalid_params"))
    }

    @Test func modeloNoInstaladoComunicaServicioNoDisponibleSinDescargar() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try syntheticWAV(duration: 0.25).write(to: file)
        let model = "test_model_\(UUID().uuidString)"
        let reply = try parseData(await NativeHost().handle(#"{"id":"missing","method":"transcribe","params":{"audioPath":"\#(file.path)","model":"\#(model)"}}"#))
        #expect(reply["error"]?["code"] == .string("backend_unavailable"))
    }

    @Test func invalidRequestDoesNotEndSession() async throws {
        let host = NativeHost()
        let invalid = try parseData(await host.handle(#"{"id":"bad","method":"unknown","params":{}}"#))
        #expect(invalid["id"] == .string("bad"))
        #expect(invalid["error"]?["code"] == .string("unknown_method"))
        let valid = try parseData(await host.handle(#"{"id":"next","method":"status","params":{}}"#))
        #expect(valid["result"]?["protocolVersion"] == .number(1))
    }

    @Test func audioInfoReadsSyntheticWAV() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try syntheticWAV(duration: 0.25).write(to: file)
        let request = dataText(.object([
            .init(name: "id", value: .string("a1")),
            .init(name: "method", value: .string("audioInfo")),
            .init(name: "params", value: .object([.init(name: "audioPath", value: .string(file.path))])),
        ]))
        let reply = try parseData(await NativeHost().handle(request))
        guard case .number(let duration) = reply["result"]?["duration"] else {
            Issue.record("audioInfo did not return duration: \(reply)")
            return
        }
        #expect(abs(duration - 0.25) < 0.001)
    }

    @Test func estadoDeCapturaInactivaSobreviveALaConsulta() async throws {
        let host = NativeHost()
        let reply = try parseData(await host.handle(#"{"id":"r1","method":"recordingStatus","params":{}}"#))
        #expect(reply["result"]?["active"] == .bool(false))
        #expect(reply["result"]?["paused"] == .bool(false))
        #expect(reply["result"]?["audioPath"] == .null)
        #expect(reply["result"]?["duration"] == .number(0))
    }

    @Test func estadoDeArchivoConsultaAudioSinteticoSinAbrirlo() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try syntheticWAV(duration: 0.25).write(to: file)
        let host = NativeHost()
        let reply = try parseData(await host.handle(#"{"id":"f1","method":"fileStatus","params":{"path":"\#(file.path)"}}"#))
        #expect(reply["result"]?["size"] == .number(Double(44 + 8000)))
        #expect(reply["result"]?["dataless"] == .bool(false))
        #expect(reply["result"]?["modifiedAt"]?.text != nil)
        let missing = try parseData(await host.handle(#"{"id":"f2","method":"fileStatus","params":{"path":"\#(file.path).missing"}}"#))
        #expect(missing["error"]?["code"] == .string("audio_missing"))
    }

    @Test func materializacionDeArchivoLocalRespondeSinEsperarNiDescargar() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try syntheticWAV(duration: 0.25).write(to: file)
        let host = NativeHost()
        let reply = try parseData(await host.handle(#"{"id":"i1","method":"materialize","params":{"path":"\#(file.path)","timeoutSeconds":1}}"#))
        #expect(reply["result"]?["ready"] == .bool(true))
        #expect(reply["result"]?["size"] == .number(8044))
        let invalid = try parseData(await host.handle(#"{"id":"i2","method":"materialize","params":{"path":"\#(file.path)","timeoutSeconds":301}}"#))
        #expect(invalid["error"]?["code"] == .string("invalid_params"))
    }

    @Test func materializacionRechazaBookmarkCorruptoAunqueElArchivoSeaLegible() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try syntheticWAV(duration: 0.25).write(to: file)
        let reply = try parseData(await NativeHost().handle(#"{"id":"b1","method":"materialize","params":{"path":"\#(file.path)","folderBookmark":[1,2,3],"timeoutSeconds":1}}"#))
        #expect(reply["error"]?["code"] == .string("invalid_params"))
        #expect(reply["result"] == nil)
    }

    @Test func materializacionResuelveCarpetaAutorizadaYRechazaAudioFueraDeElla() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "autorizada", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = folder.appending(path: "dentro.wav")
        let outside = root.appending(path: "fuera.wav")
        try syntheticWAV(duration: 0.25).write(to: inside)
        try syntheticWAV(duration: 0.25).write(to: outside)
        let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        func request(_ file: URL) -> String {
            dataText(.object([
                .init(name: "id", value: .string("folder")),
                .init(name: "method", value: .string("materialize")),
                .init(name: "params", value: .object([
                    .init(name: "path", value: .string(file.path)),
                    .init(name: "timeoutSeconds", value: .number(1)),
                    .init(name: "folderBookmark", value: .array(bookmark.map { .number(Double($0)) })),
                ])),
            ]))
        }
        let insideReply = try parseData(await NativeHost().handle(request(inside)))
        #expect(insideReply["result"]?["ready"] == .bool(true))
        #expect(insideReply["result"]?["size"] == .number(8044))
        let outsideReply = try parseData(await NativeHost().handle(request(outside)))
        #expect(outsideReply["error"]?["code"] == .string("invalid_params"))
        #expect(outsideReply["result"] == nil)
    }

    private func syntheticWAV(duration: Double) -> Data {
        let samples = UInt32(16_000 * duration)
        let bytes = samples * 2
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func little<T: FixedWidthInteger>(_ value: T) {
            var raw = value.littleEndian
            withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); little(UInt32(36) + bytes); ascii("WAVEfmt ")
        little(UInt32(16)); little(UInt16(1)); little(UInt16(1))
        little(UInt32(16_000)); little(UInt32(32_000)); little(UInt16(2)); little(UInt16(16))
        ascii("data"); little(bytes)
        data.append(Data(repeating: 0, count: Int(bytes)))
        return data
    }
}
