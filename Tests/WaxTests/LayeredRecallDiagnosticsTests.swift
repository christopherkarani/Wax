import Foundation
import Testing
@testable import Wax

private struct LaneDiagnosticsEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "LaneDiagnosticsTests", model: "deterministic", dimensions: 4, normalized: true
    )
    func embed(_ text: String) async throws -> [Float] { [1, 0, 0, 0] }
}

@Suite
struct LayeredRecallDiagnosticsTests {
    private func withLanes(
        workingVectorEnabled: Bool,
        _ body: (LayeredRecall.Stores, UUID) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-lane-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeMemory(_ name: String, vector: Bool) async throws -> MemoryOrchestrator {
            var config = OrchestratorConfig.default
            config.enableVectorSearch = vector
            config.enableStructuredMemory = false
            return try await MemoryOrchestrator(
                at: root.appendingPathComponent(name + ".wax"),
                config: config,
                embedder: vector ? LaneDiagnosticsEmbedder() : nil
            )
        }
        let working = try await makeMemory("working", vector: workingVectorEnabled)
        do {
            let durable = try await makeMemory("durable", vector: !workingVectorEnabled)
            do {
                try await working.remember("Memory reliability working investigation")
                try await durable.remember("Memory reliability durable decision")
                try await working.flush()
                try await durable.flush()
                let id = UUID()
                let stores = LayeredRecall.Stores(
                    longTermMemory: durable,
                    workingLane: { requested in
                        guard requested == id else { return nil }
                        return .init(sessionID: id, agentID: nil, runID: nil,
                                     updatedAtMs: 0, project: nil, repo: nil, memory: working)
                    },
                    inferWriteScope: { _, _ in .init(project: nil, repo: nil) },
                    preview: { $0 ?? "" },
                    canonicalFrameID: { frameID, _ in frameID },
                    endedSessions: InMemoryEndedSessionStore()
                )
                try await body(stores, id)
                try await durable.close()
            } catch {
                try? await durable.close()
                throw error
            }
            try await working.close()
        } catch {
            try? await working.close()
            throw error
        }
    }

    @Test(arguments: [true, false])
    func mixedLanesReportBothRetrievalOutcomes(workingVectorEnabled: Bool) async throws {
        try await withLanes(workingVectorEnabled: workingVectorEnabled) { stores, id in
            let result = try await LayeredRecall.recall(request: .init(
                query: "memory reliability", scope: .global, limit: 8, searchTopK: 8,
                mode: .hybrid(), sessionID: id
            ), stores: stores)
            #expect(result.hits.contains { $0.text.contains("working investigation") })
            #expect(result.hits.contains { $0.text.contains("durable decision") })
            #expect(result.effectiveModeSummary == "mixed")
            #expect(result.queryEmbeddingState == "mixed")
        }
    }

    @Test func sessionScopeDoesNotReportUnqueriedDurableDegradation() async throws {
        try await withLanes(workingVectorEnabled: true) { stores, id in
            let result = try await LayeredRecall.recall(request: .init(
                query: "memory reliability", scope: .session, limit: 8, searchTopK: 8,
                mode: .hybrid(), sessionID: id
            ), stores: stores)
            #expect(result.effectiveModeSummary == "hybrid(alpha=0.500)")
            #expect(result.queryEmbeddingState == "available")
        }
    }
}
