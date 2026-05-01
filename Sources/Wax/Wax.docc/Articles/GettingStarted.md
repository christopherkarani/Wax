# Getting Started

Save text to a `.wax` file and retrieve relevant context with the public
``Memory`` facade.

## Add the Dependency

Add Wax to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8"),
]
```

Then add the `Wax` product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Wax", package: "Wax")
    ]
)
```

## Open Text-Only Memory

Use text-only mode when you do not provide an embedding model. This compiles and
runs in external packages without touching package-internal orchestrator APIs.

```swift
import Foundation
import Wax

let storeURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("memory")
    .appendingPathExtension("wax")

var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: storeURL, config: config)
```

The store is created if it does not exist and recovered if Wax finds an existing
file at the same URL.

## Remember Content

Save one or more text memories:

```swift
try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
try await memory.save("Team standup: discussed sprint velocity and blockers.")
```

Metadata is optional and remains available on returned context items:

```swift
try await memory.save(
    "The Android launch is waiting on design signoff.",
    metadata: ["source": "standup", "id": "note-42"]
)
```

## Search Memory

Ask Wax for ranked context:

```swift
var options = Memory.SearchOptions()
options.mode = .textOnly
options.topK = 5
let context = try await memory.search(
    "What did Alice say about the roadmap?",
    options: options
)

for item in context.items {
    print("\(item.score): \(item.text)")
}

print("Total tokens: \(context.totalTokens)")
```

## Use A Custom Embedder

For hybrid retrieval, provide a public ``EmbeddingProvider`` implementation and
keep vector search enabled:

```swift
import Foundation
import Wax

actor LocalEmbedder: EmbeddingProvider {
    let dimensions = 384
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Local",
        model: "example-v1",
        dimensions: 384,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        // Replace this with an on-device model.
        [Float](repeating: 0, count: dimensions)
    }
}

var semanticConfig = Memory.Config()
semanticConfig.enableVectorSearch = true
let semanticMemory = try await Memory(
    at: storeURL,
    config: semanticConfig,
    embedding: LocalEmbedder()
)

try await semanticMemory.save("Alice prefers roadmap summaries before meetings.")

var semanticOptions = Memory.SearchOptions()
semanticOptions.mode = .hybrid
semanticOptions.topK = 5
let semanticContext = try await semanticMemory.search(
    "meeting prep for Alice",
    options: semanticOptions
)
```

`MiniLMEmbedder` is currently package-internal to Wax. External packages should
bring their own ``EmbeddingProvider`` or use the packaged CLI/MCP runtime when
they want the bundled embedding path.

## Clean Up

Close memory handles when your app or tool is done with the store:

```swift
try await memory.close()
try await semanticMemory.close()
```

## Package-Internal Articles

The articles on `MemoryOrchestrator`, `WaxSession`, `SearchRequest`, Photo RAG,
and Video RAG document Wax internals. They are useful when changing Wax itself,
but they are not copy-paste examples for external packages unless the article
explicitly says the snippet uses ``Memory``.

## Using Wax With Coding Agents

Wax ships with an MCP server for persistent coding-agent memory:

```bash
npx -y waxmcp@latest mcp install --scope user
```

Add the Codex prompt to `AGENTS.md` or the Claude Code prompt to `CLAUDE.md`.
Both use the current unprefixed tool names:

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

Normal agent flows should not manage `SESSION_STORE`, `--store-path`, or
`flush`; the broker owns long-term memory and virtual session stores.
