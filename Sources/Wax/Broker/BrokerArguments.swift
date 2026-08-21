import Foundation

/// Thin typed accessor over a broker argument bag.
///
/// Pure value wrapper — no I/O. Used by ``BrokerCommand`` decode.
package struct BrokerArguments: Sendable {
    package let values: [String: AgentBrokerValue]

    package init(_ values: [String: AgentBrokerValue]) {
        self.values = values
    }

    package func requiredString(_ key: String, maxBytes: Int) throws -> String {
        guard let raw = try optionalString(key) else {
            throw BrokerValidationError.missing(key)
        }
        guard raw.utf8.count <= maxBytes else {
            throw BrokerValidationError.invalid("\(key) exceeds \(maxBytes) bytes")
        }
        return raw
    }

    package func requiredStringPreservingWhitespace(_ key: String, maxBytes: Int) throws -> String {
        guard let raw = try optionalStringPreservingWhitespace(key) else {
            throw BrokerValidationError.missing(key)
        }
        guard raw.utf8.count <= maxBytes else {
            throw BrokerValidationError.invalid("\(key) exceeds \(maxBytes) bytes")
        }
        return raw
    }

    package func optionalString(_ key: String) throws -> String? {
        try optionalStringPreservingWhitespace(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package func optionalStringPreservingWhitespace(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        // CLI/MCP often send explicit JSON null for omitted optional filters.
        if value == .null { return nil }
        guard let stringValue = value.stringValue else {
            throw BrokerValidationError.invalid("\(key) must be a string")
        }
        return stringValue
    }

    package func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        if value == .null { return nil }
        guard let array = value.arrayValue else {
            throw BrokerValidationError.invalid("\(key) must be an array of strings")
        }
        return try array.map { element in
            guard let stringValue = element.stringValue else {
                throw BrokerValidationError.invalid("\(key) must contain only strings")
            }
            return stringValue
        }
    }

    package func optionalObject(_ key: String) throws -> [String: AgentBrokerValue]? {
        guard let value = values[key] else { return nil }
        if value == .null { return nil }
        guard let object = value.objectValue else {
            throw BrokerValidationError.invalid("\(key) must be an object")
        }
        return object
    }

    package func optionalBool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard let boolValue = value.boolValue else {
            throw BrokerValidationError.invalid("\(key) must be a boolean")
        }
        return boolValue
    }

    package func optionalInt(_ key: String) throws -> Int? {
        guard let parsed = try optionalInt64(key) else { return nil }
        guard let intValue = Int(exactly: parsed) else {
            throw BrokerValidationError.invalid("\(key) is out of range")
        }
        return intValue
    }

    package func optionalUInt64(_ key: String) throws -> UInt64? {
        guard let value = values[key] else { return nil }
        guard let intValue = value.intValue, intValue >= 0 else {
            throw BrokerValidationError.invalid("\(key) must be a non-negative integer")
        }
        return UInt64(intValue)
    }

    package func requiredInt64(_ key: String) throws -> Int64 {
        guard let value = values[key], let intValue = value.intValue else {
            throw BrokerValidationError.missing(key)
        }
        return intValue
    }

    package func optionalInt64(_ key: String) throws -> Int64? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let intValue):
            return intValue
        case .double(let double):
            guard double.isFinite else {
                throw BrokerValidationError.invalid("\(key) is out of range")
            }
            guard double.rounded() == double else {
                throw BrokerValidationError.invalid("\(key) must be an integer")
            }
            guard let intValue = Int64(exactly: double) else {
                throw BrokerValidationError.invalid("\(key) is out of range")
            }
            return intValue
        default:
            throw BrokerValidationError.invalid("\(key) must be an integer")
        }
    }

    package func optionalDouble(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        guard let doubleValue = value.doubleValue else {
            throw BrokerValidationError.invalid("\(key) must be a number")
        }
        return doubleValue
    }

    package func optionalFloat(_ key: String) throws -> Float? {
        guard let value = try optionalDouble(key) else { return nil }
        guard value.isFinite else {
            throw BrokerValidationError.invalid("\(key) must be a finite number")
        }
        return Float(value)
    }

    package func requiredValue(_ key: String) throws -> AgentBrokerValue {
        guard let value = values[key] else {
            throw BrokerValidationError.missing(key)
        }
        return value
    }

    package func optionalValue(_ key: String) throws -> AgentBrokerValue? {
        values[key]
    }
}

package enum BrokerValidationError: LocalizedError, Sendable, Equatable {
    case missing(String)
    case invalid(String)

    package var errorDescription: String? {
        switch self {
        case .missing(let key):
            return "Missing required argument '\(key)'."
        case .invalid(let message):
            return message
        }
    }
}
