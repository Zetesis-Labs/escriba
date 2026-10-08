import CryptoKit
import Foundation

public enum ZodPackage {
    public static let version = "4.6.5"
    static let sha256 = "a78c0c533de30dc1c4afc259ac43ac06e390cb0da8d2e32eae355301b50b36fc"
    static let marker = ".instalado"
    public static let projectFolder = ".escriba/zod"

    public static func directory(in applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "herramientas/zod-\(version)")
    }

    public static func isInstalled(in directory: URL) -> Bool {
        (try? String(contentsOf: directory.appending(path: marker), encoding: .utf8)) == version
    }

    public static func install(
        into directory: URL,
        fetch: @Sendable (URL) async throws -> Data = { url in try await URLSession.shared.data(from: url).0 }
    ) async throws {
        let url = URL(string: "https://registry.npmjs.org/zod/-/zod-\(version).tgz")!
        let archive = try await fetch(url)
        guard SHA256.hash(data: archive).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw EsbuildToolsError.checksum("zod-\(version).tgz")
        }
        try unpack(archive, into: directory)
    }

    static func unpack(_ archive: Data, into directory: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: directory.path(percentEncoded: false)) { try files.removeItem(at: directory) }
        for entry in try tarEntries(try gunzip(archive)) {
            guard let path = keptPath(entry.path) else { continue }
            let target = directory.appending(path: path)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.contents.write(to: target)
        }
        try Data(version.utf8).write(to: directory.appending(path: marker))
    }

    static func keptPath(_ path: String) -> String? {
        guard path.hasPrefix("package/") else { return nil }
        let inner = String(path.dropFirst("package/".count))
        let parts = inner.split(separator: "/")
        guard !parts.contains(".."), let first = parts.first, !["src", "v3"].contains(first) else { return nil }
        let keep = inner == "package.json" || inner == "LICENSE" || inner.hasSuffix(".d.ts")
            || (inner.hasSuffix(".js") && !inner.hasSuffix(".d.js"))
        return keep ? inner : nil
    }

    static func file(_ path: String, in directory: URL) -> String? {
        guard !path.split(separator: "/").contains(".."), path.hasSuffix(".js") || path == "package.json" else {
            return nil
        }
        return try? String(contentsOf: directory.appending(path: path), encoding: .utf8)
    }

    @discardableResult
    public static func installTypes(from directory: URL, intoProject project: URL) throws -> Bool {
        let files = FileManager.default
        if files.fileExists(atPath: project.appending(path: "node_modules/zod/package.json").path) { return false }
        let destination = project.appending(path: projectFolder)
        let stamp = destination.appending(path: marker)
        if (try? String(contentsOf: stamp, encoding: .utf8)) == version { return false }
        if files.fileExists(atPath: destination.path(percentEncoded: false)) { try files.removeItem(at: destination) }
        guard let walker = files.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        let base = directory.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(base.count))
                .trimmingPrefix("/")
            guard relative.hasSuffix(".d.ts") || relative == "package.json" || relative == "LICENSE" else { continue }
            let target = destination.appending(path: String(relative))
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: url, to: target)
        }
        try Data(version.utf8).write(to: stamp)
        return true
    }
}

struct TarEntry: Equatable {
    let path: String
    let contents: Data
}

func gunzip(_ data: Data) throws -> Data {
    let bytes = [UInt8](data)
    guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw ArchiveError.notGzip }
    let flags = bytes[3]
    var offset = 10
    if flags & 4 != 0 {
        guard offset + 2 <= bytes.count else { throw ArchiveError.notGzip }
        offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
    }
    for flag: UInt8 in [8, 16] where flags & flag != 0 {
        while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 2 != 0 { offset += 2 }
    guard offset < bytes.count - 8 else { throw ArchiveError.notGzip }
    let deflated = Data(bytes[offset..<(bytes.count - 8)])
    return try (deflated as NSData).decompressed(using: .zlib) as Data
}

func tarEntries(_ data: Data) throws -> [TarEntry] {
    let bytes = [UInt8](data)
    var entries: [TarEntry] = []
    var offset = 0
    var longName: String?
    while offset + 512 <= bytes.count {
        let header = bytes[offset..<offset + 512]
        if header.allSatisfy({ $0 == 0 }) { break }
        let name = tarString(header, 0, 100)
        let prefix = tarString(header, 345, 155)
        guard let size = Int(tarString(header, 124, 12).trimmingCharacters(in: .whitespaces), radix: 8) else {
            throw ArchiveError.corrupt
        }
        let type = header[header.startIndex + 156]
        let start = offset + 512
        guard start + size <= bytes.count else { throw ArchiveError.corrupt }
        let contents = Data(bytes[start..<start + size])
        switch type {
        case UInt8(ascii: "x"):
            longName = paxPath(contents)
        case UInt8(ascii: "0"), 0:
            let path = longName ?? (prefix.isEmpty ? name : "\(prefix)/\(name)")
            entries.append(TarEntry(path: path, contents: contents))
            longName = nil
        default:
            longName = nil
        }
        offset = start + (size + 511) / 512 * 512
    }
    return entries
}

private func tarString(_ header: ArraySlice<UInt8>, _ start: Int, _ length: Int) -> String {
    let field = header[(header.startIndex + start)..<(header.startIndex + start + length)]
    return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
}

private func paxPath(_ contents: Data) -> String? {
    String(decoding: contents, as: UTF8.self).split(separator: "\n").lazy.compactMap { line -> String? in
        guard let space = line.firstIndex(of: " ") else { return nil }
        let record = line[line.index(after: space)...]
        guard record.hasPrefix("path=") else { return nil }
        return String(record.dropFirst("path=".count))
    }.first
}

enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case notGzip
    case corrupt

    var description: String {
        switch self {
        case .notGzip: "el paquete descargado no es un .tgz"
        case .corrupt: "el paquete descargado está roto"
        }
    }
}
