import Foundation

public func logTail(of url: URL, maxBytes: Int) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try handle.seek(toOffset: start)
    let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines
}

public func fileSize(of url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? Int
}
