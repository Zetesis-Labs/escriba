import CryptoKit
import Foundation

public enum EsbuildTools {
    public static let version = "0.28.2"

    struct File: Sendable {
        let name: String
        let remotePath: String
        let sha256: String
    }

    static let files = [
        File(
            name: "esbuild.wasm", remotePath: "esbuild.wasm",
            sha256: "b1831a5c0f6cf688034fb94d0419812f165ea316a3380d3fc00a151e562d2eaf"),
        File(
            name: "browser.js", remotePath: "lib/browser.js",
            sha256: "91593b8f5d1021600a92443717a52e311bb1e1b772981f6aab76cd0ffba33169"),
    ]

    public static func directory(in applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "herramientas/esbuild-wasm-\(version)")
    }

    public static func isInstalled(in directory: URL) -> Bool {
        files.allSatisfy { file in
            (try? Data(contentsOf: directory.appending(path: file.name))).map { sha256($0) == file.sha256 } ?? false
        }
    }

    public static func install(
        into directory: URL,
        fetch: @Sendable (URL) async throws -> Data = { url in try await URLSession.shared.data(from: url).0 }
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            let url = URL(string: "https://cdn.jsdelivr.net/npm/esbuild-wasm@\(version)/\(file.remotePath)")!
            let data = try await fetch(url)
            guard sha256(data) == file.sha256 else { throw EsbuildToolsError.checksum(file.name) }
            try data.write(to: directory.appending(path: file.name), options: .atomic)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum EsbuildToolsError: Error, Equatable, CustomStringConvertible {
    case checksum(String)

    public var description: String {
        switch self {
        case .checksum(let name): "lo descargado para \(name) no es lo esperado; no se instala"
        }
    }
}
