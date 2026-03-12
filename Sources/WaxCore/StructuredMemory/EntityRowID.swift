import Foundation

/// Stable row identifier for a stored entity.
package struct EntityRowID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    package var rawValue: Int64

    package init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    package static func < (lhs: EntityRowID, rhs: EntityRowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
