import Foundation

package enum StructuredMemoryValidation {
    package static let maxKeyUTF8Bytes = 4_096

    package static func validateEntityKey(_ key: EntityKey, field: String = "entity key") throws {
        try validateKey(key.rawValue, field: field)
    }

    package static func validatePredicateKey(_ key: PredicateKey, field: String = "predicate key") throws {
        try validateKey(key.rawValue, field: field)
    }

    package static func validateFactValue(_ value: FactValue) throws {
        if case .entity(let key) = value {
            try validateEntityKey(key, field: "fact entity object")
        }
    }

    private static func validateKey(_ rawValue: String, field: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WaxError.encodingError(reason: "\(field) must not be empty")
        }
        let byteCount = rawValue.utf8.count
        guard byteCount <= maxKeyUTF8Bytes else {
            throw WaxError.capacityExceeded(limit: UInt64(maxKeyUTF8Bytes), requested: UInt64(byteCount))
        }
    }
}
