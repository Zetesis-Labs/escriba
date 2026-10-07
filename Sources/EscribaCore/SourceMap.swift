import Foundation

public struct SourcePosition: Sendable, Equatable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String { "\(file):\(line):\(column)" }
}

public struct SourceMap: Sendable, Equatable {
    private let sources: [String]
    private let lines: [[SourceMapSegment]]

    public init?(json: String) {
        struct Raw: Decodable {
            let sources: [String]
            let mappings: String
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(json.utf8)),
            let lines = decodeMappings(raw.mappings)
        else { return nil }
        sources = raw.sources.map { $0.hasPrefix("proyecto:") ? String($0.dropFirst("proyecto:".count)) : $0 }
        self.lines = lines
    }

    public func original(line: Int, column: Int) -> SourcePosition? {
        guard line >= 1, line <= lines.count else { return nil }
        let segments = lines[line - 1]
        guard let segment = segments.last(where: { $0.column <= column - 1 }) ?? segments.first,
            sources.indices.contains(segment.source)
        else { return nil }
        return SourcePosition(file: sources[segment.source], line: segment.line + 1, column: segment.sourceColumn + 1)
    }
}

private struct SourceMapSegment: Sendable, Equatable {
    let column: Int
    let source: Int
    let line: Int
    let sourceColumn: Int
}

private let base64Values = Dictionary(
    uniqueKeysWithValues: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".enumerated().map { ($1, $0) })

private func decodeVLQ(_ text: Substring) -> [Int]? {
    var values: [Int] = []
    var value = 0
    var shift = 0
    for character in text {
        guard let digit = base64Values[character] else { return nil }
        value += (digit & 31) << shift
        if digit & 32 != 0 {
            shift += 5
        } else {
            values.append(value & 1 == 1 ? -(value >> 1) : value >> 1)
            value = 0
            shift = 0
        }
    }
    return values
}

private func decodeMappings(_ mappings: String) -> [[SourceMapSegment]]? {
    var source = 0
    var line = 0
    var sourceColumn = 0
    var result: [[SourceMapSegment]] = []
    for generated in mappings.split(separator: ";", omittingEmptySubsequences: false) {
        var column = 0
        var segments: [SourceMapSegment] = []
        for text in generated.split(separator: ",") {
            guard let fields = decodeVLQ(text), !fields.isEmpty else { return nil }
            column += fields[0]
            guard fields.count >= 4 else { continue }
            source += fields[1]
            line += fields[2]
            sourceColumn += fields[3]
            segments.append(SourceMapSegment(column: column, source: source, line: line, sourceColumn: sourceColumn))
        }
        result.append(segments)
    }
    return result
}
