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
        /// Unique agent+project lease; used by `rebound`, not by `evaluate` (start owns rebind).
        package var priorUnique: Match?
        /// Requested run_id; used by `rebound`, not by `evaluate`.
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
    /// Unique agent+project rebind is intentionally *not* decided here — `startNew`
    /// lets `virtualSessions.start` stamp/rebind.
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

    /// Unique agent+project rebind or conversation resume with a different/omitted run_id.
    package static func rebound(returnedSessionID: UUID, facts: Facts) -> Bool {
        if let prior = facts.priorUnique, returnedSessionID == prior.sessionID {
            return facts.requestedRunID == nil || facts.requestedRunID != prior.runID
        }
        if let match = facts.conversationMatch, returnedSessionID == match.sessionID {
            return facts.requestedRunID == nil || facts.requestedRunID != match.runID
        }
        return false
    }
}
