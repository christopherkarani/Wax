import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTestSupport
import WaxVectorSearch

/// `Memory.Config.embedding = .automatic` gives a new store e5 and keeps an existing store on
/// the built-in that wrote it, so the e5 default never strands a MiniLM store.
private enum Identities {
    static func wax(_ model: String) -> EmbeddingIdentity {
        EmbeddingIdentity(provider: "Wax", model: model, dimensions: 384, normalized: true)
    }

    static let miniLM = wax("MiniLMAll-mean")
    static let e5 = wax("E5SmallV2-prefixed")
    static let arctic = wax("ArcticEmbedS")
    static let defaultBuild: [BuiltInEmbeddingProvider: EmbeddingIdentity] = [.miniLM: miniLM, .e5: e5]

    static func binding(_ identity: EmbeddingIdentity) -> MemoryBinding {
        MemoryBindingCompatibility.binding(from: identity)
    }
}

@Test func automaticGivesANewStoreE5() {
    let choice = AutomaticEmbedderChoice.provider(
        binding: nil,
        storeHasVectors: false,
        newStore: .e5,
        available: Identities.defaultBuild
    )
    #expect(choice == .e5)
}

@Test func automaticKeepsAMiniLMStoreOnMiniLM() {
    let choice = AutomaticEmbedderChoice.provider(
        binding: Identities.binding(Identities.miniLM),
        storeHasVectors: true,
        newStore: .e5,
        available: Identities.defaultBuild
    )
    #expect(choice == .miniLM)
}

@Test func automaticKeepsAStoreFromTheSupersededMiniLMOnMiniLMSoItReembeds() {
    // Stores written before mean pooling (#257) are bound to "MiniLMAll"; only MiniLM
    // re-embeds them in place.
    let choice = AutomaticEmbedderChoice.provider(
        binding: Identities.binding(Identities.wax("MiniLMAll")),
        storeHasVectors: true,
        newStore: .e5,
        available: Identities.defaultBuild
    )
    #expect(choice == .miniLM)
}

@Test func automaticKeepsAnE5StoreOnE5() {
    let choice = AutomaticEmbedderChoice.provider(
        binding: Identities.binding(Identities.e5),
        storeHasVectors: true,
        newStore: .e5,
        available: Identities.defaultBuild
    )
    #expect(choice == .e5)
}

@Test func automaticKeepsAnArcticStoreOnArcticWhenTheBuildHasIt() {
    var available = Identities.defaultBuild
    available[.arctic] = Identities.arctic
    let choice = AutomaticEmbedderChoice.provider(
        binding: Identities.binding(Identities.arctic),
        storeHasVectors: true,
        newStore: .e5,
        available: available
    )
    #expect(choice == .arctic)
}

@Test func automaticGivesAStoreWithUnboundVectorsMiniLM() {
    // Stores from before bindings were recorded hold MiniLM vectors of unknown revision.
    let choice = AutomaticEmbedderChoice.provider(
        binding: nil,
        storeHasVectors: true,
        newStore: .e5,
        available: Identities.defaultBuild
    )
    #expect(choice == .miniLM)
}

@Test func automaticNeverPairsUnboundVectorsWithE5() {
    // A build without MiniLM must report the store unavailable, not attach e5 to MiniLM vectors.
    let choice = AutomaticEmbedderChoice.provider(
        binding: nil,
        storeHasVectors: true,
        newStore: .e5,
        available: [.e5: Identities.e5]
    )
    #expect(choice == .miniLM)
}

@Test func automaticGivesAStoreBoundToACustomEmbedderTheDefault() {
    // No built-in matches, so the default loads and reports the mismatch as unavailable.
    let custom = EmbeddingIdentity(provider: "Acme", model: "acme-embed", dimensions: 384, normalized: true)
    let choice = AutomaticEmbedderChoice.provider(
        binding: Identities.binding(custom),
        storeHasVectors: true,
        newStore: .e5,
        available: Identities.defaultBuild
    )
    #expect(choice == .e5)
}

@Test func automaticChoosesMiniLMWhenNoBuiltInIsAvailable() {
    // Linux and older OS versions: MiniLM's compile reports unavailable, as before.
    let choice = AutomaticEmbedderChoice.provider(binding: nil, storeHasVectors: false, newStore: .e5, available: [:])
    #expect(choice == .miniLM)
}

@Test func automaticFallsBackToMiniLMWhenTheBuildHasNoE5() {
    let choice = AutomaticEmbedderChoice.provider(
        binding: nil,
        storeHasVectors: false,
        newStore: .e5,
        available: [.miniLM: Identities.miniLM]
    )
    #expect(choice == .miniLM)
}

#if MiniLMEmbeddings && E5Embeddings
@Test func memoryWithAutomaticEmbeddingGivesANewStoreE5() async throws {
    try await TempFiles.withTempFile { url in
        let vector = Array(repeating: Float(1 / 384.0.squareRoot()), count: 384)
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: EmbeddingReadiness(),
            readinessFactory: { ConstantEmbedder(vector: vector, identity: Identities.e5) }
        )
        #expect(await memory.automaticProviderForTesting == .e5)
        try await memory.close()
    }
}

@Test func automaticMiniLMOpenOfAnE5StoreLoadsE5() async throws {
    // The CLI and broker default to MiniLM; a store `Memory` wrote with e5 must still get
    // vector search there instead of going text-only.
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let vector = Array(repeating: Float(1 / 384.0.squareRoot()), count: 384)

        let writer = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: ConstantEmbedder(vector: vector, identity: Identities.e5)
        )
        try await writer.remember("a memory written by e5")
        try await writer.flush()
        try await writer.close()

        let reopened = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.miniLM, .default),
            readiness: EmbeddingReadiness()
        ) {
            ConstantEmbedder(vector: vector, identity: Identities.e5)
        }
        #expect(await reopened.automaticProvider == .e5)
        #expect(!(await reopened.config.fitsChunksToMiniLMInput))
        try await reopened.close()
    }
}

@Test func builtInBindingIdentitiesMatchTheEmbedders() {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let identities = BuiltInEmbeddingCompiler.bindingIdentities()
    #expect(identities[.miniLM] == Identities.miniLM)
    #expect(identities[.e5] == Identities.e5)
}

@Test func automaticOpenLoadsE5ForANewStoreAndMiniLMForAMiniLMStore() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let vector = Array(repeating: Float(1 / 384.0.squareRoot()), count: 384)

        let fresh = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.e5, .default),
            readiness: EmbeddingReadiness()
        ) {
            ConstantEmbedder(vector: vector, identity: Identities.e5)
        }
        #expect(await fresh.automaticProvider == .e5)
        #expect(!(await fresh.config.fitsChunksToMiniLMInput))
        try await fresh.close()
    }

    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let vector = Array(repeating: Float(1 / 384.0.squareRoot()), count: 384)

        let writer = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: ConstantEmbedder(vector: vector, identity: Identities.miniLM)
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
            ConstantEmbedder(vector: vector, identity: Identities.miniLM)
        }
        #expect(await reopened.automaticProvider == .miniLM)
        #expect(await reopened.config.fitsChunksToMiniLMInput)
        try await reopened.waitUntilReadyForRemember()
        guard case .active = await reopened.runtimeStats().embeddingStatus else {
            Issue.record("a MiniLM store must reattach MiniLM, got \(await reopened.runtimeStats().embeddingStatus)")
            try await reopened.close()
            return
        }
        try await reopened.close()
    }
}
#endif
