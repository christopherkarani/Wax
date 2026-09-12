#if MCPServer
import Foundation
import Wax

enum MCPTeardownReason: String, Sendable, Equatable {
    case httpDelete
    case idleExpiry
    case shutdown
    case recoveryReplacement
    case stdioEOF
}

enum MCPTeardownPerformError: Error, Sendable {
    case brokerUnavailable
}

struct MCPTeardownOutcome: Sendable, Equatable {
    var status: String
    var reason: String
    var alreadyEnded: Bool
    var sessionID: String?

    static func skipped(_ reason: String) -> MCPTeardownOutcome {
        MCPTeardownOutcome(status: "skipped", reason: reason, alreadyEnded: false, sessionID: nil)
    }
}

enum MCPTransportTeardown {
    static let defaultTimeoutSeconds: TimeInterval = 2.0

    static func checkpointBoundTransportSession(
        connectionKey: String,
        reason: MCPTeardownReason,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) async -> MCPTeardownOutcome {
        // Close the coordinator first: an in-flight auto-session open must
        // observe .closed and refuse to bind before we snapshot the registry.
        if let coordinator = MCPAutoSessionCoordinatorStore.shared.current(for: connectionKey) {
            await coordinator.markClosed()
        }
        MCPAutoSessionCoordinatorStore.shared.remove(for: connectionKey)
        guard let sessionID = MCPBoundSessionRegistry.shared.current(for: connectionKey) else {
            return .skipped("no_bound_session")
        }

        let outcome = await closeExactly(
            sessionID: sessionID,
            reason: reason,
            perform: perform,
            timeoutSeconds: timeoutSeconds
        )
        MCPBoundSessionRegistry.shared.invalidate(sessionID: sessionID)
        return outcome
    }

    static func closeExactly(
        sessionID: String,
        reason: MCPTeardownReason,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) async -> MCPTeardownOutcome {
        enum Race: Sendable {
            case response(AgentBrokerResponse)
            case timeout
        }

        let winner = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                do {
                    let response = try await perform(
                        AgentBrokerRequest(
                            command: "session_close",
                            arguments: [
                                "session_id": .string(sessionID),
                                "content": .string("transport \(reason.rawValue)"),
                            ]
                        )
                    )
                    return .response(response)
                } catch {
                    return .timeout
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        let response: AgentBrokerResponse
        switch winner {
        case .timeout:
            return MCPTeardownOutcome(
                status: "timeout",
                reason: reason.rawValue,
                alreadyEnded: false,
                sessionID: sessionID
            )
        case .response(let value):
            response = value
        }

        switch response.outcome {
        case .success(let payload):
            let alreadyEnded = payload.objectValue?["already_ended"]?.boolValue == true
            return MCPTeardownOutcome(
                status: "closed",
                reason: reason.rawValue,
                alreadyEnded: alreadyEnded,
                sessionID: sessionID
            )
        case .failure(let payload, let message):
            let code = payload?.objectValue?["code"]?.stringValue ?? ""
            if ["session_ended", "session_unknown", "session_not_live"].contains(code) {
                return MCPTeardownOutcome(
                    status: "closed",
                    reason: reason.rawValue,
                    alreadyEnded: true,
                    sessionID: sessionID
                )
            }
            return MCPTeardownOutcome(
                status: "failed",
                reason: message,
                alreadyEnded: false,
                sessionID: sessionID
            )
        }
    }

    /// Best-effort teardown perform: probes an already-running broker with a
    /// short socket deadline. Never starts a broker process during teardown,
    /// so `timeoutSeconds` actually bounds the close attempt.
    static func boundedPerform(
        configuration: AgentBrokerConfiguration,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) -> @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse {
        { request in
            guard let response = try AgentBrokerClient.probe(
                request: request,
                configuration: configuration,
                timeoutSeconds: timeoutSeconds
            ) else {
                throw MCPTeardownPerformError.brokerUnavailable
            }
            return response
        }
    }

    static func makeHTTPCallback(
        configuration: AgentBrokerConfiguration
    ) -> @Sendable (String, MCPTeardownReason) async -> MCPTeardownOutcome {
        { connectionKey, reason in
            await checkpointBoundTransportSession(
                connectionKey: connectionKey,
                reason: reason,
                perform: boundedPerform(configuration: configuration)
            )
        }
    }
}

enum MCPHTTPConnectionContextRegistry {
    static let shared = Registry()

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var contexts: [String: MCPConnectionContext] = [:]

        func remember(sessionID: String, context: MCPConnectionContext) {
            lock.lock()
            defer { lock.unlock() }
            contexts[sessionID] = context
        }

        func current(sessionID: String) -> MCPConnectionContext? {
            lock.lock()
            defer { lock.unlock() }
            return contexts[sessionID]
        }

        func remove(sessionID: String) {
            lock.lock()
            defer { lock.unlock() }
            contexts.removeValue(forKey: sessionID)
        }

        func resetForTests() {
            lock.lock()
            defer { lock.unlock() }
            contexts.removeAll()
        }
    }
}
#endif
