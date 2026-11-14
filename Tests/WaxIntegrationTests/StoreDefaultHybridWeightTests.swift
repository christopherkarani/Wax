import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTestSupport
import WaxVectorSearch

/// A hybrid search whose caller chose no text weight uses the store's default: 0.4 for a store
/// served by e5-small-v2, 0.5 otherwise. A weight the caller chose always wins.
///
/// Calls and expected values are bound to typed constants before `#expect`: overloaded calls and
/// untyped literals inside the macro are slow to type-check on the Swift 6.2 CI toolchain.
private enum Embedders {
    static let vector: [Float] = [1, 0]

    static func wax(_ model: String) -> ConstantEmbedder {
        ConstantEmbedder(vector: vector, provider: "Wax", model: model)
    }

    static let e5 = wax("E5SmallV2-prefixed")
    static let miniLM = wax("MiniLMAll-mean")
    static let custom = ConstantEmbedder(vector: vector, provider: "Test", model: "Deterministic")
}

private enum Weights {
    static let e5: Float = 0.4
    static let standard: Float = 0.5
    static let e5Mode: SearchMode = .hybrid(alpha: 0.4)
    static let standardMode: SearchMode = .hybrid(alpha: 0.5)
    static let unsetRequest: SearchModeRequest = .hybrid(alpha: nil)
    static let standardRequest: SearchModeRequest = .hybrid(alpha: 0.5)
}

private func withMemory(
    embeddedBy embedder: ConstantEmbedder,
    _ body: (Memory) async throws -> Void
) async throws {
    try await TempFiles.withTempFile { (url: URL) async throws -> Void in
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

private struct HybridWeights {
    let requested: SearchMode
    let effective: SearchMode
}

private func hybridWeights(_ results: Memory.Results) throws -> HybridWeights {
    let diagnostics: RAGContext.Diagnostics = try #require(results.diagnostics)
    return HybridWeights(requested: diagnostics.requestedMode, effective: diagnostics.effectiveMode)
}

private func search(_ memory: Memory, options: Memory.SearchOptions) async throws -> HybridWeights {
    let results: Memory.Results = try await memory.search("hybrid search", options: options)
    return try hybridWeights(results)
}

@Test func storeDefaultTextWeightFollowsTheEmbedderIdentity() {
    let noIdentity: EmbeddingIdentity? = nil
    let noProvider: BuiltInEmbeddingProvider? = nil
    let byIdentity: [Float] = [
        HybridTextWeight.storeDefault(for: Embedders.e5.identity),
        HybridTextWeight.storeDefault(for: Embedders.miniLM.identity),
        HybridTextWeight.storeDefault(for: Embedders.custom.identity),
        HybridTextWeight.storeDefault(for: noIdentity),
    ]
    #expect(byIdentity == [Weights.e5, Weights.standard, Weights.standard, Weights.standard])

    let providers: [BuiltInEmbeddingProvider?] = [.e5, .miniLM, .arctic, noProvider]
    let byProvider: [Float] = providers.map { (provider: BuiltInEmbeddingProvider?) -> Float in
        HybridTextWeight.storeDefault(for: provider)
    }
    #expect(byProvider == [Weights.e5, Weights.standard, Weights.standard, Weights.standard])
}

@Test func builtInE5IdentityGetsTheE5TextWeight() {
    // Ties the identity check to the identity the built-in e5 embedder records.
    guard let e5: EmbeddingIdentity = BuiltInEmbeddingCompiler.bindingIdentities()[.e5] else { return }
    let weight: Float = HybridTextWeight.storeDefault(for: e5)
    #expect(weight == Weights.e5)
}

@Test func searchOptionsLeaveTheWeightToTheStoreUntilTheCallerChoosesOne() {
    let unsetMode: SearchMode = Memory.SearchOptions().mode
    #expect(unsetMode == Weights.standardMode)

    let requests: [SearchModeRequest] = [
        Memory.SearchOptions.default.modeRequest,
        Memory.SearchOptions(topK: 3).modeRequest,
        Memory.SearchOptions(mode: .hybrid()).modeRequest,
        Memory.SearchOptions(mode: .hybrid(alpha: 0.5)).modeRequest,
        Memory.SearchOptions(mode: .textOnly).modeRequest,
    ]
    let expected: [SearchModeRequest] = [
        Weights.unsetRequest, Weights.unsetRequest, Weights.standardRequest, Weights.standardRequest, .textOnly,
    ]
    #expect(requests == expected)

    var assigned = Memory.SearchOptions()
    assigned.mode = .hybrid()
    let assignedRequest: SearchModeRequest = assigned.modeRequest
    #expect(assignedRequest == Weights.standardRequest)
    #expect(assigned != Memory.SearchOptions.default)
}

@Test func e5StoreSearchesAtTextWeightPointFourByDefault() async throws {
    try await withMemory(embeddedBy: Embedders.e5) { (memory: Memory) async throws -> Void in
        let byDefault: HybridWeights = try await search(memory, options: .default)
        #expect(byDefault.requested == Weights.e5Mode)
        #expect(byDefault.effective == Weights.e5Mode)
        let summary: String = byDefault.effective.diagnosticsSummary
        #expect(summary == "hybrid(alpha=0.400)")

        let configuredResults: Memory.Results = try await memory.search("hybrid search") { $0.topK = 3 }
        let configured: HybridWeights = try hybridWeights(configuredResults)
        #expect(configured.effective == Weights.e5Mode)

        let options = Memory.SearchOptions(topK: 2)
        let strategyResults: Memory.Results = try await memory.search("hybrid search", strategy: nil, options: options)
        let withStrategy: HybridWeights = try hybridWeights(strategyResults)
        #expect(withStrategy.effective == Weights.e5Mode)
    }
}

@Test func e5StoreKeepsAWeightTheCallerChose() async throws {
    try await withMemory(embeddedBy: Embedders.e5) { (memory: Memory) async throws -> Void in
        let explicitHalf: HybridWeights = try await search(memory, options: .init(mode: .hybrid(alpha: 0.5)))
        #expect(explicitHalf.requested == Weights.standardMode)
        #expect(explicitHalf.effective == Weights.standardMode)

        let explicitDefaultCase: HybridWeights = try await search(memory, options: .init(mode: .hybrid()))
        #expect(explicitDefaultCase.effective == Weights.standardMode)

        let assignedResults: Memory.Results = try await memory.search("hybrid search") { $0.mode = .hybrid() }
        let assigned: HybridWeights = try hybridWeights(assignedResults)
        #expect(assigned.effective == Weights.standardMode)

        let otherMode: SearchMode = .hybrid(alpha: 0.7)
        let other: HybridWeights = try await search(memory, options: .init(mode: otherMode))
        #expect(other.effective == otherMode)
    }
}

@Test(arguments: [Embedders.miniLM, Embedders.custom])
func otherStoresSearchAtTextWeightOneHalfByDefault(embedder: ConstantEmbedder) async throws {
    try await withMemory(embeddedBy: embedder) { (memory: Memory) async throws -> Void in
        let byDefault: HybridWeights = try await search(memory, options: .default)
        #expect(byDefault.requested == Weights.standardMode)
        #expect(byDefault.effective == Weights.standardMode)
    }
}

@Test func orchestratorRequestsWithoutAWeightUseTheStoreDefault() async throws {
    try await TempFiles.withTempFile { (url: URL) async throws -> Void in
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: .default,
            embedder: Embedders.e5
        )
        try await orchestrator.remember("Wax hybrid search weighs text against vectors.")
        try await orchestrator.flush()

        // No mode at all (broker / MCP recall without mode or alpha).
        let noMode: SearchModeRequest? = nil
        let unset = try await orchestrator.recallExecution(query: "hybrid search", mode: noMode)
        let unsetEffective: SearchMode = unset.diagnostics.effectiveMode
        #expect(unsetEffective == Weights.e5Mode)

        // mode=hybrid without alpha.
        let hybridNoWeight = try await orchestrator.recallExecution(query: "hybrid search", mode: Weights.unsetRequest)
        let noWeightRequested: SearchMode = hybridNoWeight.diagnostics.requestedMode
        let noWeightEffective: SearchMode = hybridNoWeight.diagnostics.effectiveMode
        #expect(noWeightRequested == Weights.e5Mode)
        #expect(noWeightEffective == Weights.e5Mode)

        let chosen = try await orchestrator.recallExecution(query: "hybrid search", mode: Weights.standardRequest)
        let chosenEffective: SearchMode = chosen.diagnostics.effectiveMode
        #expect(chosenEffective == Weights.standardMode)

        let search = try await orchestrator.searchExecution(query: "hybrid search", mode: Weights.unsetRequest)
        let searchEffective: SearchMode = search.diagnostics.effectiveMode
        #expect(searchEffective == Weights.e5Mode)

        let chosenRequest: SearchModeRequest = .hybrid(alpha: 0.6)
        let searchChosen = try await orchestrator.searchExecution(query: "hybrid search", mode: chosenRequest)
        let searchChosenEffective: SearchMode = searchChosen.diagnostics.effectiveMode
        let chosenMode: SearchMode = .hybrid(alpha: 0.6)
        #expect(searchChosenEffective == chosenMode)

        try await orchestrator.close()
    }
}

@Test func memoryToolConfigLeavesTheWeightToTheStoreUnlessSet() async throws {
    let unset: SearchModeRequest = WaxMemoryToolConfig().searchOptions().modeRequest
    let perCall: SearchModeRequest = WaxMemoryToolConfig().searchOptions(alpha: 0.5).modeRequest
    let configured: SearchModeRequest = WaxMemoryToolConfig(searchAlpha: 0.5).searchOptions().modeRequest
    let reportedAlpha: Float = WaxMemoryToolConfig().searchAlpha
    #expect(unset == Weights.unsetRequest)
    #expect(perCall == Weights.standardRequest)
    #expect(configured == Weights.standardRequest)
    #expect(reportedAlpha == Weights.standard)

    var assigned = WaxMemoryToolConfig()
    assigned.searchAlpha = 0.3
    let assignedRequest: SearchModeRequest = assigned.searchOptions().modeRequest
    let expectedAssigned: SearchModeRequest = .hybrid(alpha: 0.3)
    #expect(assignedRequest == expectedAssigned)

    try await withMemory(embeddedBy: Embedders.e5) { (memory: Memory) async throws -> Void in
        let weights: HybridWeights = try await search(memory, options: WaxMemoryToolConfig().searchOptions())
        #expect(weights.effective == Weights.e5Mode)
    }
}

#if MiniLMEmbeddings && E5Embeddings
@Test func automaticStoresWeighByTheBuiltInServingThem() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let component: Float = 1 / Float(384).squareRoot()
    let vector: [Float] = Array(repeating: component, count: 384)
    let e5Identity = EmbeddingIdentity(provider: "Wax", model: "E5SmallV2-prefixed", dimensions: 384, normalized: true)
    let miniLMIdentity = EmbeddingIdentity(provider: "Wax", model: "MiniLMAll-mean", dimensions: 384, normalized: true)
    var config = OrchestratorConfig.default
    config.requireOnDeviceProviders = false

    try await TempFiles.withTempFile { (url: URL) async throws -> Void in
        let fresh = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.e5, .default),
            readiness: EmbeddingReadiness()
        ) {
            ConstantEmbedder(vector: vector, identity: e5Identity)
        }
        // Before and after the provider attaches, a new automatic store weighs text at 0.4.
        let beforeAttach: Float = await fresh.defaultHybridAlpha
        #expect(beforeAttach == Weights.e5)
        try await fresh.waitUntilReadyForRemember()
        let afterAttach: Float = await fresh.defaultHybridAlpha
        #expect(afterAttach == Weights.e5)
        try await fresh.close()
    }

    try await TempFiles.withTempFile { (url: URL) async throws -> Void in
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
        let provider: BuiltInEmbeddingProvider? = await reopened.automaticProvider
        #expect(provider == .miniLM)
        try await reopened.waitUntilReadyForRemember()
        let alpha: Float = await reopened.defaultHybridAlpha
        #expect(alpha == Weights.standard)
        let noMode: SearchModeRequest? = nil
        let execution = try await reopened.recallExecution(query: "memory", mode: noMode)
        let effective: SearchMode = execution.diagnostics.effectiveMode
        #expect(effective == Weights.standardMode)
        try await reopened.close()
    }
}
#endif
