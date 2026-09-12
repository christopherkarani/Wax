#if MCPServer
import Foundation
import MCP
import Wax

enum MCPAutoSessionError: Error, Sendable {
    case projectUnresolved(missing: [String])
    case openFailed(message: String, retryable: Bool)
}

struct MCPAutoSessionBinding: Sendable, Equatable {
    var sessionID: String
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

    func currentBinding() -> MCPAutoSessionBinding? {
        if case .bound(let binding) = state {
            return binding
        }
        return nil
    }

    func markClosed() {
        openingTask?.cancel()
        openingTask = nil
        state = .closed
    }

    func clearIfMatches(_ sessionID: String) {
        if case .bound(let binding) = state, binding.sessionID == sessionID {
            state = .unbound
        }
    }

    func resetForRetry() {
        if case .failed(_, let retryable) = state, retryable {
            state = .unbound
        }
        if case .closed = state {
            state = .unbound
        }
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
            switch await existing.value {
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
        switch result {
        case .success(let binding):
            // Bind before observing caller cancellation so a successful open is not orphaned.
            state = .bound(binding)
            return binding
        case .failure(let error):
            if let auto = error as? MCPAutoSessionError, case .openFailed(_, let retryable) = auto {
                state = .failed(message: autoErrorMessage(auto), retryable: retryable)
            } else {
                state = .failed(message: error.localizedDescription, retryable: true)
            }
            throw error
        }
    }

    private func autoErrorMessage(_ error: MCPAutoSessionError) -> String {
        switch error {
        case .projectUnresolved:
            return "project_unresolved"
        case .openFailed(let message, _):
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
            "agent_id": .string("mcp-auto"),
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
            guard let sessionID = payload.objectValue?["session_id"]?.stringValue, !sessionID.isEmpty else {
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
            throw MCPAutoSessionError.openFailed(message: message, retryable: true)
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
