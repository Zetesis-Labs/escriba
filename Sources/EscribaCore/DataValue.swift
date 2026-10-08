public indirect enum DataValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([DataValue])
    case object([DataField])

    public subscript(name: String) -> DataValue? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.name == name }?.value
    }

    public var text: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

public struct DataField: Sendable, Equatable {
    public let name: String
    public let value: DataValue

    public init(name: String, value: DataValue) {
        self.name = name
        self.value = value
    }
}

public struct DataParseError: Error, Equatable, CustomStringConvertible {
    public let offset: Int
    public let reason: String

    public var description: String { "no es JSON válido (posición \(offset)): \(reason)" }
}

public func parseData(_ text: String) throws(DataParseError) -> DataValue {
    var parser = DataParser(bytes: Array(text.utf8))
    parser.skipWhitespace()
    let value = try parser.value()
    parser.skipWhitespace()
    guard parser.atEnd else { throw parser.failure("sobra texto después del valor") }
    return value
}

public func dataText(_ value: DataValue, pretty: Bool = false) -> String {
    var output = ""
    write(value, into: &output, indent: pretty ? 0 : nil)
    return output
}

private func write(_ value: DataValue, into output: inout String, indent: Int?) {
    switch value {
    case .null: output += "null"
    case .bool(let flag): output += flag ? "true" : "false"
    case .number(let number): output += numberText(number)
    case .string(let text): output += quoted(text)
    case .array(let items):
        writeContainer(items, open: "[", close: "]", into: &output, indent: indent) { item, output, indent in
            write(item, into: &output, indent: indent)
        }
    case .object(let fields):
        writeContainer(fields, open: "{", close: "}", into: &output, indent: indent) { field, output, indent in
            output += quoted(field.name) + (indent == nil ? ":" : ": ")
            write(field.value, into: &output, indent: indent)
        }
    }
}

private func writeContainer<Element>(
    _ elements: [Element], open: String, close: String, into output: inout String, indent: Int?,
    _ writeElement: (Element, inout String, Int?) -> Void
) {
    output += open
    guard !elements.isEmpty else {
        output += close
        return
    }
    let inner = indent.map { $0 + 2 }
    for (index, element) in elements.enumerated() {
        if index > 0 { output += "," }
        if let inner { output += "\n" + String(repeating: " ", count: inner) }
        writeElement(element, &output, inner)
    }
    if let indent { output += "\n" + String(repeating: " ", count: indent) }
    output += close
}

private func numberText(_ number: Double) -> String {
    if number == number.rounded(), abs(number) < 9_007_199_254_740_992 { return String(Int64(number)) }
    return "\(number)"
}

private func quoted(_ text: String) -> String {
    var output = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": output += "\\\""
        case "\\": output += "\\\\"
        case "\n": output += "\\n"
        case "\r": output += "\\r"
        case "\t": output += "\\t"
        case "\u{8}": output += "\\b"
        case "\u{C}": output += "\\f"
        case _ where scalar.value < 0x20:
            let hex = String(scalar.value, radix: 16)
            output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        default: output.unicodeScalars.append(scalar)
        }
    }
    return output + "\""
}

private let maximumDataDepth = 64

private struct DataParser {
    let bytes: [UInt8]
    var position = 0
    var depth = 0

    var atEnd: Bool { position == bytes.count }

    func failure(_ reason: String) -> DataParseError {
        DataParseError(offset: position, reason: reason)
    }

    mutating func skipWhitespace() {
        while position < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[position]) { position += 1 }
    }

    mutating func value() throws(DataParseError) -> DataValue {
        guard position < bytes.count else { throw failure("se acabó el texto") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return try nested { (parser: inout DataParser) throws(DataParseError) in try parser.object() }
        case UInt8(ascii: "["): return try nested { (parser: inout DataParser) throws(DataParseError) in try parser.array() }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        default: return .number(try number())
        }
    }

    private mutating func nested(
        _ body: (inout DataParser) throws(DataParseError) -> DataValue
    ) throws(DataParseError) -> DataValue {
        guard depth < maximumDataDepth else { throw failure("más de \(maximumDataDepth) niveles anidados") }
        depth += 1
        defer { depth -= 1 }
        return try body(&self)
    }

    private mutating func literal(_ word: String, _ value: DataValue) throws(DataParseError) -> DataValue {
        let expected = Array(word.utf8)
        guard bytes.count - position >= expected.count, Array(bytes[position..<position + expected.count]) == expected
        else { throw failure("se esperaba \(word)") }
        position += expected.count
        return value
    }

    private mutating func object() throws(DataParseError) -> DataValue {
        position += 1
        var fields: [DataField] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return .object(fields)
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                throw failure("se esperaba el nombre de un campo entre comillas")
            }
            let name = try string()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            fields.append(DataField(name: name, value: try value()))
            skipWhitespace()
            if try closes("}") { return .object(fields) }
        }
    }

    private mutating func array() throws(DataParseError) -> DataValue {
        position += 1
        var items: [DataValue] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try value())
            skipWhitespace()
            if try closes("]") { return .array(items) }
        }
    }

    private mutating func closes(_ close: Unicode.Scalar) throws(DataParseError) -> Bool {
        guard position < bytes.count else { throw failure("falta cerrar con \(close)") }
        if bytes[position] == UInt8(ascii: close) {
            position += 1
            return true
        }
        try expect(",")
        return false
    }

    private mutating func expect(_ character: Unicode.Scalar) throws(DataParseError) {
        guard position < bytes.count, bytes[position] == UInt8(ascii: character) else {
            throw failure("se esperaba «\(character)»")
        }
        position += 1
    }

    private mutating func string() throws(DataParseError) -> String {
        position += 1
        var scalars = String.UnicodeScalarView()
        var run: [UInt8] = []
        func flush() {
            scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
            run.removeAll()
        }
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            switch byte {
            case UInt8(ascii: "\""):
                flush()
                return String(scalars)
            case UInt8(ascii: "\\"):
                flush()
                scalars.append(try escaped())
            case 0..<0x20:
                throw failure("un texto no puede llevar caracteres de control sin escapar")
            default:
                run.append(byte)
            }
        }
        throw failure("falta cerrar las comillas")
    }

    private mutating func escaped() throws(DataParseError) -> Unicode.Scalar {
        guard position < bytes.count else { throw failure("escape incompleto") }
        let byte = bytes[position]
        position += 1
        switch byte {
        case UInt8(ascii: "\""): return "\""
        case UInt8(ascii: "\\"): return "\\"
        case UInt8(ascii: "/"): return "/"
        case UInt8(ascii: "b"): return "\u{8}"
        case UInt8(ascii: "f"): return "\u{C}"
        case UInt8(ascii: "n"): return "\n"
        case UInt8(ascii: "r"): return "\r"
        case UInt8(ascii: "t"): return "\t"
        case UInt8(ascii: "u"):
            let high = try hexUnit()
            guard (0xD800..<0xDC00).contains(high) else {
                return Unicode.Scalar(high) ?? "\u{FFFD}"
            }
            guard bytes.count - position >= 6, bytes[position] == UInt8(ascii: "\\"),
                bytes[position + 1] == UInt8(ascii: "u")
            else { return "\u{FFFD}" }
            let start = position
            position += 2
            let low = try hexUnit()
            guard (0xDC00..<0xE000).contains(low) else {
                position = start
                return "\u{FFFD}"
            }
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}"
        default:
            throw failure("escape desconocido")
        }
    }

    private mutating func hexUnit() throws(DataParseError) -> UInt32 {
        guard bytes.count - position >= 4,
            let unit = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16)
        else { throw failure("\\u necesita cuatro cifras hexadecimales") }
        position += 4
        return unit
    }

    private mutating func number() throws(DataParseError) -> Double {
        let start = position
        let allowed = Set("+-0123456789.eE".utf8)
        while position < bytes.count, allowed.contains(bytes[position]) { position += 1 }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        guard !text.isEmpty, text.first != "+", !text.hasPrefix("."), !text.hasPrefix("-."),
            let number = Double(text), number.isFinite
        else {
            position = start
            throw failure("se esperaba un valor")
        }
        return number
    }
}
