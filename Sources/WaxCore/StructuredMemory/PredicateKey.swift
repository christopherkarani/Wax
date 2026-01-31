import Foundation

/// Open-world predicate identifier for structured memory.
public struct PredicateKey: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
