import Foundation

/// Closed lock plan for one decoded broker command.
package enum BrokerAdmission: Sendable, Equatable {
    /// `commandMutex`, then `rememberMutex`. No embedder wait before those locks.
    case rememberDrain
    /// `rememberMutex` only.
    case remember
    /// Query-embedder wait outside `commandMutex`, then `commandMutex`.
    case embedderThenCommand
    /// `commandMutex` only. Also the lock for a failed decode.
    case command

    /// Remember-drain wins over an embedder wait. No current command is in both
    /// sets. If a future command were, drain skips the embedder wait so teardown
    /// does not sit behind a cold embedder load.
    package static func admission(for command: BrokerCommand) -> BrokerAdmission {
        if AgentBrokerService.requiresRememberDrain(command) {
            return .rememberDrain
        }
        switch command {
        case .remember:
            return .remember
        case .recall(let recall):
            if recall.mode == .textOnly {
                return .command
            }
            return .embedderThenCommand
        case .search(let search):
            if search.mode == .textOnly {
                return .command
            }
            return .embedderThenCommand
        case .sessionOpen(let open):
            let query = open.recallQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if query.isEmpty {
                return .command
            }
            return .embedderThenCommand
        default:
            return .command
        }
    }
}

extension AgentBrokerService {
    /// Invalid decode does not take the remember-drain lock.
    /// `handle` does not call this; it decodes once and then calls ``BrokerAdmission/admission(for:)``.
    package static func requiresRememberDrain(_ request: AgentBrokerRequest) -> Bool {
        guard let command = try? BrokerCommand.decode(
            command: request.command,
            arguments: request.arguments
        ) else {
            return false
        }
        return requiresRememberDrain(command)
    }
}
