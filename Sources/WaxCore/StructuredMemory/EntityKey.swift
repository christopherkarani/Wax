import Foundation

/// Open-world entity identifier for structured memory.
public struct EntityKey: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
