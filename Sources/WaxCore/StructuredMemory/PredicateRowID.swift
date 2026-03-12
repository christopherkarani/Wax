import Foundation

/// Stable row identifier for a stored predicate.
package struct PredicateRowID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    package var rawValue: Int64

    package init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    package static func < (lhs: PredicateRowID, rhs: PredicateRowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
