---
name: wax
description: >
  Swift framework guidance for Wax on-device memory/RAG. Use when writing Swift code
  with the public Memory facade, embedding providers, retrieval modes, or hybrid search.
  For agent operators using the Wax MCP server tools, use the separate wax-mcp skill instead.
---

# Wax (Swift Framework)

## Overview
Use this skill to design and implement correct Wax-based on-device memory flows in Swift 6.2, emphasizing deterministic retrieval, single-file persistence, and safe concurrency.

If you need the agent memory operator playbook for MCP tools (`remember`, `recall`,
`handoff`, `session_start`), use the `wax-mcp` skill instead of this one.

## Choose The API Surface
1. Use `Memory` (public actor) for text memory, retrieval, and structured entities/facts.
2. Use `PhotoMemory` and `VideoMemory` for on-device photo and video recall. They take a `MultimodalEmbeddingProvider` (`executionMode` is `.onDeviceOnly` or `.mayUseNetwork`).
3. `MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, `Wax`, and `WaxSession` are **package-only internals** — downstream apps cannot import or construct them. Do not generate client code against them.
4. Import `Wax` to get the re-exported embedding protocols (`EmbeddingProvider`, `BatchEmbeddingProvider`, `QueryAwareEmbeddingProvider`, `EmbeddingIdentity`).

## Core Workflow
1. Choose a `.wax` store URL.
2. Open `Memory(at:config:)` — on iOS 18/macOS 15+ with the default `MiniLMEmbeddings` trait, the built-in MiniLM embedder is wired automatically (`.automatic`).
3. Or select the embedder in config: `config.embedding = .custom(MyEmbedder())`, or force a built-in via `config.embedding = .builtIn(.miniLM)` (throws when unavailable).
4. Call `save(...)` to ingest and `search(...)` to retrieve `RAGContext`.
5. Call `flush()` or `close()` to persist. Close before any file-level copy; do not run concurrent writers across devices.

## Safety & Constraints
- Keep Wax offline-only; no network calls are made. See `references/constraints.md`.
- Treat the `.wax` file as the single source of truth (data + indexes + WAL). A default new public store is ~4 MiB WAL plus committed data; older stores may retain 256 MiB logical WAL regions.
- `RetrievalMode.hybrid` (the default) degrades to the text lane when no embedder is available; `RetrievalMode.vectorOnly` throws instead. Always check `results.diagnostics` (requested vs. effective mode) or `memory.stats()` when the mode matters.
- On iOS 17/macOS 14 there is no built-in embedder: provide a custom `EmbeddingProvider` or use text-only search.
- Video memory does not transcribe; supply a `VideoTranscriptProvider`.

## Performance & Determinism Tips
- The first-ever built-in embedder load pays a one-time CoreML compile; later launches reuse the cached compiled model.
- Use `.textOnly` mode for fast deterministic lexical lookups.
- The Metal HNSW vector engine activates automatically at 10,000+ vectors; smaller stores use an exact CPU flat index.
- Default MiniLM bundle is ~43 MiB; Arctic is opt-in (~32 MiB); `traits: []` ships no built-in model.

## Examples

```swift compile
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

    if let diagnostics = results.diagnostics {
        print(diagnostics.effectiveMode)
    }

    try await memory.close()
}
```

```swift compile
import Foundation
import Wax

func demoTextOnly() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-text")
        .appendingPathExtension("wax")

    let memory = try await Memory(at: url) { config in
        config.enableVectorSearch = false
    }
    try await memory.save("User: prefers Swift over Java.")

    let results = try await memory.search("preferences", options: .init(mode: .textOnly))
    _ = results.items

    try await memory.close()
}
```

```swift compile
import Foundation
import Wax

actor MyEmbedder: EmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Local",
        model: "v1",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(_ text: String) async throws -> [Float] {
        text.localizedCaseInsensitiveContains("password")
            ? [1, 0, 0, 0]
            : [0, 1, 0, 0]
    }
}

func demoCustomEmbedder() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-vector")
        .appendingPathExtension("wax")

    var config = Memory.Config.default
    config.embedding = .custom(MyEmbedder())
    let memory = try await Memory(at: url, config: config)
    try await memory.save("Password reset instructions are in account settings.")
    try await memory.save("The office snack drawer has trail mix.")

    let results = try await memory.search("recover password", options: .init(topK: 1, mode: .vectorOnly))
    precondition(results.items.first?.text.contains("Password reset") == true)

    try await memory.flush()
    try await memory.close()
}
```

## Glossary
- `Memory`: Public facade for ingesting text, searching `RAGContext`, and structured entities/facts.
- `PhotoMemory` / `VideoMemory`: Public owning facades for photo and video recall.
- `RAGContext`: Retrieval output with items, total token count, and `diagnostics` (requested vs. effective mode).
- `EmbeddingProvider`: Supplies text embeddings for vector search.
- `MultimodalEmbeddingProvider`: Supplies text and image embeddings for photo/video memory.
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
