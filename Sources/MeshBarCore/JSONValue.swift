import Foundation

/// A JSON value we can both build (request bodies) and walk (responses).
///
/// Codable is the boundary with `JSONEncoder` / `JSONDecoder`. Higher-level
/// models intentionally read this tree with optional accessors instead of a
/// rigid synthesized `Decodable`, because one mistyped field on a Velop would
/// otherwise fail the entire document.
public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .number(Double(value))
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            if value.isFinite,
               value.rounded() == value,
               value >= Double(Int64.min),
               value <= Double(Int64.max) {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value):
            return value
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .number(value):
            return value.isFinite ? value : nil
        case let .string(value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    public var intValue: Int? {
        guard let doubleValue else { return nil }
        guard doubleValue.rounded() == doubleValue,
              doubleValue >= Double(Int.min),
              doubleValue <= Double(Int.max) else { return nil }
        return Int(doubleValue)
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }
}

extension JSONValue {
    func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
