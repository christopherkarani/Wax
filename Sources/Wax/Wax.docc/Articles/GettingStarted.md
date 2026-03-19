# Getting Started

Create a memory orchestrator, remember text, and recall context in minutes.

## Overview

Wax provides persistent, on-device memory with semantic search. The fastest way to get started is with ``MemoryOrchestrator``, which handles ingestion, chunking, embedding, indexing, and retrieval automatically.

## Add the Dependency

Add Wax to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/user/Wax.git", from: "1.0.0"),
]
```

Then add it to your target:

```swift
.target(
    name: "MyApp",
    dependencies: ["Wax", "WaxVectorSearchMiniLM"]
)
```

## Create an Orchestrator

```swift
import Wax
import WaxVectorSearchMiniLM

// Create the on-device embedding provider
let embedder = try MiniLMEmbedder()

// Initialize the orchestrator (creates or opens the .wax file)
let orchestrator = try await MemoryOrchestrator(
    at: URL(filePath: "memory.wax"),
    config: .init(),
    embedder: embedder
)
```

You can also use the convenience initializer:

```swift
let orchestrator = try await MemoryOrchestrator.openMiniLM(
    at: URL(filePath: "memory.wax")
)
```

The orchestrator creates a new `.wax` file if one doesn't exist, or opens and recovers an existing one.

## Remember Content

Ingest text content with ``MemoryOrchestrator/remember(_:metadata:)``:

```swift
try await orchestrator.remember("Had coffee with Alice. She mentioned the Q4 roadmap.")
try await orchestrator.remember("Team standup: discussed sprint velocity and blockers.")
```

Behind the scenes, Wax:
1. Chunks the text according to the configured ``ChunkingStrategy``
2. Embeds each chunk using the provided embedding provider
3. Indexes the text for BM25 full-text search
4. Writes frames and embeddings to the `.wax` file
5. Commits the changes

## Recall Context

Retrieve relevant context for a query with ``MemoryOrchestrator/recall(query:)``:

```swift
let context = try await orchestrator.recall(query: "What did Alice say about the roadmap?")

for item in context.items {
    print("[\(item.kind)] \(item.text)")
}
print("Total tokens: \(context.totalTokens)")
```

The RAG pipeline:
1. Classifies the query type (factual, semantic, temporal, exploratory)
2. Searches across BM25, vector, and structured memory lanes
3. Fuses results with reciprocal rank fusion (RRF)
4. Assembles context within the configured token budget

## Search Directly

For lower-level access, use ``MemoryOrchestrator/search(query:mode:topK:frameFilter:)``:

```swift
let hits = try await orchestrator.search(
    query: "sprint velocity",
    mode: .hybrid(alpha: 0.5),
    topK: 10
)

for hit in hits {
    print("\(hit.frameId): \(hit.score) — \(hit.previewText ?? "")")
}
```

If you store a structured payload alongside your content, the returned hit also
includes `metadata`. That lets you recover app-specific identifiers such as an
`id` field without re-parsing the original content.

## Configuration

Customize behavior via ``OrchestratorConfig``:

```swift
var config = OrchestratorConfig()

// Search features
config.enableTextSearch = true
config.enableVectorSearch = true
config.enableStructuredMemory = false

// Chunking
config.chunking = .tokenCount(400, overlap: 40)

// RAG token budget
config.ragConfig.maxContextTokens = 2000
config.ragConfig.searchTopK = 32

let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: config,
    embedder: embedder
)
```

## Text-Only Mode

If you don't need vector search, pass `nil` for the embedder:

```swift
let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: .init(),
    embedder: nil
)
```

This gives you BM25 full-text search without the embedding overhead.

## Clean Up

Always close the orchestrator when done:

```swift
try await orchestrator.close()
```

## Using Wax with Claude Code

Wax ships with an MCP server that gives Claude Code persistent memory. Install and configure:

```bash
npx -y waxmcp@latest mcp install --scope user
```

Then add the memory prompt to your `CLAUDE.md` — see the [README](https://github.com/christopherkarani/Wax#ai-coding-assistants) for the recommended snippet.

### MCP Tools

| Tool | Purpose | Key Parameters |
|------|---------|----------------|
| `wax_session_start` | Start a process-local MCP session and return `session_id` | none |
| `wax_remember` | Store text and optional metadata | `content`, `session_id`, `metadata`, `commit` |
| `wax_recall` | Build assembled context for a query | `query`, `session_id`, `limit`, `mode`, `search_top_k` |
| `wax_search` | Return ranked raw hits | `query`, `session_id`, `mode`, `topK`, `filters` |
| `wax_corpus_search` | Search across many session `.wax` files with provenance | `query`, `sessions_dir`, `corpus_store_path`, `rebuild`, `mode`, `topK` |
| `wax_handoff` | Save session state for the next run | `content`, `session_id`, `project`, `pending_tasks` |
| `wax_handoff_latest` | Load the latest handoff | `project` |
| `wax_flush` | Commit batched writes before reads | none |
| `wax_stats` | Runtime and storage stats | none |

### Agent Workflow

```
Session start      →  wax_handoff_latest(project: "my-app"), then wax_session_start()
During work        →  wax_recall(query: "auth architecture", session_id: ...)
Save task memory   →  wax_remember(content: "Auth uses session cookies", session_id: ...)
Batch writes       →  wax_remember(..., commit: false), then wax_flush()
Cross-session look →  wax_corpus_search(query: "previous auth migration", mode: "hybrid")
Session end        →  wax_handoff(content: "Migrated auth to cookies", session_id: ..., project: "my-app"), then wax_session_end(session_id: ...)
```
