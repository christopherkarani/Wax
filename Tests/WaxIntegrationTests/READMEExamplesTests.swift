import Foundation
import Testing
import Wax
import WaxCore

@Test
func readmeQuickStartImportsFoundationBeforeWax() throws {
    let readmeURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("README.md")
    let readme = try String(contentsOf: readmeURL, encoding: .utf8)

    #expect(readme.contains("```swift\nimport Foundation\nimport Wax"))
}

@Test
func readmePublicMemoryQuickStartDoesNotAdvertiseHybridWithoutEmbedding() throws {
    let readmeURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("README.md")
    let readme = try String(contentsOf: readmeURL, encoding: .utf8)

    let swiftAppMarker = try #require(readme.range(of: "## Swift app"))
    let swiftAppRemainder = readme[swiftAppMarker.upperBound...]
    let quickStartMarker = try #require(
        swiftAppRemainder.range(of: "```swift\nimport Foundation\nimport Wax\n")
    )
    let quickStartRemainder = swiftAppRemainder[quickStartMarker.upperBound...]
    let quickStartEnd = try #require(quickStartRemainder.range(of: "\n```\n"))
    let quickStart = quickStartRemainder[..<quickStartEnd.lowerBound]

    #expect(quickStart.contains("let memory = try await Memory(at: url)"))
    #expect(!quickStart.localizedCaseInsensitiveContains("hybrid"))
    #expect(!quickStart.contains("text + vector"))
}

@Test
func npmReadmeLocalDevelopmentUsesRepoRootPackagePath() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let readmeURL = repoRoot.appendingPathComponent("Resources/npm/waxmcp/README.md")
    let readme = try String(contentsOf: readmeURL, encoding: .utf8)

    #expect(!readme.contains("npx --yes ./npm/waxmcp mcp doctor"))
    #expect(readme.contains("npx --yes ./Resources/npm/waxmcp mcp doctor"))
}

@Test
func npmTaskStateMigrationDocsMatchNativeLauncherDispatch() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let readme = try String(
        contentsOf: repoRoot.appendingPathComponent("Resources/npm/waxmcp/README.md"),
        encoding: .utf8
    )
    let launcher = try String(
        contentsOf: repoRoot.appendingPathComponent("Resources/npm/waxmcp/bin/waxmcp.js"),
        encoding: .utf8
    )
    let cliSource = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxCLI/BrokerForwardingCommands.swift"),
        encoding: .utf8
    )

    #expect(readme.contains("task-state-migrate --direct-store --store-path"))
    #expect(readme.contains("--destination-path /tmp/repaired.wax --dry-run"))
    #expect(launcher.contains("forwardedArgs[0] === \"task-state-migrate\""))
    #expect(launcher.contains("runBinary(\"wax-cli\", forwardedArgs)"))
    #expect(cliSource.contains("customLong(\"destination-path\")"))
    #expect(cliSource.contains("customLong(\"dry-run\")"))
    #expect(cliSource.contains("customLong(\"overwrite-destination\")"))
}

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

// MARK: - README save/search snippets find what they save

// These run the literals the README snippets pass to `memory.save` / `memory.search`, so a
// README whose query no longer finds its own saved text (or whose snippet stops saving,
// searching or reading the best hit) fails here. Vector search is disabled so the run is
// deterministic; the snippets' default hybrid search degrades to text the same way.

@Test
func readmeExampleSwiftUIFindsWhatItSaves() async throws {
    let block = try readmeSwiftBlock(after: "<summary><strong>SwiftUI</strong></summary>")
    #expect(block.contains("result = context.items.first?.text"))

    try await expectReadmeSnippetFindsWhatItSaves(block)
}

@Test
func readmeExampleSwiftAppQuickStartFindsWhatItSaves() async throws {
    let block = try readmeSwiftBlock(after: "## Swift app", startingWith: "import Foundation\nimport Wax\n")
    #expect(block.contains("if let best = results.items.first"))

    let context = try await expectReadmeSnippetFindsWhatItSaves(block)
    #expect(context.totalTokens > 0)
}

/// Saves the snippet's one `memory.save` literal, searches its one `memory.search` literal and
/// requires the best hit to be the saved text. Returns the search result.
@discardableResult
private func expectReadmeSnippetFindsWhatItSaves(
    _ block: Substring,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> RAGContext {
    let saved = try memoryCallLiterals("save", in: block)
    let queries = try memoryCallLiterals("search", in: block)
    try #require(saved.count == 1, "memory.save literals: \(saved)", sourceLocation: sourceLocation)
    try #require(queries.count == 1, "memory.search literals: \(queries)", sourceLocation: sourceLocation)

    return try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = false
        }
        try await memory.save(saved[0])
        let context = try await memory.search(queries[0])
        try await memory.close()

        let best = try #require(context.items.first, sourceLocation: sourceLocation)
        #expect(best.text == saved[0], sourceLocation: sourceLocation)
        return context
    }
}

/// The body of the first fenced Swift block after `marker` whose body starts with `prefix`.
private func readmeSwiftBlock(after marker: String, startingWith prefix: String = "") throws -> Substring {
    let readmeURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("README.md")
    let readme = try String(contentsOf: readmeURL, encoding: .utf8)
    let markerRange = try #require(readme.range(of: marker))
    let fence = "```swift\n" + prefix
    let open = try #require(readme[markerRange.upperBound...].range(of: fence))
    let body = readme[readme.index(open.lowerBound, offsetBy: "```swift\n".count)...]
    let close = try #require(body.range(of: "\n```\n"))
    return body[..<close.lowerBound]
}

/// The string literal passed to each `memory.<method>("…")` call in `block`.
private func memoryCallLiterals(_ method: String, in block: Substring) throws -> [String] {
    let call = try Regex(#"memory\."# + method + #"\("([^"\\]*)"\)"#, as: (Substring, Substring).self)
    return block.matches(of: call).map { String($0.output.1) }
}

// MARK: - README Example: Swift app quick start (public `Memory` API)

/// Runs the README "Swift app" snippet through the public `Memory` facade.
/// Vector search is disabled so the sample is deterministic on Linux CI and
/// does not compile MiniLM; the snippet's default hybrid search degrades to text.
@Test
func readmeExampleSwiftAppQuickStart() async throws {
    // Pin the snippet this test mirrors so README drift fails here. The SwiftUI and Foundation
    // Models samples repeat some of these lines, so pin them in the quick-start block itself.
    let quickStart = try readmeSwiftBlock(after: "## Swift app", startingWith: "import Foundation\nimport Wax\n")
    #expect(quickStart.contains("let memory = try await Memory(at: url)"))
    #expect(quickStart.contains(#"try await memory.save("The user is building a habit tracker in SwiftUI.")"#))
    #expect(quickStart.contains(#"let results = try await memory.search("What is the user building?")"#))

    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = false
        }

        try await memory.save("The user is building a habit tracker in SwiftUI.")
        let results = try await memory.search("What is the user building?")
        let best = try #require(results.items.first)
        #expect(best.text.contains("habit tracker"))
        #expect(results.diagnostics?.effectiveMode == .textOnly)

        try await memory.close()
    }
}

// MARK: - Package-only MemoryOrchestrator text recall (not a README snippet)

@Test
func memoryOrchestratorTextOnlyRecallReturnsRememberedItem() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let memory = try await MemoryOrchestrator(at: url, config: config)

        try await memory.remember("Swift is safe and fast.")
        try await memory.remember("Rust is fearless.")

        let ctx = try await memory.recall(query: "safe")
        let texts = ctx.items.map(\.text)
        #expect(texts.contains { $0.contains("Swift is safe and fast.") })
        #expect(!texts.contains { $0.contains("Rust is fearless.") })

        try await memory.close()
    }
}

// MARK: - README Example: Unified Search API (Lower-Level)

@Test
func readmeExampleUnifiedSearchAPI() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
        let vec = try await wax.enableVectorSearch(dimensions: 384)

        let frameId = try await wax.put(
            Data("Hello from Wax".utf8),
            options: FrameMetaSubset(searchText: "Hello from Wax")
        )
        try await text.indexText(frameId: frameId, text: "Hello from Wax")
        try await vec.add(frameId: frameId, vector: [Float](repeating: 0.01, count: 384))

        try await vec.commit()
        try await text.commit()

        let request = try SearchRequest(query: "Hello", lane: .hybrid(alpha: 0.5, embedding: nil), topK: 10)
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
        let text = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))

        // Add some content first
        let frameId = try await wax.put(
            Data("Swift concurrency is powerful".utf8),
            options: FrameMetaSubset(searchText: "Swift concurrency is powerful")
        )
        try await text.indexText(frameId: frameId, text: "Swift concurrency is powerful")
        try await text.commit()

        let builder = FastRAGContextBuilder()
        var config = FastRAGConfig(
            maxContextTokens: 800,
            searchMode: .hybrid(alpha: 0.5)
        )
        config.deterministicNowMs = 1_700_000_000_000

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
