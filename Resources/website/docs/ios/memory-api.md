---
sidebar_position: 3
title: "Memory API"
sidebar_label: "Memory API"
---

`Memory` is the public facade for text memory in app targets. Everything below assumes `import Wax` and a package pin of **`main`** (see [Get started](./getting-started)).

## Create a store

```swift
import Foundation
import Wax

func openMemoryStores(storeURL: URL) async throws -> (Memory, Memory) {
    // Default: automatic MiniLM on iOS 18+ when the MiniLMEmbeddings trait is on
    let memory = try await Memory(at: storeURL)

    // Or configure inline
    let memory2 = try await Memory(at: storeURL) { config in
        config.enableTextSearch = true
        config.enableVectorSearch = true
        config.ingestConcurrency = 2
        config.ingestBatchSize = 32
    }

    return (memory, memory2)
}
```

### Embeddings

```swift
import Foundation
import Wax

func openWithEmbeddingChoices(storeURL: URL, custom: MyEmbedder) async throws {
    // Fail if the built-in provider cannot load
    let withMiniLM = try await Memory(at: storeURL) { config in
        config.embedding = .builtIn(.miniLM)
    }
    try await withMiniLM.close()

    // Bring your own model
    let withCustom = try await Memory(at: storeURL) { config in
        config.embedding = .custom(custom)
    }
    try await withCustom.close()

    // Full-text only — no embedder load
    let textOnly = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }
    try await textOnly.close()
}
```

`EmbeddingSource.automatic` (the default) wires MiniLM on supported OS + trait builds. Otherwise the store stays usable with text search; check `search` diagnostics or `stats()` if you need to know which lane ran.

## Save

```swift
import Foundation
import Wax

func saveExamples(memory: Memory) async throws {
    try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
    try await memory.save(
        "Team standup notes",
        metadata: ["source": "standup", "day": "2026-08-15"]
    )
    try await memory.flush() // optional; close() flushes too
}
```

Behind the scenes Wax chunks text, embeds when a provider is present, indexes BM25, and appends frames through the WAL.

## Search

```swift
import Foundation
import Wax

func searchExamples(memory: Memory) async throws {
    let results = try await memory.search("What did Alice say about the roadmap?")

    for item in results.items {
        print("[\(item.kind)] \(item.text)")
    }
    print("tokens:", results.totalTokens)
}
```

### Retrieval modes

```swift
import Foundation
import Wax

func retrievalModeExamples(memory: Memory) async throws {
    let lexical = try await memory.search(
        "sprint velocity",
        options: .init(mode: .textOnly)
    )
    print("lexical hits:", lexical.items.count)

    // Prefer textOnly/hybrid in copy-paste demos. vectorOnly throws when no embedder
    // can serve the query — wrap it if you need that mode:
    do {
        let semantic = try await memory.search(
            "roadmap discussion",
            options: .init(mode: .vectorOnly)
        )
        print("semantic hits:", semantic.items.count)
    } catch {
        print("vectorOnly unavailable:", error)
    }

    let hybrid = try await memory.search(
        "Alice roadmap",
        options: .init(topK: 12, mode: .hybrid(alpha: 0.7))
    )
    print("hybrid hits:", hybrid.items.count)
}
```

Default mode is hybrid. Hybrid degrades to text when the vector lane is unavailable.

### Diagnostics

```swift
import Foundation
import Wax

func diagnosticsExample(memory: Memory) async throws {
    let results = try await memory.search("roadmap")
    if let d = results.diagnostics {
        print(d.requestedMode, d.effectiveMode, d.queryEmbeddingState)
    }

    let stats = await memory.stats()
    print(stats.vectorSearchEnabled, stats.queryEmbedderConfigured)
}
```

## Lifecycle

```swift
import Foundation
import Wax

func lifecycleExample(storeURL: URL) async throws {
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }
    try await memory.save("Durable note")
    try await memory.flush()
    try await memory.close()
}
```

Prefer a single store URL per app (or per user) under Documents or an App Group container if extensions need the same file.

## Custom embedder shape

```swift
import Foundation
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
