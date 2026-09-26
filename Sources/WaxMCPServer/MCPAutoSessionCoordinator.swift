#if MCPServer
import Foundation
import MCP
import Wax

enum MCPAutoSessionError: Error, Sendable {
    case projectUnresolved(missing: [String])
    case openFailed(message: String, retryable: Bool)
    case collisionResumeFailed(message: String, retryable: Bool, nextAction: String)
}

struct MCPAutoSessionBinding: Sendable, Equatable {
    var sessionID: UUID
    var ownership: MCPMemoryOwnership
    var conversationKey: String
}

actor MCPAutoSessionCoordinator {
    enum State: Sendable {
        case unbound
        case opening
        case bound(MCPAutoSessionBinding)
        case failed(message: String, retryable: Bool)
        case closed
    }

    private var state: State = .unbound
    private var openingTask: Task<Result<MCPAutoSessionBinding, Error>, Never>?

    /// Fixed auto-session identity. Resume-after-collision reuses these exact
    /// selectors so the colliding transport rebinds instead of failing.
    private static let autoAgentID = "mcp-auto"

    /// Broker pair-guard marker (see VirtualSessionStore). Matched with
    /// `contains` so minor broker rewording keeps the stable core detectable.
    private static let agentRunCollisionMarker = "already have an active session"

    private static let collisionResumeNextAction =
        "call session_resume with the same agent_id and run_id"

    func currentBinding() -> MCPAutoSessionBinding? {
        if case .bound(let binding) = state {
            return binding
        }
        return nil
    }

    /// Teardown marker. Sticky: a late finish of an in-flight open must not
    /// rebind a session the transport will never checkpoint.
    func markClosed() {
        openingTask?.cancel()
        openingTask = nil
        state = .closed
    }

    func ensureBound(
        transportKey: String,
        attribution: MCPProjectAttribution,
        context: MCPConnectionContext,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse
    ) async throws -> MCPAutoSessionBinding {
        if case .bound(let binding) = state {
            return binding
        }
        if case .closed = state {
            state = .unbound
        }
        if case .failed(_, let retryable) = state {
            if !retryable {
                throw MCPAutoSessionError.openFailed(message: "auto-session previously failed", retryable: false)
            }
            state = .unbound
        }

        if let existing = openingTask {
            let result = await existing.value
            if case .closed = state {
                if case .success(let binding) = result {
                    await Self.closeOrphanedSession(sessionID: binding.sessionID, perform: perform)
                }
                throw MCPAutoSessionError.openFailed(
                    message: "transport closed during auto-session open",
                    retryable: true
                )
            }
            switch result {
            case .success(let binding):
                return binding
            case .failure(let error):
                throw error
            }
        }

        let task = Task<Result<MCPAutoSessionBinding, Error>, Never> {
            do {
                return .success(
                    try await Self.openSession(
                        transportKey: transportKey,
                        attribution: attribution,
                        context: context,
                        perform: perform
                    )
                )
            } catch {
                return .failure(error)
            }
        }
        openingTask = task
        state = .opening
        let result = await task.value
        openingTask = nil
        if case .closed = state {
            // Teardown raced the open. Never bind the result; close the fresh
            // session best-effort so the broker does not keep an orphan.
            if case .success(let binding) = result {
                await Self.closeOrphanedSession(sessionID: binding.sessionID, perform: perform)
            }
            throw MCPAutoSessionError.openFailed(
                message: "transport closed during auto-session open",
                retryable: true
            )
        }
        switch result {
        case .success(let binding):
            // Bind before observing caller cancellation so a successful open is not orphaned.
            state = .bound(binding)
            return binding
        case .failure(let error):
            if let auto = error as? MCPAutoSessionError {
                switch auto {
                case .openFailed(_, let retryable), .collisionResumeFailed(_, let retryable, _):
                    state = .failed(message: autoErrorMessage(auto), retryable: retryable)
                case .projectUnresolved:
                    state = .failed(message: error.localizedDescription, retryable: true)
                }
            } else {
                state = .failed(message: error.localizedDescription, retryable: true)
            }
            throw error
        }
    }

    private static func closeOrphanedSession(
        sessionID: UUID,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse
    ) async {
        _ = try? await perform(
            AgentBrokerRequest(
                command: "session_close",
                arguments: [
                    "session_id": .string(sessionID.uuidString),
                    "content": .string("auto-session orphaned by transport teardown"),
                ]
            )
        )
    }

    private func autoErrorMessage(_ error: MCPAutoSessionError) -> String {
        switch error {
        case .projectUnresolved:
            return "project_unresolved"
        case .openFailed(let message, _):
            return message
        case .collisionResumeFailed(let message, _, _):
            return message
        }
    }

    private static func openSession(
        transportKey: String,
        attribution: MCPProjectAttribution,
        context: MCPConnectionContext,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse
    ) async throws -> MCPAutoSessionBinding {
        let ownership: MCPMemoryOwnership
        let conversationKey: String
        if let host = context.trustedHostConversation,
           context.clientIdentity.canOwnHostConversation,
           host.isUsable {
            ownership = .host
            conversationKey = host.wireConversationID
        } else {
            ownership = .transport
            conversationKey = MCPTransportKey(rawConnectionKey: transportKey).hashedConversationID
        }

        var arguments: [String: AgentBrokerValue] = [
            "conversation_id": .string(conversationKey),
            "agent_id": .string(Self.autoAgentID),
            "run_id": .string(transportKey),
        ]
        if let project = attribution.project {
            arguments["project"] = .string(project)
        }
        if let repo = attribution.repo {
            arguments["repo"] = .string(repo)
        }
        if let cwd = attribution.cwdPath {
            arguments["cwd"] = .string(cwd)
        }

        let response: AgentBrokerResponse
        do {
            response = try await perform(
                AgentBrokerRequest(command: "session_open", arguments: arguments)
            )
        } catch {
            throw MCPAutoSessionError.openFailed(message: error.localizedDescription, retryable: true)
        }

        switch response.outcome {
        case .success(let payload):
            guard let raw = payload.objectValue?["session_id"]?.stringValue,
                  let sessionID = UUID(uuidString: raw) else {
                throw MCPAutoSessionError.openFailed(
                    message: "session_open returned no session_id",
                    retryable: true
                )
            }
            return MCPAutoSessionBinding(
                sessionID: sessionID,
                ownership: ownership,
                conversationKey: conversationKey
            )
        case .failure(_, let message):
            if message.contains(Self.agentRunCollisionMarker) {
                return try await Self.resumeAfterCollision(
                    transportKey: transportKey,
                    ownership: ownership,
                    conversationKey: conversationKey,
                    openMessage: message,
                    perform: perform
                )
            }
            throw MCPAutoSessionError.openFailed(message: message, retryable: true)
        }
    }

    /// Rebind the winner of an agent/run pair collision. The broker keeps the
    /// pair guard (isolation), so the coordinator resumes explicitly with the
    /// same selectors instead of surfacing the collision.
    private static func resumeAfterCollision(
        transportKey: String,
        ownership: MCPMemoryOwnership,
        conversationKey: String,
        openMessage: String,
        perform: @escaping @Sendable (AgentBrokerRequest) async throws -> AgentBrokerResponse
    ) async throws -> MCPAutoSessionBinding {
        let response: AgentBrokerResponse
        do {
            response = try await perform(
                AgentBrokerRequest(
                    command: "session_resume",
                    arguments: [
                        "agent_id": .string(Self.autoAgentID),
                        "run_id": .string(transportKey),
                    ]
                )
            )
        } catch {
            throw MCPAutoSessionError.collisionResumeFailed(
                message: "auto-session collision (\(openMessage)); session_resume failed: \(error.localizedDescription)",
                retryable: true,
                nextAction: Self.collisionResumeNextAction
            )
        }
        switch response.outcome {
        case .success(let payload):
            guard let raw = payload.objectValue?["session_id"]?.stringValue,
                  let sessionID = UUID(uuidString: raw) else {
                throw MCPAutoSessionError.collisionResumeFailed(
                    message: "auto-session collision (\(openMessage)); session_resume returned no session_id",
                    retryable: true,
                    nextAction: Self.collisionResumeNextAction
                )
            }
            return MCPAutoSessionBinding(
                sessionID: sessionID,
                ownership: ownership,
                conversationKey: conversationKey
            )
        case .failure(_, let resumeMessage):
            throw MCPAutoSessionError.collisionResumeFailed(
                message: "auto-session collision (\(openMessage)); session_resume failed: \(resumeMessage)",
                retryable: true,
                nextAction: Self.collisionResumeNextAction
            )
        }
    }
}

final class MCPAutoSessionCoordinatorStore: @unchecked Sendable {
    static let shared = MCPAutoSessionCoordinatorStore()
    private let lock = NSLock()
    private var coordinators: [String: MCPAutoSessionCoordinator] = [:]

    func coordinator(for transportKey: String) -> MCPAutoSessionCoordinator {
        lock.lock()
        defer { lock.unlock() }
        if let existing = coordinators[transportKey] {
            return existing
        }
        let created = MCPAutoSessionCoordinator()
        coordinators[transportKey] = created
        return created
    }

    /// Non-creating lookup. Teardown uses this to mark an in-flight coordinator
    /// closed before the registry is read, so a late open cannot rebind.
    func current(for transportKey: String) -> MCPAutoSessionCoordinator? {
        lock.lock()
        defer { lock.unlock() }
        return coordinators[transportKey]
    }

    func remove(for transportKey: String) {
        lock.lock()
        defer { lock.unlock() }
        coordinators.removeValue(forKey: transportKey)
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        coordinators.removeAll()
    }
}
#endif
