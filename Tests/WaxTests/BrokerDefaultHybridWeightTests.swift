import Foundation
import Testing
@testable import Wax
import WaxTestSupport

/// Broker recall and search requests that name no hybrid weight use the long-term store's
/// default (0.4 for e5-small-v2); a request with `alpha` uses it.
private func withE5BrokerEnvironment<T>(
    _ body: (BrokerRecall.Environment) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-hybrid-weight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var config = OrchestratorConfig.default
    config.enableStructuredMemory = false
    let longTerm = try await MemoryOrchestrator(
        at: root.appendingPathComponent("durable.wax"),
        config: config,
        embedder: ConstantEmbedder(vector: [1, 0], provider: "Wax", model: "E5SmallV2-prefixed")
    )
    let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
    let sessions = VirtualSessionStore(
        sessionRootURL: sessionRoot,
        brokerInstanceID: UUID().uuidString,
        openExisting: { url, _ in
            var sessionConfig = OrchestratorConfig.default
            sessionConfig.enableVectorSearch = false
            sessionConfig.enableStructuredMemory = false
            return try await MemoryOrchestrator(at: url, config: sessionConfig)
        }
    )
    let ended = DiskEndedSessionStore(
        sessionRootURL: sessionRoot,
        noEmbedder: true,
        enableAccessStatsScoring: false,
        readiness: EmbeddingReadiness()
    )
    do {
        _ = try await longTerm.remember("Wax hybrid search weighs text against vectors.")
        try await longTerm.flush()
        let environment = BrokerRecall.Environment(
            longTermMemory: longTerm,
            sessions: sessions,
            endedSessions: ended,
            preview: { $0 ?? "" },
            canonicalFrameID: { frameID, _ in frameID },
            nowMs: { Int64(Date().timeIntervalSince1970 * 1000) }
        )
        let result = try await body(environment)
        await sessions.closeAll()
        try await longTerm.close()
        return result
    } catch {
        await sessions.closeAll()
        try? await longTerm.close()
        throw error
    }
}

private func recallModes(
    _ arguments: [String: AgentBrokerValue],
    in environment: BrokerRecall.Environment
) async throws -> (requested: String?, effective: String?) {
    let decoded = try BrokerCommand.decode(command: "recall", arguments: arguments)
    guard case .recall(let command) = decoded else {
        throw BrokerValidationError.invalid("expected recall command")
    }
    let payload = try await BrokerRecall.recall(command, in: environment).payload.objectValue
    return (payload?["requested_mode"]?.stringValue, payload?["effective_mode"]?.stringValue)
}

private func searchModes(
    _ arguments: [String: AgentBrokerValue],
    in environment: BrokerRecall.Environment
) async throws -> (requested: String?, effective: String?) {
    let decoded = try BrokerCommand.decode(command: "search", arguments: arguments)
    guard case .search(let command) = decoded else {
        throw BrokerValidationError.invalid("expected search command")
    }
    let payload = try await BrokerRecall.search(command, in: environment).payload.objectValue
    return (payload?["requested_mode"]?.stringValue, payload?["effective_mode"]?.stringValue)
}

@Test
func brokerRecallWithoutAlphaUsesTheE5StoreDefaultWeight() async throws {
    try await withE5BrokerEnvironment { environment in
        let query: AgentBrokerValue = .string("hybrid search")

        let unset = try await recallModes(["query": query], in: environment)
        #expect(unset.requested == "hybrid(alpha=0.400)")
        #expect(unset.effective == "hybrid(alpha=0.400)")

        let hybridOnly = try await recallModes(["query": query, "mode": .string("hybrid")], in: environment)
        #expect(hybridOnly.effective == "hybrid(alpha=0.400)")

        let chosen = try await recallModes(["query": query, "alpha": .double(0.5)], in: environment)
        #expect(chosen.requested == "hybrid(alpha=0.500)")
        #expect(chosen.effective == "hybrid(alpha=0.500)")

        let other = try await recallModes(
            ["query": query, "mode": .string("hybrid"), "alpha": .double(0.7)],
            in: environment
        )
        #expect(other.effective == "hybrid(alpha=0.700)")
    }
}

@Test
func brokerSearchWithoutAlphaUsesTheE5StoreDefaultWeight() async throws {
    try await withE5BrokerEnvironment { environment in
        let query: AgentBrokerValue = .string("hybrid search")

        let hybridOnly = try await searchModes(["query": query, "mode": .string("hybrid")], in: environment)
        #expect(hybridOnly.requested == "hybrid(alpha=0.400)")
        #expect(hybridOnly.effective == "hybrid(alpha=0.400)")

        let chosen = try await searchModes(
            ["query": query, "mode": .string("hybrid"), "alpha": .double(0.5)],
            in: environment
        )
        #expect(chosen.effective == "hybrid(alpha=0.500)")
    }
}
