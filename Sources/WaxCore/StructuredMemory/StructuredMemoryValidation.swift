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

    package static func validateEvidence(_ evidence: [StructuredEvidence]) throws {
        for item in evidence {
            if let span = item.spanUTF8 {
                guard span.lowerBound >= 0 else {
                    throw WaxError.encodingError(reason: "evidence span start must be non-negative")
                }
                guard !span.isEmpty else {
                    throw WaxError.encodingError(reason: "evidence span must not be empty")
                }
            }

            if let confidence = item.confidence {
                guard confidence.isFinite, (0...1).contains(confidence) else {
                    throw WaxError.encodingError(reason: "evidence confidence must be finite and between 0 and 1")
                }
            }
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
