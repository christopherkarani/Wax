import Foundation

package enum VersionRelation: UInt8, Sendable, Equatable, CaseIterable {
    case sets = 0
    case updates = 1
    case extends = 2
    case retracts = 3

    package var supersedes: Bool {
        switch self {
        case .updates, .retracts:
            return true
        case .sets, .extends:
            return false
        }
    }

    package var wireName: String {
        switch self {
        case .sets:
            return "sets"
        case .updates:
            return "updates"
        case .extends:
            return "extends"
        case .retracts:
            return "retracts"
        }
    }

    package init?(wireName: String) {
        let normalized = wireName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let match = Self.allCases.first(where: { $0.wireName == normalized }) else {
            return nil
        }
        self = match
    }
}
