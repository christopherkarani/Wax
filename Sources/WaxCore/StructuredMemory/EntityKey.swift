import Foundation

/// Open-world entity identifier for structured memory.
package struct EntityKey: RawRepresentable, Hashable, Codable, Sendable {
    package var rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}
