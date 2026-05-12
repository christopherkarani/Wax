---
sidebar_position: 1
title: "Getting Started"
sidebar_label: "Getting Started"
---

Save text to a `.wax` store and retrieve relevant context with the public
`Memory` facade.

## Add The Dependency

Add Wax from the public repository:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.21"),
]
```

Wax is still pre-1.0. For application releases, pin the exact version you have
validated:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", exact: "0.1.21"),
]
```

Then add the `Wax` product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "Wax", package: "Wax"),
    ]
)
```

The root package currently supports Swift 6.1+, macOS 15+, and iOS 18+.

## Open A Store

Use text-only mode when you do not provide your own embedding model:

```swift
import Foundation
import Wax

let storeURL = URL.documentsDirectory.appending(path: "agent.wax")

var config = Memory.Config()
config.enableVectorSearch = false

let memory = try await Memory(at: storeURL, config: config)
```

Wax creates the store if it does not exist and recovers it when reopening the
same file.

## Save Content

Save text with optional metadata:

```swift
try await memory.save(
    "Had coffee with Alice. She mentioned the Q4 roadmap.",
    metadata: ["source": "meeting-notes", "id": "note-42"]
)

try await memory.save("Team standup: discussed sprint velocity and blockers.")
```

## Search Memory

Search returns ranked context items:

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

## Use Hybrid Retrieval

For semantic retrieval, keep vector search enabled and provide an
`EmbeddingProvider` from your app:

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

The bundled MiniLM runtime is used by Wax's CLI and MCP packages. External Swift
packages should use the public `Memory` facade with their own
`EmbeddingProvider`.

## Clean Up

Close memory handles when your app or tool is done:

```swift
try await memory.close()
try await semanticMemory.close()
```
