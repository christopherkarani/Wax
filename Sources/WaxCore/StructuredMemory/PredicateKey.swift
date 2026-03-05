import Foundation

/// Open-world predicate identifier for structured memory.
package struct PredicateKey: RawRepresentable, Hashable, Codable, Sendable {
    package var rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}
