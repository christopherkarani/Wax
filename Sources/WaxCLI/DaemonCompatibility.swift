import Foundation
import Wax

enum AgentDaemonPolicy {
    static func shouldUseDaemonForRemember(store: VectorStoreOptions) -> Bool {
        !store.directStore && !store.noEmbedder
    }

    static func shouldUseDaemonForRecall(store: VectorStoreOptions) -> Bool {
        !store.directStore && !store.noEmbedder
    }

    static func shouldUseDaemonForSearch(store: VectorStoreOptions, mode: String) -> Bool {
        !store.directStore && !store.noEmbedder && mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "hybrid"
    }
}

enum AgentDaemonTransport {
    static func configuration(
        storePath: String,
        embedderChoice: EmbedderChoice,
        cliPathOverride: String? = nil
    ) throws -> AgentBrokerConfiguration {
        let brokerExecutable: String
        if let cliPathOverride {
            brokerExecutable = cliPathOverride
        } else {
            let executablePath = try Pathing.resolveSelfExecutablePath()
            brokerExecutable = AgentBrokerPathing.resolveBrokerCLIPath(currentExecutablePath: executablePath)
        }
        return try AgentBrokerPathing.configuration(
            brokerExecutablePath: brokerExecutable,
            storePath: storePath,
            embedderChoice: embedderChoice.rawValue,
            noEmbedder: false
        )
    }
}

struct CLIDaemonRequest: Sendable {
    let id: String?
    let command: String
    let content: String?
    let query: String?
    let metadata: [String: String]?
    let mode: String?
    let topK: Int?
    let limit: Int?
}

struct CLIDaemonResultItem: Sendable {
    let frameId: Int64?
    let score: Double?
    let preview: String?
    let text: String?
}

enum CLIDaemonPayload: Sendable {
    case remember(frameCount: Int, pendingFrames: Int, framesAdded: Int)
    case search(count: Int, items: [CLIDaemonResultItem])
    case recall(query: String, totalTokens: Int, items: [CLIDaemonResultItem])
    case shutdown
}

struct CLIDaemonResponse: Sendable {
    let id: String?
    let ok: Bool
    let payload: CLIDaemonPayload?
    let error: String?
    let shouldExit: Bool
}

actor CLIDaemonSession {
    private let memory: MemoryOrchestrator

    init(memory: MemoryOrchestrator) {
        self.memory = memory
    }

    func handle(_ request: CLIDaemonRequest) async -> CLIDaemonResponse {
        do {
            switch request.command {
            case "remember":
                return try await remember(request)
            case "search":
                return try await search(request)
            case "recall":
                return try await recall(request)
            case "shutdown":
                return CLIDaemonResponse(
                    id: request.id,
                    ok: true,
                    payload: .shutdown,
                    error: nil,
                    shouldExit: true
                )
            default:
                return CLIDaemonResponse(
                    id: request.id,
                    ok: false,
                    payload: nil,
                    error: "Unknown command '\(request.command)'",
                    shouldExit: false
                )
            }
        } catch {
            return CLIDaemonResponse(
                id: request.id,
                ok: false,
                payload: nil,
                error: error.localizedDescription,
                shouldExit: false
            )
        }
    }
}

private extension CLIDaemonSession {
    func remember(_ request: CLIDaemonRequest) async throws -> CLIDaemonResponse {
        let content = request.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else {
            throw CLIError("Content must not be empty")
        }

        let before = await memory.runtimeStats()
        try await memory.remember(content, metadata: request.metadata ?? [:])
        try await memory.flush()
        let after = await memory.runtimeStats()
        let totalBefore = before.frameCount + before.pendingFrames
        let totalAfter = after.frameCount + after.pendingFrames
        let added = totalAfter >= totalBefore ? Int(totalAfter - totalBefore) : 0

        return CLIDaemonResponse(
            id: request.id,
            ok: true,
            payload: .remember(
                frameCount: Int(after.frameCount),
                pendingFrames: Int(after.pendingFrames),
                framesAdded: added
            ),
            error: nil,
            shouldExit: false
        )
    }

    func search(_ request: CLIDaemonRequest) async throws -> CLIDaemonResponse {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw CLIError("Query must not be empty")
        }

        let modeString = request.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "text"
        let mode: MemoryOrchestrator.DirectSearchMode
        switch modeString {
        case "text":
            mode = .text
        case "vector":
            mode = .vector
        case "hybrid":
            mode = .hybrid(alpha: 0.5)
        default:
            throw CLIError("mode must be one of: text, vector, hybrid")
        }

        let topK = request.topK ?? 10
        let hits = try await memory.search(query: query, mode: mode, topK: topK, frameFilter: nil)
        let items = hits.map {
            CLIDaemonResultItem(
                frameId: Int64($0.frameId),
                score: Double($0.score),
                preview: $0.previewText,
                text: nil
            )
        }

        return CLIDaemonResponse(
            id: request.id,
            ok: true,
            payload: .search(count: items.count, items: items),
            error: nil,
            shouldExit: false
        )
    }

    func recall(_ request: CLIDaemonRequest) async throws -> CLIDaemonResponse {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw CLIError("Query must not be empty")
        }

        let limit = request.limit ?? 5
        let context = try await memory.recall(query: query, frameFilter: nil)
        let selected = Array(context.items.prefix(limit))
        let items = selected.map {
            CLIDaemonResultItem(
                frameId: Int64($0.frameId),
                score: Double($0.score),
                preview: nil,
                text: $0.text
            )
        }

        return CLIDaemonResponse(
            id: request.id,
            ok: true,
            payload: .recall(
                query: context.query,
                totalTokens: context.totalTokens,
                items: items
            ),
            error: nil,
            shouldExit: false
        )
    }
}
