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

/// Public Memory.search must return full short-frame content for every hit, not just the
/// expanded top hit. FTS snippet() truncates with `...` and highlight markers; consumers
/// need durable tokens from later saves after reopen to remain fully readable.
@Test
func memorySearchReturnsFullShortTextForSecondaryHitsAfterReopen() async throws {
    try await TempFiles.withTempFile { url in
        let config = Memory.Config(
            enableTextSearch: true,
            enableVectorSearch: false,
            requireOnDeviceProviders: false
        )

        // First session: seed an older similar fact.
        do {
            let memory = try await Memory(at: url, config: config)
            try await memory.save(
                "The user's preferred editor is Helix for WAX_STRESS_TOKEN_1_FIXEDTOKEN."
            )
            try await memory.flush()
            try await memory.close()
        }

        // Second session: save a near-duplicate with a different durable token, then search.
        let memory = try await Memory(at: url, config: config)
        try await memory.save(
            "The user's preferred editor is Helix for WAX_STRESS_TOKEN_2_FIXEDTOKEN."
        )

        let results = try await memory.search(
            "preferred editor Helix",
            options: .init(topK: 5, mode: .textOnly)
        )
        let joined = results.items.map(\.text).joined(separator: "\n")

        #expect(results.items.count >= 2)
        // Both full tokens must appear — truncated FTS snippets like "WAX_STRESS..." fail this.
        #expect(joined.contains("WAX_STRESS_TOKEN_1_FIXEDTOKEN"))
        #expect(joined.contains("WAX_STRESS_TOKEN_2_FIXEDTOKEN"))
        // Highlight-bracketed truncated previews are not acceptable for short frames.
        #expect(!joined.contains("WAX_STRESS..."))

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
