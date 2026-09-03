import Foundation
import Testing
@testable import Wax

private let brokerCwdScope = MemoryScopeContext(
    cwdPath: "/tmp/broker-cwd",
    repoName: "broker-cwd",
    projectName: "broker-cwd"
)

private func withRecallIdentityMemory<T>(
    defaultScopeContext: MemoryScopeContext = brokerCwdScope,
    _ body: (MemoryOrchestrator) async throws -> T
) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-recall-identity-" + UUID().uuidString)
        .appendingPathExtension("wax")
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    config.enableAccessStatsScoring = false
    config.rag.searchMode = .textOnly
    config.defaultScopeContext = defaultScopeContext

    let memory = try await MemoryOrchestrator(at: url, config: config)
    do {
        let result = try await body(memory)
        try await memory.close()
        try? FileManager.default.removeItem(at: url)
        return result
    } catch {
        try? await memory.close()
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

private func identityStores(memory: MemoryOrchestrator) -> LayeredRecall.Stores {
    LayeredRecall.Stores(
        longTermMemory: memory,
        workingLane: { _ in nil },
        inferWriteScope: { _, _ in LayeredRecall.Identity() },
        preview: { text in String((text ?? "").prefix(180)) },
        canonicalFrameID: { frameID, _ in frameID },
        endedManifests: { [] },
        searchEndedSession: { _, _, _, _ in [] },
        recallEndedSession: { _, _, _, _, _ in [] }
    )
}

@Suite("Recall identity ranking wire")
struct RecallIdentityRankingTests {
    @Test
    func recallExecutionTagsSameRepoFromRequestIdentityNotBrokerCwd() async throws {
        let token = "WAXRANKWIRE-REPO-\(UUID().uuidString.prefix(8))"
        let recallIdentity = MemoryScopeContext(
            cwdPath: "/tmp/other-cwd",
            repoName: "recall-repo",
            projectName: "recall-project"
        )
        try await withRecallIdentityMemory { memory in
            try await memory.remember(
                "Canonical \(token) ranking identity note.",
                metadata: [
                    MemoryMetadataKeys.project: "recall-project",
                    MemoryMetadataKeys.repo: "recall-repo",
                    MemoryMetadataKeys.type: MemoryType.note.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                ]
            )
            try await memory.flush()

            let execution = try await memory.recallExecution(
                query: token,
                mode: .textOnly,
                topK: 5,
                scopeContext: recallIdentity
            )
            let hit = try #require(execution.context.items.first { $0.text.contains(token) })
            #expect(hit.explanations.contains("same repo"))
            #expect(hit.explanations.contains("same project"))
        }
    }

    @Test
    func layeredRecallUsesIdentityForSameRepoNotBrokerCwd() async throws {
        let token = "WAXRANKWIRE-LANE-\(UUID().uuidString.prefix(8))"
        try await withRecallIdentityMemory { memory in
            try await memory.remember(
                "Canonical \(token) layered identity note.",
                metadata: [
                    MemoryMetadataKeys.project: "recall-project",
                    MemoryMetadataKeys.repo: "recall-repo",
                    MemoryMetadataKeys.type: MemoryType.note.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                ]
            )
            try await memory.flush()

            let result = try await LayeredRecall.recall(
                request: LayeredRecall.RecallRequest(
                    query: token,
                    scope: .project,
                    limit: 5,
                    searchTopK: 5,
                    mode: .textOnly,
                    explicitProject: "recall-project",
                    explicitRepo: "recall-repo"
                ),
                stores: identityStores(memory: memory)
            )
            let hit = try #require(result.hits.first { $0.text.contains(token) })
            #expect(hit.explanations.contains("same repo"))
            #expect(hit.explanations.contains("same project"))
            #expect(result.identity.repo == "recall-repo")
            #expect(result.identity.project == "recall-project")
        }
    }

    @Test
    func layeredRecallProjectScopeReportsScopeDroppedForLouderForeignHit() async throws {
        let token = "WAXRANKWIRE-DROP-\(UUID().uuidString.prefix(8))"
        try await withRecallIdentityMemory { memory in
            try await memory.remember(
                "\(token) swarmy operator note.",
                metadata: [
                    MemoryMetadataKeys.project: "Swarmy",
                    MemoryMetadataKeys.type: MemoryType.note.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                ]
            )
            try await memory.remember(
                "\(token) wax operator lessons wax operator lessons wax operator lessons.",
                metadata: [
                    MemoryMetadataKeys.project: "Wax",
                    MemoryMetadataKeys.repo: "Wax",
                    MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                    MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
                    MemoryMetadataKeys.confidence: "0.95",
                ]
            )
            try await memory.flush()

            let result = try await LayeredRecall.recall(
                request: LayeredRecall.RecallRequest(
                    query: "\(token) wax operator lessons",
                    scope: .project,
                    limit: 5,
                    searchTopK: 5,
                    mode: .textOnly,
                    explicitProject: "Swarmy"
                ),
                stores: identityStores(memory: memory)
            )

            #expect(result.projectMiss == false)
            #expect(result.hits.isEmpty == false)
            #expect(result.hits.allSatisfy { $0.metadata[MemoryMetadataKeys.project] == "Swarmy" })
            #expect(result.hits.contains { $0.metadata[MemoryMetadataKeys.project] == "Wax" } == false)
            #expect(result.scopeDropped.count >= 1)
            #expect(result.scopeDropped.top.contains { $0.project == "Wax" })
        }
    }
}
