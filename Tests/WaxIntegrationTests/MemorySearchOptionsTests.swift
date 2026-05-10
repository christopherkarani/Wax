import Foundation
import Testing
import Wax

@Test
func memorySearchOptionsExposeVectorOnlyAndHybridAlpha() async throws {
    var defaultOptions = Memory.SearchOptions.default
    defaultOptions.mode = .hybrid()

    let explicitHybrid = Memory.SearchOptions(mode: .hybrid(alpha: 0.25))
    let vectorOnly = Memory.SearchOptions(mode: .vectorOnly)

    #expect(defaultOptions.mode == .hybrid(alpha: 0.5))
    #expect(explicitHybrid.mode == .hybrid(alpha: 0.25))
    #expect(vectorOnly.mode == .vectorOnly)
}

@Test
func memoryFacadeRunsVectorOnlySearch() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(
            at: url,
            config: .init(enableTextSearch: false, enableVectorSearch: true),
            embedding: DeterministicEmbeddingProvider()
        )

        try await memory.save("Wax vector search should find this frame.", metadata: ["id": "needle"])
        try await memory.flush()

        let results = try await memory.search(
            "find the frame",
            options: .init(topK: 1, mode: .vectorOnly)
        )

        #expect(results.items.first?.metadata["id"] == "needle")
        #expect(results.items.first?.sources.contains(.vector) == true)

        try await memory.close()
    }
}

private struct DeterministicEmbeddingProvider: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        [1.0, 0.0]
    }
}
