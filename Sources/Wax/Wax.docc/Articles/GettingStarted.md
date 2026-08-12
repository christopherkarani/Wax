# Getting Started

Create a memory store, save text, and search it in minutes.

## Overview

Wax provides persistent, on-device memory with semantic search. The public entry point is ``Memory``, an actor that handles ingestion, chunking, embedding, indexing, and retrieval automatically.

## Add the Dependency

Add Wax to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8"),
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["Wax"]
)
```

Wax builds for iOS 17/macOS 14 and later. The built-in MiniLM embedder requires iOS 18/macOS 15 and the default `MiniLMEmbeddings` package trait; Foundation Models tools require iOS 26/macOS 26.

## Create a Memory Store

```swift
import Foundation
import Wax

// Creates or opens the .wax file. On iOS 18/macOS 15+ the built-in MiniLM
// embedder is wired automatically, so semantic search works out of the box.
let memory = try await Memory(at: URL(filePath: "memory.wax"))
```

To configure the built-in embedder explicitly (and fail loudly when it is unavailable):

```swift
let memory = try await Memory(at: URL(filePath: "memory.wax"), builtInEmbedding: .miniLM)
```

To bring your own embedding model, conform to `EmbeddingProvider` and pass it in:

```swift
let memory = try await Memory(at: URL(filePath: "memory.wax"), embedding: MyEmbedder())
```

The store creates a new `.wax` file if one doesn't exist, or opens and recovers an existing one.

## Save Content

```swift
try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
try await memory.save("Team standup: discussed sprint velocity and blockers.")
```

Behind the scenes, Wax:
1. Chunks the text according to the configured chunking strategy
2. Embeds each chunk when an embedding provider is configured
3. Indexes the text for BM25 full-text search
4. Writes frames and embeddings to the `.wax` file's write-ahead log

Call ``Memory/flush()`` to force pending writes to durable storage; ``Memory/close()`` flushes automatically.

## Search

```swift
let results = try await memory.search("What did Alice say about the roadmap?")

for item in results.items {
    print("[\(item.kind)] \(item.text)")
}
print("Total tokens: \(results.totalTokens)")
```

The retrieval pipeline:
1. Classifies the query type (factual, semantic, temporal, exploratory)
2. Searches across BM25, vector, and structured memory lanes
3. Fuses results with reciprocal rank fusion (RRF)
4. Assembles context within the configured token budget

### Know which mode actually ran

Wax degrades to the text lane when the vector lane is unavailable (no embedder, unsupported OS, embedding timeout). Every search reports what actually happened via ``RAGContext/diagnostics``:

```swift
let results = try await memory.search("roadmap")
if let diagnostics = results.diagnostics {
    print("requested: \(diagnostics.requestedMode)")
    print("effective: \(diagnostics.effectiveMode)")       // "text" when the vector lane was unavailable
    print("embedding: \(diagnostics.queryEmbeddingState)") // e.g. .available, .noEmbedder, .circuitOpen
}
```

For a store-level health snapshot, use ``Memory/stats()``:

```swift
let stats = await memory.stats()
print(stats.vectorSearchEnabled)      // is the vector index active?
print(stats.queryEmbedderConfigured)  // can queries be embedded?
```

## Retrieval Modes

Control the retrieval lanes per query via ``Memory/SearchOptions``:

```swift
// BM25 only — deterministic and fastest
let textOnly = try await memory.search("sprint velocity", options: .init(mode: .textOnly))

// Vector only — semantic similarity
let semantic = try await memory.search("roadmap discussion", options: .init(mode: .vectorOnly))

// Hybrid (default) — RRF fusion of both lanes; alpha weights the vector lane
let hybrid = try await memory.search("Alice roadmap", options: .init(mode: .hybrid(alpha: 0.7)))
```

## Configuration

Customize behavior via ``Memory/Config``:

```swift
let memory = try await Memory(at: storeURL) { config in
    config.enableTextSearch = true
    config.enableVectorSearch = true
    config.enableStructuredMemory = false
    config.ingestConcurrency = 2
    config.ingestBatchSize = 32
}
```

## Text-Only Mode

If you don't need vector search, disable it explicitly — no embedder is loaded:

```swift
let memory = try await Memory(at: storeURL) { config in
    config.enableVectorSearch = false
}
```

This gives you BM25 full-text search without the embedding overhead.

## Clean Up

Always close the store when done:

```swift
try await memory.close()
```

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
