import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTestSupport
import WaxVectorSearch

/// A hybrid search whose caller chose no text weight uses the store's default: 0.4 for a store
/// served by e5-small-v2, 0.5 otherwise. A weight the caller chose always wins.
private enum Embedders {
    static let vector: [Float] = [1, 0]

    static func wax(_ model: String) -> ConstantEmbedder {
        ConstantEmbedder(vector: vector, provider: "Wax", model: model)
    }

    static let e5 = wax("E5SmallV2-prefixed")
    static let miniLM = wax("MiniLMAll-mean")
    static let custom = ConstantEmbedder(vector: vector, provider: "Test", model: "Deterministic")
}

private func withMemory(
    embeddedBy embedder: ConstantEmbedder,
    _ body: (Memory) async throws -> Void
) async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(
            at: url,
            config: .init(enableTextSearch: true, enableVectorSearch: true, embedding: .custom(embedder))
        )
        try await memory.save("Wax hybrid search weighs text against vectors.")
        try await memory.flush()
        do {
            try await body(memory)
        } catch {
            try await memory.close()
            throw error
        }
        try await memory.close()
    }
}

private func hybridWeights(_ results: Memory.Results) throws -> (requested: SearchMode, effective: SearchMode) {
    let diagnostics = try #require(results.diagnostics)
    return (diagnostics.requestedMode, diagnostics.effectiveMode)
}

@Test func storeDefaultTextWeightFollowsTheEmbedderIdentity() {
    #expect(HybridTextWeight.storeDefault(for: Embedders.e5.identity) == 0.4)
    #expect(HybridTextWeight.storeDefault(for: Embedders.miniLM.identity) == 0.5)
    #expect(HybridTextWeight.storeDefault(for: Embedders.custom.identity) == 0.5)
    #expect(HybridTextWeight.storeDefault(for: nil as EmbeddingIdentity?) == 0.5)
    #expect(HybridTextWeight.storeDefault(for: .e5) == 0.4)
    #expect(HybridTextWeight.storeDefault(for: .miniLM) == 0.5)
    #expect(HybridTextWeight.storeDefault(for: .arctic) == 0.5)
    #expect(HybridTextWeight.storeDefault(for: nil as BuiltInEmbeddingProvider?) == 0.5)
}

@Test func builtInE5IdentityGetsTheE5TextWeight() {
    // Ties the identity check to the identity the built-in e5 embedder records.
    guard let e5 = BuiltInEmbeddingCompiler.bindingIdentities()[.e5] else { return }
    #expect(HybridTextWeight.storeDefault(for: e5) == 0.4)
}

@Test func searchOptionsLeaveTheWeightToTheStoreUntilTheCallerChoosesOne() {
    #expect(Memory.SearchOptions().mode == .hybrid(alpha: 0.5))
    #expect(Memory.SearchOptions.default.modeRequest == .hybrid(alpha: nil))
    #expect(Memory.SearchOptions(topK: 3).modeRequest == .hybrid(alpha: nil))
    #expect(Memory.SearchOptions(mode: .hybrid()).modeRequest == .hybrid(alpha: 0.5))
    #expect(Memory.SearchOptions(mode: .hybrid(alpha: 0.5)).modeRequest == .hybrid(alpha: 0.5))
    #expect(Memory.SearchOptions(mode: .textOnly).modeRequest == .textOnly)

    var assigned = Memory.SearchOptions()
    assigned.mode = .hybrid()
    #expect(assigned.modeRequest == .hybrid(alpha: 0.5))
    #expect(assigned != Memory.SearchOptions.default)
}

@Test func e5StoreSearchesAtTextWeightPointFourByDefault() async throws {
    try await withMemory(embeddedBy: Embedders.e5) { memory in
        let byDefault = try hybridWeights(try await memory.search("hybrid search"))
        #expect(byDefault.requested == .hybrid(alpha: 0.4))
        #expect(byDefault.effective == .hybrid(alpha: 0.4))
        #expect(byDefault.effective.diagnosticsSummary == "hybrid(alpha=0.400)")

        let configured = try hybridWeights(try await memory.search("hybrid search") { $0.topK = 3 })
        #expect(configured.effective == .hybrid(alpha: 0.4))

        let withStrategy = try hybridWeights(
            try await memory.search("hybrid search", strategy: nil, options: .init(topK: 2))
        )
        #expect(withStrategy.effective == .hybrid(alpha: 0.4))
    }
}

@Test func e5StoreKeepsAWeightTheCallerChose() async throws {
    try await withMemory(embeddedBy: Embedders.e5) { memory in
        let explicitHalf = try hybridWeights(
            try await memory.search("hybrid search", options: .init(mode: .hybrid(alpha: 0.5)))
        )
        #expect(explicitHalf.requested == .hybrid(alpha: 0.5))
        #expect(explicitHalf.effective == .hybrid(alpha: 0.5))

        let explicitDefaultCase = try hybridWeights(
            try await memory.search("hybrid search", options: .init(mode: .hybrid()))
        )
        #expect(explicitDefaultCase.effective == .hybrid(alpha: 0.5))

        let assigned = try hybridWeights(try await memory.search("hybrid search") { $0.mode = .hybrid() })
        #expect(assigned.effective == .hybrid(alpha: 0.5))

        let other = try hybridWeights(
            try await memory.search("hybrid search", options: .init(mode: .hybrid(alpha: 0.7)))
        )
        #expect(other.effective == .hybrid(alpha: 0.7))
    }
}

@Test(arguments: [Embedders.miniLM, Embedders.custom])
func otherStoresSearchAtTextWeightOneHalfByDefault(embedder: ConstantEmbedder) async throws {
    try await withMemory(embeddedBy: embedder) { memory in
        let byDefault = try hybridWeights(try await memory.search("hybrid search"))
        #expect(byDefault.requested == .hybrid(alpha: 0.5))
        #expect(byDefault.effective == .hybrid(alpha: 0.5))
    }
}

@Test func orchestratorRequestsWithoutAWeightUseTheStoreDefault() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: .default,
            embedder: Embedders.e5
        )
        try await orchestrator.remember("Wax hybrid search weighs text against vectors.")
        try await orchestrator.flush()

        // No mode at all (broker / MCP recall without mode or alpha).
        let unset = try await orchestrator.recallExecution(query: "hybrid search", mode: nil)
        #expect(unset.diagnostics.effectiveMode == .hybrid(alpha: 0.4))

        // mode=hybrid without alpha.
        let hybridNoWeight = try await orchestrator.recallExecution(
            query: "hybrid search",
            mode: .hybrid(alpha: nil)
        )
        #expect(hybridNoWeight.diagnostics.requestedMode == .hybrid(alpha: 0.4))
        #expect(hybridNoWeight.diagnostics.effectiveMode == .hybrid(alpha: 0.4))

        let chosen = try await orchestrator.recallExecution(query: "hybrid search", mode: .hybrid(alpha: 0.5))
        #expect(chosen.diagnostics.effectiveMode == .hybrid(alpha: 0.5))

        let search = try await orchestrator.searchExecution(query: "hybrid search", mode: .hybrid(alpha: nil))
        #expect(search.diagnostics.effectiveMode == .hybrid(alpha: 0.4))
        let searchChosen = try await orchestrator.searchExecution(query: "hybrid search", mode: .hybrid(alpha: 0.6))
        #expect(searchChosen.diagnostics.effectiveMode == .hybrid(alpha: 0.6))

        try await orchestrator.close()
    }
}

@Test func memoryToolConfigLeavesTheWeightToTheStoreUnlessSet() async throws {
    #expect(WaxMemoryToolConfig().searchOptions().modeRequest == .hybrid(alpha: nil))
    #expect(WaxMemoryToolConfig().searchOptions(alpha: 0.5).modeRequest == .hybrid(alpha: 0.5))
    #expect(WaxMemoryToolConfig(searchAlpha: 0.5).searchOptions().modeRequest == .hybrid(alpha: 0.5))
    #expect(WaxMemoryToolConfig().searchAlpha == 0.5)

    var assigned = WaxMemoryToolConfig()
    assigned.searchAlpha = 0.3
    #expect(assigned.searchOptions().modeRequest == .hybrid(alpha: 0.3))

    try await withMemory(embeddedBy: Embedders.e5) { memory in
        let results = try await memory.search("hybrid search", options: WaxMemoryToolConfig().searchOptions())
        #expect(try hybridWeights(results).effective == .hybrid(alpha: 0.4))
    }
}

#if MiniLMEmbeddings && E5Embeddings
@Test func automaticStoresWeighByTheBuiltInServingThem() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let vector = Array(repeating: Float(1 / 384.0.squareRoot()), count: 384)
    let e5Identity = EmbeddingIdentity(provider: "Wax", model: "E5SmallV2-prefixed", dimensions: 384, normalized: true)
    let miniLMIdentity = EmbeddingIdentity(provider: "Wax", model: "MiniLMAll-mean", dimensions: 384, normalized: true)
    var config = OrchestratorConfig.default
    config.requireOnDeviceProviders = false

    try await TempFiles.withTempFile { url in
        let fresh = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.e5, .default),
            readiness: EmbeddingReadiness()
        ) {
            ConstantEmbedder(vector: vector, identity: e5Identity)
        }
        // Before and after the provider attaches, a new automatic store weighs text at 0.4.
        #expect(await fresh.defaultHybridAlpha == 0.4)
        try await fresh.waitUntilReadyForRemember()
        #expect(await fresh.defaultHybridAlpha == 0.4)
        try await fresh.close()
    }

    try await TempFiles.withTempFile { url in
        let writer = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: ConstantEmbedder(vector: vector, identity: miniLMIdentity)
        )
        try await writer.remember("a memory written by MiniLM")
        try await writer.flush()
        try await writer.close()

        let reopened = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.e5, .default),
            readiness: EmbeddingReadiness()
        ) {
            ConstantEmbedder(vector: vector, identity: miniLMIdentity)
        }
        #expect(await reopened.automaticProvider == .miniLM)
        try await reopened.waitUntilReadyForRemember()
        #expect(await reopened.defaultHybridAlpha == 0.5)
        let execution = try await reopened.recallExecution(query: "memory", mode: nil)
        #expect(execution.diagnostics.effectiveMode == .hybrid(alpha: 0.5))
        try await reopened.close()
    }
}
#endif
