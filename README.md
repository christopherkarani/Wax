# 🕯️ Wax

**The Swift-native single-file memory engine**

> 🚀 **Built for iOS 26 & macOS 26** | 🧠 **On-device RAG** | 🔍 **Hybrid Search** | 💾 **Single-file persistence**

Wax is a crash-safe, single-file memory store that brings production-grade RAG (Retrieval-Augmented Generation) to mobile and desktop apps. Zero external dependencies. Maximum performance. Deterministic results.

## ✨ What Makes Wax Special

**Stop shipping dumb apps.** Give your users AI that actually remembers.

- 🎯 **One file to rule them all** - A single `.mv2s` file contains everything: data, indexes, and write-ahead log
- 🔒 **Bulletproof reliability** - Crash-safe by design. Your data survives app kills, power loss, and update cycles  
- ⚡ **Lightning fast** - Hybrid search fuses lexical + vector + temporal signals in microseconds
- 🧮 **Predictable costs** - Deterministic token counting means stable, testable AI prompts
- 🎭 **Swift-native perfection** - Actor-isolated, fully async, written for Swift 6.2 concurrency
- 🧩 **Pick your poison** - Use just the core, or go full-stack with embeddings and RAG

## 🚀 Perfect For

- **AI Assistants** that remember conversations across app launches
- **Offline-first apps** with enterprise-grade search
- **Privacy-focused products** where data never leaves the device
- **Research tools** that need reproducible retrieval experiments
- **Agent workflows** that require durable state management

## 🎯 Live Examples

### Build a Memory Palace for Your AI

```swift
// Your AI assistant that never forgets
let memory = try await MemoryOrchestrator(at: documentsURL)

// Every conversation gets remembered
try await memory.remember("User: I prefer Python over JavaScript")
try await memory.remember("User: My birthday is March 15th")

// Instant, context-aware retrieval
let context = try await memory.recall(query: "programming preferences")
// Returns: "User: I prefer Python over JavaScript"
```

### Turn Documents into Searchable Knowledge

```swift
// Ingest your entire documentation
let documents = ["API Reference", "User Guide", "Troubleshooting"]
for doc in documents {
    try await memory.remember(doc)  
}

// Semantic search across everything
let results = try await memory.recall(query: "how to authenticate users")
```

### Build Deterministic AI Pipelines

```swift
// Perfect for research - same input = same output
testSuite.run {
    let context = try await memory.recall(query: $0.query)
    assert(context.totalTokens == $0.expectedTokenCount)
}

## 🏁 Get Started in 30 Seconds

### Installation

```swift
// Package.swift
.package(url: "https://github.com/your-username/Wax.git", from: "0.1.0")

// Import and go
import Wax
```

### Quick Start Magic

```swift
// 1️⃣ Create your memory palace
let memory = try await MemoryOrchestrator(at: documentsURL.appendingPathComponent("brain.mv2s"))

// 2️⃣ Feed it knowledge
try await memory.remember("Swift 6.2 introduces improved concurrency")
try await memory.remember("Async/await makes code more readable")

// 3️⃣ Ask questions, get answers
let context = try await memory.recall(query: "concurrency improvements")
for item in context.items {
    print("📚 \(item.text)")  // "Swift 6.2 introduces improved concurrency"
}

// 4️⃣ Clean up (memory persists to disk automatically)
try await memory.close()
```

## Quickstart (MemoryOrchestrator)

```swift
import Wax

let url = URL(fileURLWithPath: "/tmp/example.mv2s")
let memory = try await MemoryOrchestrator(at: url)

try await memory.remember("Swift is safe and fast.")
try await memory.remember("Rust is fearless.")

let ctx = try await memory.recall(query: "safe")
for item in ctx.items {
    print(item.kind, item.text)
}

try await memory.close()
```

## Unified Search API (Lower-Level)

```swift
import Wax

let wax = try await Wax.create(at: url)
let text = try await wax.enableTextSearch()
let vec = try await wax.enableVectorSearch(dimensions: 384)

let frameId = try await wax.put(Data("Hello from Wax".utf8),
                                options: FrameMetaSubset(searchText: "Hello from Wax"))
try await text.index(frameId: frameId, text: "Hello from Wax")
try await vec.add(frameId: frameId, vector: [Float](repeating: 0.01, count: 384))

try await text.commit()
try await vec.commit()

let request = SearchRequest(query: "Hello", mode: .hybrid(), topK: 10)
let response = try await wax.search(request)
print(response.results)

try await wax.close()
```

## Fast RAG (Deterministic Context Builder)

```swift
import Wax

let builder = FastRAGContextBuilder()
let config = FastRAGConfig(maxContextTokens: 800, searchMode: .hybrid())

let context = try await builder.build(query: "swift concurrency", wax: wax, config: config)
print(context.totalTokens)
```

## Custom Embeddings

Wax uses a protocol-based embedding interface so you can plug in your own models:

```swift
import Wax

public actor MyEmbedder: EmbeddingProvider {
    public let dimensions = 384
    public let normalize = true
    public let identity = EmbeddingIdentity(provider: "MyModel", model: "v1", dimensions: 384, normalized: true)

    public func embed(_ text: String) async throws -> [Float] {
        // Return a 384-dim vector.
        return [Float](repeating: 0.0, count: 384)
    }
}

let memory = try await MemoryOrchestrator(at: url, embedder: MyEmbedder())
```

## MiniLM (Built-in Embeddings)

If you want a built-in embedding provider, the `WaxVectorSearchMiniLM` target includes a MiniLM embedding model.

```swift
import Wax

let memory = try await MemoryOrchestrator.openMiniLM(at: url)
```

## Maintenance

Wax supports background maintenance for stable retrieval quality.

```swift
let report = try await memory.optimizeSurrogates()
let compact = try await memory.compactIndexes()
```

## Architecture at a Glance

```
[Text/Docs] -> chunking -> frames (.mv2s)
                     |-> FTS5 index (lexical)
                     |-> USearch index (vector)
                                     |
                                  unified search
                                     |
                               Fast RAG context
```

## Architectural Choices

- **Actor-owned core (`Wax`)**: isolates mutable state and I/O, making correctness the default on mobile.
- **Append-only frames + WAL**: fast writes, safe recovery, and predictable performance under load.
- **Two-phase indexing**: stage, then commit; keeps ingestion fast while guaranteeing atomic index updates.
- **Adaptive hybrid fusion**: query-type–aware weighting (text/vector/temporal) improves relevance without user tuning.
- **Deterministic RAG builder**: single expansion + ranked snippets + surrogate support gives stable, testable contexts.
- **Protocol-driven embeddings**: swap local models without touching the core store or search paths.

## Researcher Notes

- Deterministic token counting and truncation (cl100k_base).
- Unified retrieval with query-type adaptive fusion.
- Reproducible RAG contexts (single expansion, ranked snippets, surrogate support).

## Requirements

- Swift 6.2
- iOS 26 / macOS 26

## Installation

Add Wax as a Swift Package dependency.

```swift
.package(url: "<REPO_URL>", from: "0.1.0")
```

Then add targets as needed:

```swift
.product(name: "Wax", package: "Wax")
```

## Contributing

We welcome issues and PRs. For local validation:

```bash
cd Wax
swift test
```

If you're exploring the MV2S format or retrieval research, start with `MV2S_SPEC.md` and the phase docs. We are especially interested in:
- Retrieval quality evaluations and reproducibility studies
- On-device memory benchmarks
- New embedding adapters and pruning/compaction strategies
