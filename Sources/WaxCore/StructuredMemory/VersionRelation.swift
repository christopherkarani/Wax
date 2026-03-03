import Foundation

public enum VersionRelation: UInt8, Sendable, Equatable, CaseIterable {
    case sets = 0
    case updates = 1
    case extends = 2
    case retracts = 3

    public var supersedes: Bool {
        switch self {
        case .updates, .retracts:
            return true
        case .sets, .extends:
            return false
        }
    }
}
