import Foundation

/// Stable row identifier for a stored structured fact.
public struct FactRowID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public var rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: FactRowID, rhs: FactRowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
