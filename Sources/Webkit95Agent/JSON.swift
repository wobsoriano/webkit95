import Foundation

/// A parsed JSON-RPC payload. Sendable so wire messages can cross the inbox.
enum JSONValue: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// nil for anything that is not a single valid JSON document.
    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { return fields[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Compact output never contains a raw LF, so it is always one wire line.
    func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(to: &out, pretty: pretty, indent: "")
        return out
    }

    private func write(to out: inout String, pretty: Bool, indent: String) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value): out += value.isFinite ? "\(value)" : "null"
        case .string(let value): JSONValue.writeString(value, to: &out)
        case .array(let items):
            writeContainer(items, open: "[", close: "]", to: &out, pretty: pretty, indent: indent) {
                item, out, inner in item.write(to: &out, pretty: pretty, indent: inner)
            }
        case .object(let fields):
            let sorted = fields.sorted { $0.key < $1.key }
            writeContainer(sorted, open: "{", close: "}", to: &out, pretty: pretty, indent: indent) {
                field, out, inner in
                JSONValue.writeString(field.key, to: &out)
                out += pretty ? ": " : ":"
                field.value.write(to: &out, pretty: pretty, indent: inner)
            }
        }
    }

    private func writeContainer<T>(
        _ items: [T], open: String, close: String, to out: inout String, pretty: Bool, indent: String,
        element: (T, inout String, String) -> Void
    ) {
        out += open
        guard !items.isEmpty else {
            out += close
            return
        }
        let inner = indent + "  "
        for (index, item) in items.enumerated() {
            if index > 0 { out += "," }
            if pretty { out += "\n" + inner }
            element(item, &out, inner)
        }
        if pretty { out += "\n" + indent }
        out += close
    }

    private static func writeString(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Newline delimited framing. Splits only on the LF byte, so U+2028 and other Unicode separators
/// stay inside a line, and buffers bytes so a line or a multibyte character can span reads.
struct LineFramer {
    private var buffer = Data()

    /// The complete lines in `bytes` plus whatever was buffered, without LF or a trailing CR.
    /// Empty lines are dropped.
    mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = Self.trimmed(buffer[start..<newline])
            if !line.isEmpty { lines.append(line) }
            start = buffer.index(after: newline)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        return lines
    }

    /// The unterminated tail at end of stream.
    mutating func finish() -> Data? {
        let line = Self.trimmed(buffer[...])
        buffer = Data()
        return line.isEmpty ? nil : line
    }

    private static func trimmed(_ line: Data.SubSequence) -> Data {
        Data(line.last == 0x0D ? line.dropLast() : line)
    }
}
