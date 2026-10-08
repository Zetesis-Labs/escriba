import Foundation
import EscribaCore

public enum BundledConnectors {
    public static func program() throws -> ConnectorProgram {
        let source = try String(contentsOf: directory.appending(path: "conectores.js"), encoding: .utf8)
        return ConnectorProgram(source: source, fingerprint: connectorFingerprint(source))
    }

    public static func install(intoProject project: URL) throws {
        let target = project.appending(path: ".escriba/conectores")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for relative in try resourceFiles() {
            let source = directory.appending(path: relative)
            let destination = target.appending(path: relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: source)
            if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
        }
    }

    public static func resolving(in sources: [String: String]) throws -> [String: String] {
        if sources["node_modules/@escriba/conectores/package.json"] != nil { return sources }
        var files = sources
        for relative in try resourceFiles() where ["js", "json", "ts"].contains(URL(fileURLWithPath: relative).pathExtension) {
            files["node_modules/@escriba/conectores/" + relative] = try String(contentsOf: directory.appending(path: relative), encoding: .utf8)
        }
        return files
    }

    private static var directory: URL {
        if let resources = Bundle.main.resourceURL {
            let installed = resources.appending(path: "conectores")
            if FileManager.default.fileExists(atPath: installed.appending(path: "conectores.js").path) { return installed }
        }
        return Bundle.module.url(forResource: "conectores", withExtension: nil)!
    }

    private static func resourceFiles() throws -> [String] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [String] = []
        while let url = walker.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(String(url.path.dropFirst(directory.path.count + 1)))
            }
        }
        return files.sorted()
    }
}
