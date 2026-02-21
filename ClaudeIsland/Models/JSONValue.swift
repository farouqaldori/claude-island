//
//  JSONValue.swift
//  ClaudeIsland
//
//  Type-safe JSON value — replaces AnyCodable's type-erasing `Any` wrapper.
//  Natively Sendable without @unchecked since all cases contain Sendable types.
//

import Foundation

// MARK: - JSONValue

/// A recursive enum representing a JSON value.
///
/// Replaces `AnyCodable` (which wrapped `Any` and required `@unchecked Sendable`)
/// with a type-safe, natively `Sendable` representation.
nonisolated enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    // MARK: Lifecycle

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([Self].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: Self].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSON value")
        }
    }

    // MARK: Internal

    /// Convenience accessor for string values
    var stringValue: String? {
        if case let .string(str) = self { str } else { nil }
    }

    /// Convenience accessor for integer values
    var intValue: Int? {
        if case let .int(num) = self { num } else { nil }
    }

    /// Convenience accessor for boolean values
    var boolValue: Bool? {
        if case let .bool(val) = self { val } else { nil }
    }

    /// Convenience accessor for double values
    var doubleValue: Double? {
        if case let .double(val) = self { val } else { nil }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}
