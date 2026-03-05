import Foundation

/// Stable row identifier for a stored structured fact.
package struct FactRowID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    package var rawValue: Int64

    package init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    package static func < (lhs: FactRowID, rhs: FactRowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
