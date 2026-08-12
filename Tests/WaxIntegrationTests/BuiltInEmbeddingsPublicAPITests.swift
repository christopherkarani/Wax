import Foundation
import Testing
import Wax

@Suite("BuiltInEmbeddingsPublicAPITests")
struct BuiltInEmbeddingsPublicAPITests {
@Test
func builtInEmbeddingsMiniLMProducesFiniteVectorAndHybridSearch() async throws {
    try await TempFiles.withTempFile { url in
        // Public defaults must work without callers hand-picking compute units.
        let embedder = try await BuiltInEmbeddings.make(.miniLM)
        let vector = try await embedder.embed("constellation hybrid CoreML")
        #expect(vector.count == embedder.dimensions)
        let allFinite = vector.allSatisfy { $0.isFinite }
        #expect(allFinite)
        #expect(vector.contains(where: { $0 != 0 }))

        let memory = try await Memory(
            at: url,
            config: .init(
                enableVectorSearch: true,
                requireOnDeviceProviders: true,
                embedding: .custom(embedder)
            )
        )
        try await memory.save(
            "Vector fact: the constellation project uses CoreML MiniLM embeddings for hybrid search."
        )
        try await memory.flush()
        let hybrid = try await memory.search(
            "constellation MiniLM",
            options: .init(topK: 3, mode: .hybrid(alpha: 0.4))
        )
        #expect(!hybrid.items.isEmpty)
        let joined = hybrid.items.map(\.text).joined(separator: "\n")
        #expect(
            joined.localizedCaseInsensitiveContains("constellation")
                || joined.localizedCaseInsensitiveContains("MiniLM")
        )
        try await memory.close()
    }
}

/// cpuOnly alone has produced non-finite MiniLM outputs on Apple Silicon; defaults must
/// fall through to a working unit (ANE preferred) rather than surface NaNs to callers.
@Test
func builtInEmbeddingsMiniLMDefaultsSkipBrokenCpuOnlyPath() async throws {
    // Using .default exercises the public compute-unit fallback order.
    let embedder = try await BuiltInEmbeddings.make(.miniLM, options: .default)
    let vector = try await embedder.embed("prefer neural engine over broken cpuOnly")
    #expect(vector.count == 384)
    #expect(vector.allSatisfy { $0.isFinite })
}
}
