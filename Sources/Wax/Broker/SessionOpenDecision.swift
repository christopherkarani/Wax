import Foundation

/// Pure open-policy for `session_open`: resume vs start-new from precomputed facts.
package enum SessionOpenDecision: Sendable {
    package struct Match: Sendable, Equatable {
        package var sessionID: UUID
        package var runID: String

        package init(sessionID: UUID, runID: String) {
            self.sessionID = sessionID
            self.runID = runID
        }
    }

    package struct Facts: Sendable, Equatable {
        package var conversationID: String?
        package var conversationMatch: Match?
        package var hintedSessionID: UUID?
        /// Exists, active, and no project conflict — shell already gates exact-pair / unique lease.
        package var hintedResumable: Bool
        package var priorUnique: Match?
        package var requestedRunID: String?

        package init(
            conversationID: String?,
            conversationMatch: Match?,
            hintedSessionID: UUID?,
            hintedResumable: Bool,
            priorUnique: Match?,
            requestedRunID: String?
        ) {
            self.conversationID = conversationID
            self.conversationMatch = conversationMatch
            self.hintedSessionID = hintedSessionID
            self.hintedResumable = hintedResumable
            self.priorUnique = priorUnique
            self.requestedRunID = requestedRunID
        }
    }

    package enum Action: Sendable, Equatable {
        case resume(sessionID: UUID)
        case startNew
    }

    /// Evaluate order matches current `sessionOpen` policy.
    package static func evaluate(_ facts: Facts) -> Action {
        if facts.conversationID != nil {
            if let match = facts.conversationMatch {
                return .resume(sessionID: match.sessionID)
            }
            // Explicit host conversation is an isolation boundary — ignore hints.
            return .startNew
        }
        if facts.hintedResumable, let hintedSessionID = facts.hintedSessionID {
            return .resume(sessionID: hintedSessionID)
        }
        return .startNew
    }
}
