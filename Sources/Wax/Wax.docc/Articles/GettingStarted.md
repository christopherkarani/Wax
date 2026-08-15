# Getting Started

Create a memory store, save text, and search it from an iOS or macOS app.

## Overview

Wax stores durable text (and embeddings) in a single `.wax` file. The public entry point is ``Memory``.

## Add the Dependency

In Xcode: **File → Add Package Dependencies…** → `https://github.com/christopherkarani/Wax.git` → add the **Wax** product.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.24"),
]
```

```swift
.target(
    name: "MyApp",
    dependencies: ["Wax"]
)
```

Wax builds for iOS 17 / macOS 14 and later. Built-in MiniLM needs iOS 18 / macOS 15 and the default `MiniLMEmbeddings` trait. Foundation Models adapters need iOS 26 / macOS 26.

## Create a Memory Store

```swift
import Foundation
import Wax

// Creates or opens the file. On iOS 18 / macOS 15+ MiniLM is wired automatically
// when the default package trait is enabled.
let memory = try await Memory(at: URL.documentsDirectory.appending(path: "memory.wax"))
```

Require the built-in embedder (throws if it cannot load):

```swift
let memory = try await Memory(at: storeURL) { config in
    config.embedding = .builtIn(.miniLM)
}
```

Custom embedder:

```swift
let memory = try await Memory(at: storeURL) { config in
    config.embedding = .custom(MyEmbedder())
}
```

## Save Content

```swift
try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
try await memory.save("Team standup: discussed sprint velocity and blockers.")
```

Wax chunks text, embeds when a provider is present, indexes BM25, and appends frames through the WAL. ``Memory/flush()`` forces durable writes; ``Memory/close()`` flushes automatically.

## Search

```swift
let results = try await memory.search("What did Alice say about the roadmap?")

for item in results.items {
    print("[\(item.kind)] \(item.text)")
}
print("Total tokens: \(results.totalTokens)")
```

Hybrid search is the default. If the vector lane is unavailable, Wax uses the text lane and reports that on ``RAGContext/diagnostics``:

```swift
let results = try await memory.search("roadmap")
if let diagnostics = results.diagnostics {
    print(diagnostics.requestedMode)
    print(diagnostics.effectiveMode)
    print(diagnostics.queryEmbeddingState)
}
```

Store-level snapshot:

```swift
let stats = await memory.stats()
print(stats.vectorSearchEnabled)
print(stats.queryEmbedderConfigured)
```

## Retrieval Modes

```swift
let textOnly = try await memory.search("sprint velocity", options: .init(mode: .textOnly))
let semantic = try await memory.search("roadmap discussion", options: .init(mode: .vectorOnly))
let hybrid = try await memory.search("Alice roadmap", options: .init(mode: .hybrid(alpha: 0.7)))
```

## Configuration

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

```swift
let memory = try await Memory(at: storeURL) { config in
    config.enableVectorSearch = false
}
```

## Clean Up

```swift
try await memory.close()
```

## Foundation Models

On iOS 26 / macOS 26, wrap the same store for Apple's on-device models — see <doc:FoundationModels>.

## Using Wax with Claude Code

Wax ships an MCP server for agent memory. Install:

```bash
npx -y waxmcp@latest mcp install --scope user
```

See the [README](https://github.com/christopherkarani/Wax#agent-quick-start) and `Resources/docs/wax-mcp-setup.md` for the operator workflow (`session_start`, `remember`, `recall`, `handoff`, …).
