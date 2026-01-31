import Foundation

/// Stable row identifier for a stored entity.
public struct EntityRowID: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public var rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: EntityRowID, rhs: EntityRowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
