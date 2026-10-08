import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import EscribaCore

struct ConnectorFiles {
    let root: URL

    func read(_ path: String, limit: Int) throws -> String? {
        let (parent, name) = try parent(path, create: false)
        defer { close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ConnectorHostError.denied
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw ConnectorHostError.denied }
        guard metadata.st_size <= limit else { throw ConnectorHostError.limit }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else { throw ConnectorHostError.denied }
            if count == 0 { break }
            guard data.count + count <= limit else { throw ConnectorHostError.limit }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(data: data, encoding: .utf8)
    }

    func write(_ path: String, content: String?) throws {
        let (parent, name) = try parent(path, create: content != nil)
        defer { close(parent) }
        if let content {
            let temporary = ".escriba-" + UUID().uuidString
            let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw ConnectorHostError.denied }
            defer { close(descriptor); unlinkat(parent, temporary, 0) }
            let data = Data(content.utf8)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = systemWrite(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else { throw ConnectorHostError.denied }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0, renameat(parent, temporary, parent, name) == 0 else { throw ConnectorHostError.denied }
            guard fsync(parent) == 0 else { throw ConnectorHostError.denied }
        } else {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw ConnectorHostError.denied }
            guard fsync(parent) == 0 else { throw ConnectorHostError.denied }
        }
    }

    private func parent(_ path: String, create: Bool) throws -> (Int32, String) {
        guard validConnectorRelativePath(path) else { throw ConnectorHostError.denied }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ConnectorHostError.denied }
        let components = root.path.split(separator: "/").map(String.init) + path.split(separator: "/").dropLast().map(String.init)
        for (index, component) in components.enumerated() {
            var next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0 && errno == ENOENT && create && index >= root.path.split(separator: "/").count {
                guard mkdirat(descriptor, component, mode_t(0o700)) == 0 || errno == EEXIST else {
                    close(descriptor); throw ConnectorHostError.denied
                }
                next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            close(descriptor)
            guard next >= 0 else { throw ConnectorHostError.denied }
            descriptor = next
        }
        guard let name = path.split(separator: "/").last else { close(descriptor); throw ConnectorHostError.denied }
        return (descriptor, String(name))
    }
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
    #else
    Glibc.read(descriptor, buffer, count)
    #endif
}

private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #else
    Glibc.write(descriptor, buffer, count)
    #endif
}

func connectorCanonicalFolder(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}
