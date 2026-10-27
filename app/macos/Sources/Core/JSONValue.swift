import Foundation

/// A JavaScript string, including isolated UTF-16 surrogates. Swift's `String`
/// equality normalizes Unicode, so neither JSON text nor object keys use it for
/// identity. Convert to `string` only at the display boundary.
public struct JSONText: Sendable, Hashable, ExpressibleByStringLiteral {
    public let codeUnits: [UInt16]

    public init(_ string: String) {
        codeUnits = Array(string.utf16)
    }

    public init(codeUnits: [UInt16]) {
        self.codeUnits = codeUnits
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// Invalid surrogate sequences are repaired for display, never for storage.
    public var string: String { String(decoding: codeUnits, as: UTF16.self) }
}

/// An integer that cannot be represented exactly by binary64. Its validated
/// decimal token stays intact until a consumer explicitly requests a Double.
public struct JSONInteger: Sendable, Hashable {
    public let literal: String
    fileprivate init(_ literal: String) { self.literal = literal }
}

public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case integer(JSONInteger)
    case string(JSONText)
    case array([JSONValue])
    case object([JSONText: JSONValue])

    public static let maximumDepth = 512

    public init(data: Data, maxDepth: Int = maximumDepth) throws {
        self = try Self.parse(data: data, maxDepth: maxDepth)
    }

    public static func parse(data: Data, maxDepth: Int = maximumDepth) throws -> JSONValue {
        try validateDepthLimit(maxDepth)
        var decoder = JSONDecoderBytes(bytes: Array(data), maxDepth: maxDepth)
        return try decoder.decode()
    }

    public func encodedData(maxDepth: Int = maximumDepth) throws -> Data {
        try Self.validateDepthLimit(maxDepth)
        var encoder = JSONEncoderBytes(maxDepth: maxDepth)
        try encoder.encode(self, depth: 0)
        return Data(encoder.bytes)
    }

    public static func text(_ string: String) -> JSONValue { .string(JSONText(string)) }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value.string
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// Measurements may opt into binary64; integer consumers should use intValue.
    public var numberValue: Double? {
        switch self {
        case let .number(value): return value
        case let .integer(value): return Double(value.literal)
        default: return nil
        }
    }

    /// Construct integer fields without first rounding them through Double.
    public static func integer<T: BinaryInteger>(_ value: T) -> JSONValue {
        if let exact = Double(exactly: value) { return .number(exact) }
        return .integer(JSONInteger(String(value)))
    }

    public var intValue: Int? {
        switch self {
        case let .number(value): return Int(exactly: value)
        case let .integer(value): return Int(value.literal)
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var objectValue: [JSONText: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public subscript(_ key: String) -> JSONValue? {
        guard case let .object(value) = self else { return nil }
        return value[JSONText(key)]
    }

    private static func validateDepthLimit(_ maxDepth: Int) throws {
        guard (1...maximumDepth).contains(maxDepth) else {
            throw JSONCodingError(reason: "maxDepth must be between 1 and \(maximumDepth)")
        }
    }
}

public struct JSONCodingError: Error, Sendable, CustomStringConvertible, LocalizedError {
    public let reason: String
    public let byteOffset: Int?

    public init(reason: String, byteOffset: Int? = nil) {
        self.reason = reason
        self.byteOffset = byteOffset
    }

    public var description: String {
        if let byteOffset { return "Invalid JSON at byte \(byteOffset): \(reason)" }
        return "Invalid JSON: \(reason)"
    }

    public var errorDescription: String? { description }
}

private struct JSONDecoderBytes {
    let bytes: [UInt8]
    let maxDepth: Int
    var offset = 0

    mutating func decode() throws -> JSONValue {
        let value = try decodeValue(depth: 0)
        skipWhitespace()
        guard offset == bytes.count else { throw error("trailing content") }
        return value
    }

    mutating func decodeValue(depth: Int) throws -> JSONValue {
        skipWhitespace()
        guard offset < bytes.count else { throw error("expected a value") }
        switch bytes[offset] {
        case 0x6E:
            try consume([0x6E, 0x75, 0x6C, 0x6C])
            return .null
        case 0x74:
            try consume([0x74, 0x72, 0x75, 0x65])
            return .bool(true)
        case 0x66:
            try consume([0x66, 0x61, 0x6C, 0x73, 0x65])
            return .bool(false)
        case 0x22:
            return .string(try decodeString())
        case 0x5B:
            guard depth < maxDepth else { throw error("maximum nesting depth exceeded") }
            offset += 1
            skipWhitespace()
            var values: [JSONValue] = []
            if take(0x5D) { return .array(values) }
            while true {
                values.append(try decodeValue(depth: depth + 1))
                skipWhitespace()
                if take(0x5D) { return .array(values) }
                guard take(0x2C) else { throw error("expected ',' or ']'") }
            }
        case 0x7B:
            guard depth < maxDepth else { throw error("maximum nesting depth exceeded") }
            offset += 1
            skipWhitespace()
            var values: [JSONText: JSONValue] = [:]
            if take(0x7D) { return .object(values) }
            while true {
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == 0x22 else {
                    throw error("expected an object key")
                }
                let key = try decodeString()
                skipWhitespace()
                guard take(0x3A) else { throw error("expected ':'") }
                values[key] = try decodeValue(depth: depth + 1)
                skipWhitespace()
                if take(0x7D) { return .object(values) }
                guard take(0x2C) else { throw error("expected ',' or '}'") }
            }
        case 0x2D, 0x30...0x39:
            return try decodeNumber()
        default:
            throw error("unexpected character")
        }
    }

    mutating func decodeString() throws -> JSONText {
        offset += 1 // The caller checked the opening quote.
        var units: [UInt16] = []
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            switch byte {
            case 0x22:
                return JSONText(codeUnits: units)
            case 0x5C:
                guard offset < bytes.count else { throw error("unfinished string escape") }
                let escaped = bytes[offset]
                offset += 1
                switch escaped {
                case 0x22, 0x5C, 0x2F: units.append(UInt16(escaped))
                case 0x62: units.append(0x08)
                case 0x66: units.append(0x0C)
                case 0x6E: units.append(0x0A)
                case 0x72: units.append(0x0D)
                case 0x74: units.append(0x09)
                case 0x75:
                    var unit: UInt16 = 0
                    for _ in 0..<4 {
                        guard offset < bytes.count, let digit = hexDigit(bytes[offset]) else {
                            throw error("invalid Unicode escape")
                        }
                        unit = unit * 16 + digit
                        offset += 1
                    }
                    // JSON permits isolated surrogates in escaped form, as does JS.
                    units.append(unit)
                default: throw error("invalid string escape")
                }
            case 0x00...0x1F:
                throw error("unescaped control character")
            case 0x20...0x7F:
                units.append(UInt16(byte))
            default:
                let scalar = try decodeUTF8Scalar(first: byte)
                if scalar <= 0xFFFF {
                    units.append(UInt16(scalar))
                } else {
                    let supplementary = scalar - 0x10000
                    units.append(UInt16(0xD800 + (supplementary >> 10)))
                    units.append(UInt16(0xDC00 + (supplementary & 0x3FF)))
                }
            }
        }
        throw error("unterminated string")
    }

    mutating func decodeUTF8Scalar(first: UInt8) throws -> UInt32 {
        let continuationCount: Int
        let minimum: UInt32
        var scalar: UInt32
        switch first {
        case 0xC2...0xDF:
            continuationCount = 1
            minimum = 0x80
            scalar = UInt32(first & 0x1F)
        case 0xE0...0xEF:
            continuationCount = 2
            minimum = 0x800
            scalar = UInt32(first & 0x0F)
        case 0xF0...0xF4:
            continuationCount = 3
            minimum = 0x10000
            scalar = UInt32(first & 0x07)
        default: throw error("invalid UTF-8")
        }
        for _ in 0..<continuationCount {
            guard offset < bytes.count, (0x80...0xBF).contains(bytes[offset]) else {
                throw error("invalid UTF-8 continuation")
            }
            scalar = (scalar << 6) | UInt32(bytes[offset] & 0x3F)
            offset += 1
        }
        guard scalar >= minimum, scalar <= 0x10FFFF, !(0xD800...0xDFFF).contains(scalar) else {
            throw error("invalid UTF-8 scalar")
        }
        return scalar
    }

    mutating func decodeNumber() throws -> JSONValue {
        let start = offset
        _ = take(0x2D)
        guard offset < bytes.count else { throw error("unfinished number") }
        if take(0x30) {
            if offset < bytes.count, isDigit(bytes[offset]) { throw error("leading zero in number") }
        } else {
            guard (0x31...0x39).contains(bytes[offset]) else { throw error("invalid number") }
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
        }
        if take(0x2E) {
            guard offset < bytes.count, isDigit(bytes[offset]) else { throw error("expected fractional digits") }
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
        }
        if take(0x65) || take(0x45) {
            if !take(0x2B) { _ = take(0x2D) }
            guard offset < bytes.count, isDigit(bytes[offset]) else { throw error("expected exponent digits") }
            while offset < bytes.count, isDigit(bytes[offset]) { offset += 1 }
        }
        let token = String(decoding: bytes[start..<offset], as: UTF8.self)
        guard let value = Double(token), value.isFinite else { throw error("non-finite number") }
        if !token.contains("."), !token.contains("e"), !token.contains("E") {
            // Normalize exact binary64 integers to the existing number case, so
            // numeric equality and hashing remain stable for ordinary values.
            if token != "-0", let integer = Int64(token) { return .integer(integer) }
            if token != String(format: "%.0f", value) {
                return .integer(JSONInteger(token))
            }
        }
        return .number(value)
    }

    mutating func consume(_ literal: [UInt8]) throws {
        guard literal.count <= bytes.count - offset,
              bytes[offset..<(offset + literal.count)].elementsEqual(literal) else {
            throw error("invalid literal")
        }
        offset += literal.count
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    mutating func skipWhitespace() {
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x20, 0x09, 0x0A, 0x0D: offset += 1
            default: return
            }
        }
    }

    func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    func hexDigit(_ byte: UInt8) -> UInt16? {
        switch byte {
        case 0x30...0x39: return UInt16(byte - 0x30)
        case 0x41...0x46: return UInt16(byte - 0x41 + 10)
        case 0x61...0x66: return UInt16(byte - 0x61 + 10)
        default: return nil
        }
    }

    func error(_ reason: String) -> JSONCodingError {
        JSONCodingError(reason: reason, byteOffset: offset)
    }
}

private struct JSONEncoderBytes {
    let maxDepth: Int
    var bytes: [UInt8] = []

    mutating func encode(_ value: JSONValue, depth: Int) throws {
        switch value {
        case .null: bytes.append(contentsOf: "null".utf8)
        case let .bool(value): bytes.append(contentsOf: (value ? "true" : "false").utf8)
        case let .number(value):
            guard value.isFinite else { throw JSONCodingError(reason: "non-finite number") }
            // Go integer DTOs reject both decimal and exponent notation, even
            // when their mathematical value is integral. Do not narrow to Int64:
            // a finite Double may hold an integer outside that type's range.
            let token: String
            if value == 0, value.sign == .minus { token = "-0" }
            else if let integer = Int64(exactly: value) { token = String(integer) }
            else if value.rounded(.towardZero) == value {
                token = String(format: "%.0f", value)
            } else { token = String(value) }
            bytes.append(contentsOf: token.utf8)
        case let .integer(value): bytes.append(contentsOf: value.literal.utf8)
        case let .string(value): encodeString(value)
        case let .array(values):
            guard depth < maxDepth else { throw JSONCodingError(reason: "maximum nesting depth exceeded") }
            bytes.append(0x5B)
            for (index, value) in values.enumerated() {
                if index != 0 { bytes.append(0x2C) }
                try encode(value, depth: depth + 1)
            }
            bytes.append(0x5D)
        case let .object(values):
            guard depth < maxDepth else { throw JSONCodingError(reason: "maximum nesting depth exceeded") }
            bytes.append(0x7B)
            // Stable output without Swift String's normalization-sensitive ordering.
            let keys = values.keys.sorted { $0.codeUnits.lexicographicallyPrecedes($1.codeUnits) }
            for (index, key) in keys.enumerated() {
                if index != 0 { bytes.append(0x2C) }
                encodeString(key)
                bytes.append(0x3A)
                if let value = values[key] { try encode(value, depth: depth + 1) }
            }
            bytes.append(0x7D)
        }
    }

    mutating func encodeString(_ text: JSONText) {
        bytes.append(0x22)
        var index = 0
        while index < text.codeUnits.count {
            let unit = text.codeUnits[index]
            index += 1
            switch unit {
            case 0x22: bytes.append(contentsOf: [0x5C, 0x22])
            case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x00...0x1F: encodeEscapedUnit(unit)
            case 0xD800...0xDBFF:
                if index < text.codeUnits.count, (0xDC00...0xDFFF).contains(text.codeUnits[index]) {
                    let low = text.codeUnits[index]
                    index += 1
                    encodeScalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + UInt32(low) - 0xDC00)
                } else {
                    encodeEscapedUnit(unit)
                }
            case 0xDC00...0xDFFF: encodeEscapedUnit(unit)
            default: encodeScalar(UInt32(unit))
            }
        }
        bytes.append(0x22)
    }

    mutating func encodeEscapedUnit(_ unit: UInt16) {
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        bytes.append(contentsOf: [0x5C, 0x75,
            hex[Int((unit >> 12) & 15)], hex[Int((unit >> 8) & 15)],
            hex[Int((unit >> 4) & 15)], hex[Int(unit & 15)]])
    }

    mutating func encodeScalar(_ scalar: UInt32) {
        switch scalar {
        case ...0x7F: bytes.append(UInt8(scalar))
        case ...0x7FF:
            bytes.append(UInt8(0xC0 | (scalar >> 6)))
            bytes.append(UInt8(0x80 | (scalar & 0x3F)))
        case ...0xFFFF:
            bytes.append(UInt8(0xE0 | (scalar >> 12)))
            bytes.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (scalar & 0x3F)))
        default:
            bytes.append(UInt8(0xF0 | (scalar >> 18)))
            bytes.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
            bytes.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
            bytes.append(UInt8(0x80 | (scalar & 0x3F)))
        }
    }
}
