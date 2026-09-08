import Foundation
import Testing
@testable import Wax

private func withCompactScopeMemory(
    _ body: (MemoryOrchestrator, LayeredRecall.Stores) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-compact-scope-\(UUID().uuidString).wax")
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    config.enableAccessStatsScoring = false
    config.rag.searchMode = .textOnly
    config.defaultScopeContext = MemoryScopeContext()
    let memory = try await MemoryOrchestrator(at: url, config: config)
    defer { try? FileManager.default.removeItem(at: url) }
    let stores = LayeredRecall.Stores(
        longTermMemory: memory,
        workingLane: { _ in nil },
        inferWriteScope: { _, _ in LayeredRecall.Identity() },
        preview: { String(($0 ?? "").prefix(180)) },
        canonicalFrameID: { frameID, _ in frameID },
        endedSessions: InMemoryEndedSessionStore()
    )
    do {
        try await body(memory, stores)
        try await memory.close()
    } catch {
        try? await memory.close()
        throw error
    }
}

@Suite("Compact scope retrieval")
struct CompactScopeRetrievalTests {
    @Test
    func foreignMatchesCannotCrowdOutProjectMemory() async throws {
        try await withCompactScopeMemory { memory, stores in
            try await memory.remember(
                "Cobalt belongs to the home project. " + String(repeating: "Additional background details. ", count: 40),
                metadata: [MemoryMetadataKeys.project: "home", MemoryMetadataKeys.type: "fact"]
            )
            for index in 0..<6 {
                try await memory.remember(
                    "Cobalt foreign project fact \(index).",
                    metadata: [MemoryMetadataKeys.project: "foreign", MemoryMetadataKeys.type: "fact"]
                )
            }
            try await memory.flush()

            let result = try await CompactAssembly.assemble(
                request: .init(
                    query: "Cobalt", sessionID: nil, mode: .textOnly,
                    tokenBudget: 10_000, maxItems: 4, explicitProject: "home"
                ),
                stores: stores,
                tokenizer: .character
            )
            #expect(result.long.contains { $0.text.contains("home project") })
            #expect(result.long.allSatisfy { $0.metadata[MemoryMetadataKeys.project] == "home" })
        }
    }

    @Test
    func namedProjectRequiresStampWhileGlobalIncludesUnstampedMemory() async throws {
        try await withCompactScopeMemory { memory, stores in
            try await memory.remember(
                "Cobalt named project fact.",
                metadata: [MemoryMetadataKeys.project: "home", MemoryMetadataKeys.type: "fact"]
            )
            try await memory.remember(
                "Cobalt unstamped personal fact.",
                metadata: [MemoryMetadataKeys.type: "fact"]
            )
            try await memory.flush()
            for scope: LayeredRecall.Scope in [.project, .global] {
                let result = try await CompactAssembly.assemble(
                    request: .init(
                        query: "Cobalt", sessionID: nil, mode: .textOnly,
                        tokenBudget: 10_000, maxItems: 4, scope: scope, explicitProject: "home"
                    ),
                    stores: stores,
                    tokenizer: .character
                )
                #expect(result.long.contains { $0.text.contains("named project") })
                #expect(result.long.contains { $0.text.contains("unstamped personal") } == (scope == .global))
            }
        }
    }
}
