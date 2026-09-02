---
name: wax
description: >
  Swift framework guidance for Wax on-device memory/RAG. Use when writing Swift code
  with the public Memory facade, experimental PhotoMemory / VideoMemory,
  BuiltInMultimodalEmbeddings, embedding providers, retrieval modes, or hybrid search.
  For agent operators using the Wax MCP server tools, use the separate wax-mcp skill instead.
---

# Wax (Swift Framework)

## Overview
Use this skill to design and implement correct Wax-based on-device memory flows in Swift 6.2, emphasizing deterministic retrieval, single-file persistence, and safe concurrency.

If you need the agent memory operator playbook for MCP tools, use the `wax-mcp`
skill and follow the live server instructions (`session_open` / `remember` /
`recall` / `session_close`). Do not treat `handoff_latest` then `session_start`
as the default open.

## Choose The API Surface
1. Use `Memory` (public actor) for text memory and retrieval.
2. Use experimental `PhotoMemory` / `VideoMemory` (`import Wax`) for photo and video RAG on Darwin. Build the embedder with `BuiltInMultimodalEmbeddings.make`.
3. `MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, `Wax`, `WaxSession`, and `MiniLMEmbedder` are **package-only internals** — downstream apps cannot import or construct them. Do not generate client code against them.
4. Structured memory (entities/facts) stays MCP/broker-facing, not a public Swift CRUD API.
5. Import `Wax` to get the re-exported embedding protocols (`EmbeddingProvider`, `BatchEmbeddingProvider`, `EmbeddingIdentity`).

## Core Workflow
1. Choose a `.wax` store URL.
2. Open `Memory(at:)` — `.automatic` opens immediately while MiniLM loads (iOS 18/macOS 15+, default `MiniLMEmbeddings` trait), then live-attaches. Check `stats().embeddingStatus`.
3. Or select the embedder in config: `Memory(at: url) { $0.embedding = .custom(MyEmbedder()) }`, or force a built-in via `$0.embedding = .builtIn(.miniLM)` (throws when unavailable).
4. Call `save(...)` to ingest and `search(...)` to retrieve `RAGContext`.
5. Call `flush()` or `close()` to persist.

## Safety & Constraints
- Keep Wax offline-only; no network calls are made. See `references/constraints.md`.
- Treat the `.wax` file as the single source of truth (data + indexes + WAL).
- `Memory.RetrievalMode.hybrid` (the default; alias of the canonical `SearchMode`) degrades to the text lane when no embedder is available; `vectorOnly` throws instead. Always check `results.diagnostics` (requested vs. effective mode) or `memory.stats()` when the mode matters.
- On iOS 17/macOS 14 there is no built-in embedder: provide a custom `EmbeddingProvider` or use text-only search.
- Video RAG does not transcribe by itself. Use `VideoMemory`; the host supplies transcripts. The store keeps text and metadata, not media bytes.

## Performance & Determinism Tips
- The first-ever built-in embedder load pays a one-time CoreML compile; later launches reuse the cached compiled model.
- Use `.textOnly` mode for fast deterministic lexical lookups.
- The Metal HNSW vector engine activates automatically at 10,000+ vectors; smaller stores use an exact CPU flat index.

## Examples

```swift
import Foundation
import Wax

func demoDefault() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-memory")
        .appendingPathExtension("wax")

    // Semantic search out of the box on iOS 18/macOS 15+ (built-in MiniLM).
    let memory = try await Memory(at: url)
    try await memory.save("User: prefers Swift over Java.")

    let results = try await memory.search("language preferences")
    _ = results.items

    // Verify which retrieval mode actually ran.
    if let diagnostics = results.diagnostics {
        print(diagnostics.effectiveMode)  // Memory.RetrievalMode (alias of SearchMode); prints "hybrid(alpha=0.500)" or "text"
    }

    try await memory.close()
}
```

```swift
import Foundation
import Wax

func demoTextOnly() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-text")
        .appendingPathExtension("wax")

    // Explicit text-only mode: no embedder is loaded.
    let memory = try await Memory(at: url) { config in
        config.enableVectorSearch = false
    }
    try await memory.save("User: prefers Swift over Java.")

    let results = try await memory.search("preferences", options: .init(mode: .textOnly))
    _ = results.items

    try await memory.close()
}
```

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

func demoCustomEmbedder() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-vector")
        .appendingPathExtension("wax")

    let memory = try await Memory(at: url) { $0.embedding = .custom(MyEmbedder()) }
    try await memory.save("Vector search enabled.")

    let results = try await memory.search("vector", options: .init(mode: .vectorOnly))
    _ = results.totalTokens

    try await memory.flush()
    try await memory.close()
}
```

```swift
import Foundation
import Wax

func demoPhotoMemory(storeURL: URL, imageURL: URL) async throws {
    let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
    let photos = try await PhotoMemory(at: storeURL, embedder: embedder, ocr: VisionOCRProvider())
    try await photos.ingest(files: [PhotoFile(id: "receipt-1", url: imageURL)])
    let context = try await photos.recall(PhotoQuery(text: "coffee receipt"))
    _ = context.items
    try await photos.close()
}
```

## Glossary
- `Memory`: Public facade for ingesting text and searching `RAGContext`.
- `PhotoMemory` / `VideoMemory`: Experimental public facades for photo and video RAG (Darwin).
- `BuiltInMultimodalEmbeddings`: Factory for the on-device multimodal embedder used by the photo/video facades.
- `RAGContext`: Retrieval output with items, total token count, and `diagnostics` (requested vs. effective mode).
- `EmbeddingProvider`: Supplies text embeddings for vector search.
- `BuiltInEmbeddingProvider`: `.miniLM` / `.arctic` on-device CoreML embedders (iOS 18/macOS 15+).

## References
- `references/public-api.md`
- `references/constraints.md`

## Templates
- `templates/init-store-embedder.md`
- `templates/remember-recall-lifecycle.md`
- `templates/hybrid-search.md`
- `templates/maintenance.md`
- `templates/video-rag-transcripts.md`
