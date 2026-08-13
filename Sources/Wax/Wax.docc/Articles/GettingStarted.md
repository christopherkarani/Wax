# Getting Started

Create a memory store, save text, and search it in minutes.

## Overview

Wax provides persistent, on-device memory with semantic search. The public entry point is ``Memory``, an actor that handles ingestion, chunking, embedding, indexing, and retrieval automatically.

## Add the Dependency

Add Wax to your `Package.swift`. This remediation ships as **0.2.0** because Tasks 8–12 remove or reshape public 0.x API.

Default (includes the MiniLM model bundle, approximately 43 MiB):

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.2.0"),
]
```

Traits-off (no built-in model; text-only unless you pass a custom ``EmbeddingProvider``):

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.2.0", traits: []),
]
```

Arctic opt-in (Snowflake Arctic Embed Small, approximately 32 MiB):

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.2.0", traits: ["ArcticEmbeddings"]),
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["Wax"]
)
```

| Consumer declaration | Built-in model | Approximate model bundle |
|----------------------|----------------|--------------------------|
| default (`MiniLMEmbeddings`) | all-MiniLM-L6-v2 | ~43 MiB |
| `traits: ["ArcticEmbeddings"]` | Snowflake Arctic Embed Small | ~32 MiB |
| `traits: []` | none | no built-in model; text-only unless you supply a custom provider |

GRDB, MetalANNS, swift-crypto, and swift-asn1 remain in the current core graph. SwiftNIO and the MCP SDK are pruned from ordinary Wax consumers — they belong to the `MCPServer` trait / `wax-mcp` product, not `import Wax`.

Wax builds for iOS 17/macOS 14 and later. The built-in MiniLM embedder requires iOS 18/macOS 15 and the default `MiniLMEmbeddings` package trait; Foundation Models tools require iOS 26/macOS 26.

## Create a Memory Store

```swift compile
import Foundation
import Wax

func gettingStartedOpenAutomatic() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    // Creates or opens the .wax file. On iOS 18/macOS 15+ the built-in MiniLM
    // embedder is wired automatically, so semantic search works out of the box.
    let memory = try await Memory(at: storeURL)
    try await memory.close()
}
```

To configure the built-in embedder explicitly (and fail loudly when it is unavailable):

```swift compile
import Foundation
import Wax

func gettingStartedOpenBuiltIn() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.embedding = .builtIn(.miniLM)
    }
    try await memory.close()
}
```

To bring your own embedding model, conform to ``EmbeddingProvider`` and select it on ``Memory/Config-swift.struct/embedding``. Use an input-dependent vector — never an all-zero embedding:

```swift compile
import Foundation
import Wax

actor DocsEmbedder: EmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "docs",
        model: "v1",
        dimensions: 4,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        text.localizedCaseInsensitiveContains("password")
            ? [1, 0, 0, 0]
            : [0, 1, 0, 0]
    }
}

func gettingStartedCustomEmbedderRanksIntendedMatchFirst() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    var config = Memory.Config.default
    config.embedding = .custom(DocsEmbedder())
    let memory = try await Memory(at: storeURL, config: config)

    try await memory.save("Password reset instructions are in account settings.")
    try await memory.save("The office snack drawer has trail mix.")

    let results = try await memory.search("recover password") { options in
        options.mode = .vectorOnly
        options.topK = 1
    }
    precondition(results.items.first?.text.contains("Password reset") == true)

    try await memory.close()
}
```

The store creates a new `.wax` file if one doesn't exist, or opens and recovers an existing one.

A default **new** public store reserves approximately 4 MiB of WAL plus committed data (logical size and allocated size are both in that neighborhood for an empty/small store). Stores created before the 4 MiB default may retain 256 MiB logical WAL regions. Close the ``Memory`` handle before any file-level copy or sync, and do not run concurrent writers on the same file across devices.

## Save Content

```swift compile
import Foundation
import Wax

func gettingStartedSave() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }
    try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
    try await memory.save("Team standup: discussed sprint velocity and blockers.")
    try await memory.close()
}
```

Behind the scenes, Wax:
1. Chunks the text according to the configured chunking strategy
2. Embeds each chunk when an embedding provider is configured
3. Indexes the text for BM25 full-text search
4. Writes frames and embeddings to the `.wax` file's write-ahead log

Call ``Memory/flush()`` to force pending writes to durable storage. ``Memory/close()`` flushes first — including an enrichment drain when ``Memory/EnrichmentPolicy/builtIn`` is set — then releases the store. If the drain times out, ``Memory/close()`` throws and the store remains open.

## Search

```swift compile
import Foundation
import Wax

func gettingStartedSearch() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }
    try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
    let results = try await memory.search("What did Alice say about the roadmap?")
    for item in results.items {
        print("[\(item.kind)] \(item.text)")
    }
    print("Total tokens: \(results.totalTokens)")
    try await memory.close()
}
```

The retrieval pipeline:
1. Classifies the query type (factual, semantic, temporal, exploratory)
2. Searches across BM25, vector, and structured memory lanes
3. Fuses results with reciprocal rank fusion (RRF)
4. Assembles context within the configured token budget

### Know which mode actually ran

Wax degrades to the text lane when the vector lane is unavailable (no embedder, unsupported OS, embedding timeout). Every search reports what actually happened via ``RAGContext/diagnostics``:

```swift compile
import Foundation
import Wax

func gettingStartedDiagnostics() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL)
    try await memory.save("Team standup: discussed sprint velocity and blockers.")
    let results = try await memory.search("roadmap")
    if let diagnostics = results.diagnostics {
        print("requested: \(diagnostics.requestedMode)")
        print("effective: \(diagnostics.effectiveMode)")
        print("embedding: \(diagnostics.queryEmbeddingState)")
    }
    try await memory.close()
}
```

For a store-level health snapshot, use ``Memory/stats()``:

```swift compile
import Foundation
import Wax

func gettingStartedStats() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL)
    let stats = await memory.stats()
    print(stats.vectorSearchEnabled)
    print(stats.queryEmbedderConfigured)
    print(stats.enrichment?.processedCount as Any)
    print(stats.enrichment?.pendingCount as Any)
    print(stats.enrichment?.isRunning as Any)
    try await memory.close()
}
```

## Retrieval Modes

Control the retrieval lanes per query via ``Memory/SearchOptions``:

```swift compile
import Foundation
import Wax

func gettingStartedRetrievalModes() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }
    try await memory.save("Team standup: discussed sprint velocity and blockers.")
    let textOnly = try await memory.search("sprint velocity", options: .init(mode: .textOnly))
    _ = textOnly.items
    try await memory.close()
}
```

Hybrid and vector-only modes require an embedding provider:

```swift compile
import Foundation
import Wax

func gettingStartedHybridSearch() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL)
    try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
    let semantic = try await memory.search("roadmap discussion", options: .init(mode: .vectorOnly))
    let hybrid = try await memory.search("Alice roadmap", options: .init(mode: .hybrid(alpha: 0.7)))
    _ = semantic.items
    _ = hybrid.items
    try await memory.close()
}
```

## Configuration

Customize behavior via ``Memory/Config-swift.struct``. Embedder selection lives on ``Memory/Config-swift.struct/embedding`` (see <doc:MigratingToMemoryConfigEmbedding>). Token budget and rerank knobs live on ``Memory/RAGConfig``; keyword/entity enrichment is ``Memory/EnrichmentPolicy``:

```swift compile
import Foundation
import Wax

func gettingStartedConfiguration() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.enableTextSearch = true
        config.enableVectorSearch = true
        config.enableStructuredMemory = false
        config.ingestConcurrency = 2
        config.ingestBatchSize = 32
        config.rag.maxContextTokens = 1_500
        config.rag.searchTopK = 24
        config.rag.answerRerankWindow = 12
        config.rag.answerDistractorPenalty = 0.30
        config.enrichment = .disabled
    }
    try await memory.close()
}
```

## Text-Only Mode

If you don't need vector search, disable it explicitly — no embedder is loaded:

```swift compile
import Foundation
import Wax

func gettingStartedTextOnly() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }
    try await memory.close()
}
```

This gives you BM25 full-text search without the embedding overhead.

## Clean Up

Always close the store when done:

```swift compile
import Foundation
import Wax

func gettingStartedClose() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }
    try await memory.close()
}
```

## Next

- Structured entities and facts: <doc:StructuredMemory>
- Photo and video memory: <doc:PhotoRAG>, <doc:VideoRAG>
- Foundation Models adapter: <doc:FoundationModels>
- Initializer migration: <doc:MigratingToMemoryConfigEmbedding>

## Using Wax with Claude Code

Wax ships with an MCP server that gives Claude Code persistent memory. Install and configure:

```bash
npx -y waxmcp@latest mcp install --scope user
```

That command registers the MCP server, stages the `wax-mcp` operator skill, and
prints a pasteable project-rules block. The server also embeds lifecycle
instructions on every tools connection.

Optional skill install if auto-registration did not run:

```bash
claude install-skill ~/.local/share/waxmcp/skills/wax-mcp
```

Or add the memory prompt to your `CLAUDE.md` / `AGENTS.md` — see the
[README](https://github.com/christopherkarani/Wax#agent-quick-start) and
`Resources/docs/wax-mcp-setup.md` for the recommended snippet.

### MCP Tools

| Tool | Purpose | Key Parameters |
|------|---------|----------------|
| `session_start` | Start a broker-managed virtual session and return `session_id` | none |
| `remember` | Store text and optional metadata | `content`, `session_id`, `metadata` |
| `recall` | Build assembled context for a query | `query`, `session_id`, `limit`, `mode`, `search_top_k` |
| `search` | Return ranked raw hits | `query`, `session_id`, `mode`, `topK`, `filters` |
| `corpus_search` | Search broker-managed session history with provenance | `query`, `rebuild`, `mode`, `topK` |
| `handoff` | Save session state for the next run | `content`, `session_id`, `project`, `pending_tasks` |
| `handoff_latest` | Load the latest handoff | `project` |
| `stats` | Runtime and storage stats | none |

### Agent Workflow

```
Session start      →  handoff_latest(project: "my-app"), then session_start()
During work        →  recall(query: "auth architecture", session_id: ...)
Save task memory   →  remember(content: "Auth uses session cookies", session_id: ...)
Cross-session look →  corpus_search(query: "previous auth migration", mode: "hybrid")
Session end        →  handoff(content: "Migrated auth to cookies", session_id: ..., project: "my-app"), then session_end(session_id: ...)
```

The MCP server now sits in front of a local broker. Agents should not manage
`SESSION_STORE`, `--store-path`, or `flush` in the normal workflow; the broker
owns the long-term store and virtual session stores.
