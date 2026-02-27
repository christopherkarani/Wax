---
name: wax
description: Comprehensive guidance for the Wax on-device memory/RAG framework. Use when integrating MemoryOrchestrator, VideoRAGOrchestrator, Wax/WaxSession, embedding providers, hybrid search, maintenance, or when evaluating Wax constraints like offline-only, single-file .wax persistence and deterministic retrieval.
---

# Wax

## Overview
Use this skill to design and implement correct Wax-based on-device RAG flows in Swift 6.2, emphasizing deterministic retrieval, single-file persistence, and safe concurrency.

## Choose The API Surface
1. Prefer `MemoryOrchestrator` for text memory and retrieval.
2. Use `VideoRAGOrchestrator` for on-device video RAG (keyframes + transcripts).
3. Use `Wax` and `WaxSession` for lower-level indexing, unified search, or structured memory.
4. Import `Wax` to get re-exported core/search/vector APIs.

## Core Workflow
1. Choose a `.wax` store URL.
2. Configure `OrchestratorConfig` (disable vector search if no embedder).
3. Provide an `EmbeddingProvider` when vector search is enabled.
4. Call `remember(...)` to ingest and `recall(...)` to build `RAGContext`.
5. Call `flush()` or `close()` to persist.

## Safety & Constraints
- Keep Wax offline-only; no network calls are made. See `references/constraints.md`.
- Treat the `.wax` file as the single source of truth (data + indexes + WAL).
- Provide an embedder when vector search is enabled and no vector index exists.
- Use `QueryEmbeddingPolicy` deliberately; `.always` throws if vector search is disabled or no embedder is configured.
- For Video RAG, supply transcripts; Wax does not transcribe in v1.
- Ensure multimodal embeddings are normalized when using Metal-backed vector search in Video RAG.

## Performance & Determinism Tips
- Use `WaxPrewarm.tokenizer()` to reduce first-query latency.
- If MiniLM is available, use `MemoryOrchestrator.openMiniLM(...)` or `WaxPrewarm.miniLM(...)` to warm embeddings.
- Prefer `.ifAvailable` query embeddings unless you require hard failures.

## Examples

```swift
import Foundation
import Wax

func demoTextOnly() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-memory")
        .appendingPathExtension("wax")

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false

    let memory = try await MemoryOrchestrator(at: url, config: config)
    try await memory.remember("User: prefers Swift over Java.")

    let ctx = try await memory.recall(query: "preferences")
    _ = ctx.items

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

func demoVector() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-vector")
        .appendingPathExtension("wax")

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true

    let memory = try await MemoryOrchestrator(at: url, config: config, embedder: MyEmbedder())
    try await memory.remember("Vector search enabled.")

    let ctx = try await memory.recall(query: "vector")
    _ = ctx.totalTokens

    try await memory.flush()
    try await memory.close()
}
```

```swift
import Foundation
import Wax
import CoreGraphics

struct MyVideoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 768
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Local",
        model: "clip-v1",
        dimensions: 768,
        normalized: true
    )

    func embed(text: String) async throws -> [Float] { [Float](repeating: 0.0, count: dimensions) }
    func embed(image: CGImage) async throws -> [Float] { [Float](repeating: 0.0, count: dimensions) }
}

struct MyTranscriptProvider: VideoTranscriptProvider {
    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        []
    }
}

func demoVideo() async throws {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-video")
        .appendingPathExtension("wax")

    let rag = try await VideoRAGOrchestrator(
        storeURL: storeURL,
        embedder: MyVideoEmbedder(),
        transcriptProvider: MyTranscriptProvider()
    )

    try await rag.ingest(files: [
        VideoFile(id: "clip-1", url: URL(fileURLWithPath: "/path/to/clip.mp4"))
    ])

    let ctx = try await rag.recall(.init(text: "find the opening scene"))
    _ = ctx.items
    try await rag.flush()
}
```

## Glossary
- `MemoryOrchestrator`: High-level API for ingesting text and building `RAGContext`.
- `RAGContext`: Deterministic retrieval output with items and total token count.
- `EmbeddingProvider`: Supplies text embeddings for vector search.
- `VideoRAGOrchestrator`: On-device video ingestion and recall over keyframes and transcripts.
- `VideoQuery`: Video recall parameters (text, time range, IDs, budgets).

## References
- `references/public-api.md`
- `references/constraints.md`

## Templates
- `templates/init-store-embedder.md`
- `templates/remember-recall-lifecycle.md`
- `templates/hybrid-search.md`
- `templates/maintenance.md`
- `templates/video-rag-transcripts.md`
