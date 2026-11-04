import Foundation
import Testing
@testable import Wax
import WaxTestSupport

struct RAGContextDiagnosticsTests {
    @Test
    func textFactoryNeverReportsVectorEffective() {
        let diagnostics = RAGContext.Diagnostics.text(
            requested: .hybrid(alpha: 0.5),
            embedding: .notRequested
        )
        #expect(diagnostics.requestedMode == .hybrid(alpha: 0.5))
        #expect(diagnostics.effectiveMode == .textOnly)
        #expect(diagnostics.queryEmbeddingState == .notRequested)
    }

    @Test
    func vectorFactoryImpliesAvailableEmbedding() {
        let diagnostics = RAGContext.Diagnostics.vector(
            requested: .hybrid(alpha: 0.25),
            effective: .hybrid(alpha: 0.25)
        )
        #expect(diagnostics.requestedMode == .hybrid(alpha: 0.25))
        #expect(diagnostics.effectiveMode == .hybrid(alpha: 0.25))
        #expect(diagnostics.queryEmbeddingState == .available)
    }

    @Test
    func vectorFactoryCoercesTextEffectiveToTextKind() {
        let diagnostics = RAGContext.Diagnostics.vector(
            requested: .vectorOnly,
            effective: .textOnly
        )
        #expect(diagnostics.effectiveMode == .textOnly)
        #expect(diagnostics.queryEmbeddingState == .available)
    }

    @Test
    func fastRAGHelperDegradesHybridWithoutEmbeddingToText() {
        let missing = FastRAGContextBuilder.diagnostics(
            requested: .hybrid(alpha: 0.5),
            embedding: nil,
            vectorSearchTimedOut: false
        )
        #expect(missing.requestedMode == .hybrid(alpha: 0.5))
        #expect(missing.effectiveMode == .textOnly)
        #expect(missing.queryEmbeddingState == .notRequested)

        let empty = FastRAGContextBuilder.diagnostics(
            requested: .hybrid(alpha: 0.5),
            embedding: [],
            vectorSearchTimedOut: false
        )
        #expect(empty.effectiveMode == .textOnly)
        #expect(empty.queryEmbeddingState == .notRequested)

        let timedOut = FastRAGContextBuilder.diagnostics(
            requested: .hybrid(alpha: 0.5),
            embedding: [1, 0],
            vectorSearchTimedOut: true
        )
        #expect(timedOut.effectiveMode == .textOnly)
        #expect(timedOut.queryEmbeddingState == .available)

        let hybridRan = FastRAGContextBuilder.diagnostics(
            requested: .hybrid(alpha: 0.5),
            embedding: [1, 0],
            vectorSearchTimedOut: false
        )
        #expect(hybridRan.effectiveMode == .hybrid(alpha: 0.5))
        #expect(hybridRan.queryEmbeddingState == .available)
    }

    @Test
    func mixedAndNAAreNotQueryEmbeddingStates() {
        #expect(RAGContext.QueryEmbeddingState(rawValue: "mixed") == nil)
        #expect(RAGContext.QueryEmbeddingState(rawValue: "n/a") == nil)
        #expect(RAGContext.QueryEmbeddingState(rawValue: "not_requested") == .notRequested)
    }

    @Test
    func publicDiagnosticsSourceRemovesUnconstrainedTripleInit() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Wax/RAG/RAGContext.swift"),
            encoding: .utf8
        )
        #expect(source.contains("@available(*, unavailable"))
        #expect(source.contains("hybrid/vector effective requires an embedding"))
        #expect(source.contains("private enum Kind"))
        #expect(!source.contains("self.requestedMode = requestedMode"))
        #expect(!source.contains("self.effectiveMode = effectiveMode"))
        #expect(!source.contains("self.queryEmbeddingState = queryEmbeddingState"))
    }

    @Test
    func retrievalDowngradeWarningUsesTypedDiagnosticsNotMagicMixedStrings() {
        let mixed = AgentBrokerService.retrievalDowngradeWarning(
            .mixed(requested: .hybrid(alpha: 0.5))
        )
        #expect(mixed?.contains("some memory stores") == true)
        #expect(mixed?.contains("embedder missing") == false)

        let timedOut = AgentBrokerService.retrievalDowngradeWarning(
            RAGContext.Diagnostics.text(requested: .hybrid(), embedding: .available)
        )
        #expect(timedOut?.contains("vector search") == true)
        #expect(timedOut?.contains("embedder missing") == false)

        let unavailable = AgentBrokerService.retrievalDowngradeWarning(.unavailable)
        #expect(unavailable == nil)

        #expect(
            AgentBrokerService.retrievalDowngradeWarning(
                RAGContext.Diagnostics.text(requested: .textOnly, embedding: .noEmbedder)
            ) == nil
        )
        #expect(
            AgentBrokerService.retrievalDowngradeWarning(
                RAGContext.Diagnostics.vector(requested: .hybrid(), effective: .hybrid())
            ) == nil
        )
    }

    @Test(arguments: [SearchMode.hybrid(), .vectorOnly])
    func emptyQueryRecallDoesNotClaimVectorEffectiveWithoutEmbedding(mode: SearchMode) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-empty-recall-\(UUID().uuidString).wax")
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableStructuredMemory = false
        let memory = try await MemoryOrchestrator(at: url, config: config, embedder: ConstantEmbedder(vector: [1, 0], provider: "EmptyQueryTests", model: "deterministic"))
        do {
            let recall = try await memory.recallExecution(query: "   ", mode: mode, topK: 5)
            #expect(recall.requestedMode == mode)
            #expect(recall.effectiveMode == .textOnly)
            #expect(recall.queryEmbeddingState == .notRequested)
            #expect(recall.context.diagnostics?.effectiveMode == .textOnly)

            let search = try await memory.searchExecution(query: "", mode: mode, topK: 5)
            #expect(search.requestedMode == mode)
            #expect(search.effectiveMode == .textOnly)
            #expect(search.queryEmbeddingState == .notRequested)
            try await memory.close()
            try? FileManager.default.removeItem(at: url)
        } catch {
            try? await memory.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
