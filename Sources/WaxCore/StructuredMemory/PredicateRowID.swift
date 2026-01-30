import Foundation

/// Stable row identifier for a stored predicate.
public struct PredicateRowID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public var rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PredicateRowID, rhs: PredicateRowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
