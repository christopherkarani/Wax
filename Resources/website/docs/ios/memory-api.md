---
sidebar_position: 3
title: "Memory API"
sidebar_label: "Memory API"
---

`Memory` is the public facade for text memory in app targets. Everything below assumes `import Wax`.

## Create a store

```swift
import Foundation
import Wax

let url = URL.documentsDirectory.appending(path: "app-memory.wax")

// Default: automatic MiniLM on iOS 18+ when the MiniLMEmbeddings trait is on
let memory = try await Memory(at: url)

// Or configure inline
let memory2 = try await Memory(at: url) { config in
    config.enableTextSearch = true
    config.enableVectorSearch = true
    config.ingestConcurrency = 2
    config.ingestBatchSize = 32
}
```

### Embeddings

```swift
// Fail if the built-in provider cannot load
let withMiniLM = try await Memory(at: url) { config in
    config.embedding = .builtIn(.miniLM)
}

// Bring your own model
let withCustom = try await Memory(at: url) { config in
    config.embedding = .custom(MyEmbedder())
}

// Full-text only — no embedder load
let textOnly = try await Memory(at: url) { config in
    config.enableVectorSearch = false
}
```

`EmbeddingSource.automatic` (the default) wires MiniLM on supported OS + trait builds. Otherwise the store stays usable with text search; check `search` diagnostics or `stats()` if you need to know which lane ran.

## Save

```swift
try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
try await memory.save(
    "Team standup notes",
    metadata: ["source": "standup", "day": "2026-08-15"]
)

try await memory.flush() // optional; close() flushes too
```

Behind the scenes Wax chunks text, embeds when a provider is present, indexes BM25, and appends frames through the WAL.

## Search

```swift
let results = try await memory.search("What did Alice say about the roadmap?")

for item in results.items {
    print("[\(item.kind)] \(item.text)")
}
print("tokens:", results.totalTokens)
```

### Retrieval modes

```swift
let lexical = try await memory.search(
    "sprint velocity",
    options: .init(mode: .textOnly)
)

let semantic = try await memory.search(
    "roadmap discussion",
    options: .init(mode: .vectorOnly)
)

let hybrid = try await memory.search(
    "Alice roadmap",
    options: .init(mode: .hybrid(alpha: 0.7), topK: 12)
)
```

Default mode is hybrid. `.vectorOnly` throws when no embedder can serve the query. Hybrid degrades to text when the vector lane is unavailable.

### Diagnostics

```swift
let results = try await memory.search("roadmap")
if let d = results.diagnostics {
    print(d.requestedMode, d.effectiveMode, d.queryEmbeddingState)
}

let stats = await memory.stats()
print(stats.vectorSearchEnabled, stats.queryEmbedderConfigured)
```

## Lifecycle

```swift
try await memory.flush()
try await memory.close()
```

Prefer a single store URL per app (or per user) under Documents or an App Group container if extensions need the same file.

## Custom embedder shape

```swift
import Wax

actor MyEmbedder: EmbeddingProvider {
    let dimensions = 384
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Local",
        model: "v1",
        dimensions: 384,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        // Return a `dimensions`-length vector for `text`.
        Array(repeating: 0, count: dimensions)
    }
}
```

## Related

- [Get started on iOS](./getting-started)
- [Foundation Models](./foundation-models)
