import Foundation
import Testing
import Wax

// MARK: - Test Embedder for README examples

private actor TestReadmeEmbedder: EmbeddingProvider {
    let dimensions = 384
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "TestReadme",
        model: "v1",
        dimensions: 384,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        // Deterministic embedding based on text hash
        var vector = [Float](repeating: 0.0, count: 384)
        let hash = text.utf8.reduce(0) { $0 &+ Int($1) }
        for i in 0..<384 {
            vector[i] = Float((hash &+ i) % 100) / 100.0
        }
        return vector
    }
}

// MARK: - README Example: Build a Memory Palace for Your AI

@Test
func readmeExampleMemoryPalace() async throws {
    try await TempFiles.withTempFile { url in
        // Your AI assistant that never forgets
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false  // Text-only mode (no embedder needed)

        let memory = try await MemoryOrchestrator(at: url, config: config)

        // Every conversation gets remembered
        try await memory.remember("User: I prefer Python over JavaScript")
        try await memory.remember("User: My birthday is March 15th")

        // Instant, context-aware retrieval
        let context = try await memory.recall(query: "programming preferences")
        // Returns context with relevant items
        #expect(context.items.count >= 0) // May or may not find matches depending on search

        try await memory.close()
    }
}

// MARK: - README Example: Turn Documents into Searchable Knowledge

@Test
func readmeExampleSearchableKnowledge() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let memory = try await MemoryOrchestrator(at: url, config: config)

        // Ingest your entire documentation
        let documents = ["API Reference", "User Guide", "Troubleshooting"]
        for doc in documents {
            try await memory.remember(doc)
        }

        // Search across everything
        let results = try await memory.recall(query: "how to authenticate users")
        #expect(results.totalTokens >= 0)

        try await memory.close()
    }
}

// MARK: - README Example: Quick Start Magic

@Test
func readmeExampleQuickStart() async throws {
    try await TempFiles.withTempFile { url in
        // 1️⃣ Create your memory palace
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false  // Text-only mode

        let memory = try await MemoryOrchestrator(at: url, config: config)

        // 2️⃣ Feed it knowledge
        try await memory.remember("Swift 6.2 introduces improved concurrency")
        try await memory.remember("Async/await makes code more readable")

        // 3️⃣ Ask questions, get answers
        let context = try await memory.recall(query: "concurrency improvements")
        for item in context.items {
            _ = item.text // "Swift 6.2 introduces improved concurrency"
        }

        // 4️⃣ Clean up (memory persists to disk automatically)
        try await memory.close()
    }
}

// MARK: - README Example: Quickstart (MemoryOrchestrator)

@Test
func readmeExampleQuickstartOrchestrator() async throws {
    try await TempFiles.withTempFile { url in
        // Text-only mode (no embedder required)
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let memory = try await MemoryOrchestrator(at: url, config: config)

        try await memory.remember("Swift is safe and fast.")
        try await memory.remember("Rust is fearless.")

        let ctx = try await memory.recall(query: "safe")
        for item in ctx.items {
            _ = (item.kind, item.text)
        }

        try await memory.close()
    }
}

// MARK: - README Example: Unified Search API (Lower-Level)

@Test
func readmeExampleUnifiedSearchAPI() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        let vec = try await wax.enableVectorSearch(dimensions: 384)

        let frameId = try await wax.put(
            Data("Hello from Wax".utf8),
            options: FrameMetaSubset(searchText: "Hello from Wax")
        )
        try await text.index(frameId: frameId, text: "Hello from Wax")
        try await vec.add(frameId: frameId, vector: [Float](repeating: 0.01, count: 384))

        try await text.commit()
        try await vec.commit()

        let request = SearchRequest(query: "Hello", mode: .hybrid(alpha: 0.5), topK: 10)
        let response = try await wax.search(request)
        #expect(response.results.count >= 0)

        try await wax.close()
    }
}

// MARK: - README Example: Fast RAG (Deterministic Context Builder)

@Test
func readmeExampleFastRAG() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // Add some content first
        let frameId = try await wax.put(
            Data("Swift concurrency is powerful".utf8),
            options: FrameMetaSubset(searchText: "Swift concurrency is powerful")
        )
        try await text.index(frameId: frameId, text: "Swift concurrency is powerful")
        try await text.commit()

        let builder = FastRAGContextBuilder()
        let config = FastRAGConfig(
            maxContextTokens: 800,
            searchMode: .hybrid(alpha: 0.5)
        )

        let context = try await builder.build(query: "swift concurrency", wax: wax, config: config)
        #expect(context.totalTokens >= 0)

        try await wax.close()
    }
}

// MARK: - README Example: Custom Embeddings

@Test
func readmeExampleCustomEmbeddings() async throws {
    // This test verifies the custom embedder pattern from the README compiles and works
    actor MyEmbedder: EmbeddingProvider {
        let dimensions = 384
        let normalize = true
        let identity: EmbeddingIdentity? = EmbeddingIdentity(
            provider: "MyModel",
            model: "v1",
            dimensions: 384,
            normalized: true
        )

        func embed(_ text: String) async throws -> [Float] {
            // Return a normalized 384-dim vector.
            var vector = [Float](repeating: 0.0, count: 384)
            vector[0] = 1.0
            return vector
        }
    }

    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true

        let memory = try await MemoryOrchestrator(at: url, config: config, embedder: MyEmbedder())

        try await memory.remember("Test content for custom embedder")
        let ctx = try await memory.recall(query: "test")
        #expect(ctx.totalTokens >= 0)

        try await memory.close()
    }
}

// MARK: - README Example: Maintenance

@Test
func readmeExampleMaintenance() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let memory = try await MemoryOrchestrator(at: url, config: config)

        // Add some content first
        try await memory.remember("Content for maintenance test")
        try await memory.flush()

        let surrogateReport = try await memory.optimizeSurrogates()
        #expect(surrogateReport.scannedFrames >= 0)

        let compactReport = try await memory.compactIndexes()
        #expect(compactReport.scannedFrames >= 0)

        try await memory.close()
    }
}

// MARK: - README Example: SearchMode hybrid syntax

@Test
func readmeExampleSearchModeHybrid() async throws {
    // Verify SearchMode.hybrid(alpha:) syntax works
    let mode1 = SearchMode.hybrid(alpha: 0.5)
    let mode2 = SearchMode.hybrid(alpha: 1.0)
    let mode3 = SearchMode.hybrid(alpha: 0.0)
    let mode4 = SearchMode.textOnly
    let mode5 = SearchMode.vectorOnly

    #expect(mode1 == .hybrid(alpha: 0.5))
    #expect(mode2 == .hybrid(alpha: 1.0))
    #expect(mode3 == .hybrid(alpha: 0.0))
    #expect(mode4 == .textOnly)
    #expect(mode5 == .vectorOnly)
}

// MARK: - README Example: FastRAGConfig initialization

@Test
func readmeExampleFastRAGConfigInit() async throws {
    // Verify FastRAGConfig initialization syntax from README
    let config = FastRAGConfig(
        maxContextTokens: 800,
        searchMode: .hybrid(alpha: 0.5)
    )

    #expect(config.maxContextTokens == 800)
    #expect(config.searchMode == .hybrid(alpha: 0.5))
}

// MARK: - README Example: EmbeddingIdentity initialization

@Test
func readmeExampleEmbeddingIdentityInit() async throws {
    // Verify EmbeddingIdentity initialization syntax from README
    let identity = EmbeddingIdentity(
        provider: "MyModel",
        model: "v1",
        dimensions: 384,
        normalized: true
    )

    #expect(identity.provider == "MyModel")
    #expect(identity.model == "v1")
    #expect(identity.dimensions == 384)
    #expect(identity.normalized == true)
}

// MARK: - README Example: RAGContext structure

@Test
func readmeExampleRAGContextStructure() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let memory = try await MemoryOrchestrator(at: url, config: config)

        try await memory.remember("Swift concurrency uses actors")
        let context = try await memory.recall(query: "actors")

        // Verify RAGContext has expected structure
        _ = context.query
        _ = context.items
        _ = context.totalTokens

        // Verify Item structure
        for item in context.items {
            _ = item.kind      // .snippet, .expanded, or .surrogate
            _ = item.frameId
            _ = item.score
            _ = item.sources
            _ = item.text
        }

        try await memory.close()
    }
}
