---
name: wax
description: Comprehensive guidance for the Wax on-device memory/RAG framework. Use when integrating the public Memory facade, custom EmbeddingProvider implementations, RAGContext retrieval output, or when clearly labeled package-internal Wax APIs are needed while editing Wax itself.
---

# Wax

## Overview
Use this skill to design and implement correct Wax-based on-device memory flows
in Swift 6.2. Public consumer snippets must use the `Memory` facade unless a
section is explicitly labeled package-internal.

## Choose The API Surface
1. Prefer `Memory` for external app text memory and retrieval.
2. Use `EmbeddingProvider` with `Memory` when a host app has its own local embedding model.
3. Treat `MemoryOrchestrator`, `WaxSession`, `SearchRequest`, `MiniLMEmbedder`, `PhotoRAGOrchestrator`, and `VideoRAGOrchestrator` as package-internal implementation details in the current Wax target.
4. Import `Wax` for the public facade and re-exported core/search/vector protocols.

## Core Workflow
1. Choose a `.wax` store URL.
2. Open `Memory`. Disable vector search when no embedding provider is supplied.
3. Call `save(...)` to ingest text.
4. Call `search(...)` to build `RAGContext`.
5. Call `close()` when done.

## Safety & Constraints
- Keep Wax offline-only; no network calls are made. See `references/constraints.md`.
- Treat the `.wax` file as the single source of truth.
- For text-only public snippets, set `Memory.Config.enableVectorSearch = false`.
- For hybrid public snippets, pass a public `EmbeddingProvider` to `Memory`.
- Do not show package-internal APIs in external consumer code unless clearly labeled.

## Performance & Determinism Tips
- Use `.textOnly` for deterministic lexical lookups.
- Use `.hybrid` only when `Memory` was opened with an embedding provider or an existing vector index.
- Keep metadata stable and simple so returned `RAGContext.Item` values can be mapped back to app records.

## Examples

### Text-Only Public API

```swift
import Foundation
import Wax

func demoTextOnly() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-memory")
        .appendingPathExtension("wax")

    var config = Memory.Config()
    config.enableVectorSearch = false
    let memory = try await Memory(at: url, config: config)

    try await memory.save("User: prefers Swift over Java.")

    var options = Memory.SearchOptions()
    options.mode = .textOnly
    options.topK = 3
    let context = try await memory.search("preferences", options: options)
    _ = context.items

    try await memory.close()
}
```

### Custom Embedder Public API

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
        [Float](repeating: 0.0, count: dimensions)
    }
}

func demoVector() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-vector")
        .appendingPathExtension("wax")

    var config = Memory.Config()
    config.enableVectorSearch = true
    let memory = try await Memory(at: url, config: config, embedding: MyEmbedder())

    try await memory.save("Vector search enabled.")

    var options = Memory.SearchOptions()
    options.mode = .hybrid
    options.topK = 3
    let context = try await memory.search("vector", options: options)
    _ = context.totalTokens

    try await memory.close()
}
```

## Glossary
- `Memory`: Public facade for saving text and retrieving `RAGContext`.
- `RAGContext`: Public retrieval output with items and total token count.
- `EmbeddingProvider`: Public protocol for host-supplied text embeddings.
- `MemoryOrchestrator`: Package-internal implementation actor behind `Memory`.
- `WaxSession`: Package-internal session and writer-lease abstraction.
- `SearchRequest`: Package-internal raw search request shape.

## References
- `references/public-api.md`
- `references/constraints.md`

## Templates
- `templates/init-store-embedder.md`
- `templates/remember-recall-lifecycle.md`
- `templates/hybrid-search.md`
- `templates/maintenance.md`
- `templates/video-rag-transcripts.md`
