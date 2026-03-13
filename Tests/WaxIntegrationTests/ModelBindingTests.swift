import Foundation
import Testing
import Wax

private struct BindingTestEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int
    let normalize: Bool
    let identity: EmbeddingIdentity?
    private let vector: [Float]

    init(
        provider: String,
        model: String,
        dimensions: Int = 4,
        normalized: Bool = true,
        vector: [Float]? = nil
    ) {
        self.dimensions = dimensions
        self.normalize = normalized
        self.identity = EmbeddingIdentity(
            provider: provider,
            model: model,
            dimensions: dimensions,
            normalized: normalized
        )
        self.vector = vector ?? Array(repeating: 0.25, count: dimensions)
    }

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return vector
    }
}

@Test func modelBindingIsPersistedOnFirstEmbeddingIngest() async throws {
    try await TempFiles.withTempFile { url in
        var config = TestHelpers.defaultMemoryConfig(vector: true)
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 0)
        let embedder = BindingTestEmbedder(provider: "Local", model: "v1", dimensions: 4, normalized: true)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)
        try await orchestrator.remember("Model binding persistence test.")
        try await orchestrator.flush()
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let binding = await wax.memoryBinding()
        #expect(binding?.embeddingProvider == "Local")
        #expect(binding?.embeddingModel == "v1")
        #expect(binding?.embeddingDimensions == 4)
        #expect(binding?.embeddingNormalized == true)
        try await wax.close()
    }
}

@Test func modelBindingMismatchFailsFastOnOpen() async throws {
    try await TempFiles.withTempFile { url in
        let writerEmbedder = BindingTestEmbedder(provider: "Local", model: "v1", dimensions: 4, normalized: true)
        let readerEmbedder = BindingTestEmbedder(provider: "Local", model: "v2", dimensions: 4, normalized: true)
        var config = TestHelpers.defaultMemoryConfig(vector: true)
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 0)

        let writer = try await MemoryOrchestrator(at: url, config: config, embedder: writerEmbedder)
        try await writer.remember("Persist vector data so binding is set.")
        try await writer.flush()
        try await writer.close()

        do {
            _ = try await MemoryOrchestrator(at: url, config: config, embedder: readerEmbedder)
            #expect(Bool(false))
        } catch let error as WaxError {
            if case .io(let reason) = error {
                #expect(reason.contains("memory binding"))
            } else {
                #expect(Bool(false))
            }
        } catch {
            #expect(Bool(false))
        }
    }
}

@Test func modelBindingBackwardCompatibleWhenStoreHasNoBinding() async throws {
    try await TempFiles.withTempFile { url in
        var noVector = TestHelpers.defaultMemoryConfig(vector: false)
        noVector.chunking = .tokenCount(targetTokens: 8, overlapTokens: 0)
        let textOnly = try await MemoryOrchestrator(at: url, config: noVector)
        try await textOnly.remember("Created without embeddings.")
        try await textOnly.flush()
        try await textOnly.close()

        var vectorConfig = TestHelpers.defaultMemoryConfig(vector: true)
        vectorConfig.chunking = .tokenCount(targetTokens: 8, overlapTokens: 0)
        let embedder = BindingTestEmbedder(provider: "Local", model: "compat-v1", dimensions: 4, normalized: true)

        let orchestrator = try await MemoryOrchestrator(at: url, config: vectorConfig, embedder: embedder)
        try await orchestrator.remember("First vector ingest after reopening.")
        try await orchestrator.flush()
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let binding = await wax.memoryBinding()
        #expect(binding?.embeddingModel == "compat-v1")
        try await wax.close()
    }
}
