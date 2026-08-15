---
name: wax
description: >
  Use when adding Wax on-device memory or RAG to an iOS, iPadOS, or macOS app
  (SwiftUI, UIKit, AppKit, SPM, Xcode). Triggers include Memory facade, .wax
  store files, hybrid/vector search, MiniLM embeddings, EmbeddingProvider, or
  integrating persistent local recall into an Apple app. For MCP
  remember/recall/handoff operator workflows, use wax-mcp instead.
license: Apache-2.0
metadata:
  author: christopherkarani
  product: Wax
  platforms: iOS,iPadOS,macOS
compatibility: Requires a Swift Apple app target (iOS 17+ / macOS 14+) and SPM access to github.com/christopherkarani/Wax
---

# Wax (Apple Apps)

## Overview

Wax is an on-device, single-file memory engine for Apple apps. Integrate it with the public `Memory` actor only. No servers, API keys, or cloud calls.

**Core principle:** Apps use `import Wax` → `Memory`. Never generate client code against package-only types.

## When to use

- Adding persistent local memory / RAG to an iOS, iPad, or Mac app
- Wiring SPM + `Memory(at:)` / `save` / `search` / `flush` / `close`
- Choosing built-in MiniLM vs a custom `EmbeddingProvider`
- Debugging text-only fallback vs hybrid/vector retrieval

**Do not use** for Wax MCP session tools (`remember`, `recall`, `handoff`, `session_start`) — that is the separate `wax-mcp` skill.

## Integration checklist

1. Add SPM dependency: `https://github.com/christopherkarani/Wax.git` (from `"0.1.8"` or newer).
2. Link the `Wax` product to the app target.
3. Pick a store URL under the app sandbox (usually Application Support or Documents) ending in `.wax`.
4. Open `Memory(at:)` (optional config closure for embeddings / search flags).
5. `save` text, `search` queries, then `flush` or `close` on lifecycle boundaries.
6. Verify effective retrieval with `results.diagnostics` or `memory.stats()`.

## Platform requirements

| Capability | Minimum |
|------------|---------|
| Build / text search | iOS 17 / iPadOS 17 / macOS 14 |
| Built-in MiniLM semantic embeddings | iOS 18 / macOS 15 + default `MiniLMEmbeddings` trait |
| Foundation Models memory tools | iOS 26 / macOS 26 |

On older OS versions, provide a custom `EmbeddingProvider` or run text-only search.

## Public API surface (apps)

Use only:

- `Memory` — open store, save, search, delete, flush, close, stats
- `Memory.Config` / `Memory.EmbeddingSource` / `Memory.SearchOptions` / `RetrievalMode`
- `RAGContext` (`Memory.Results`) + diagnostics
- `EmbeddingProvider` / `BatchEmbeddingProvider` / `EmbeddingIdentity`
- `BuiltInEmbeddingProvider` / `BuiltInEmbeddings` (when available)
- Optional: `memory.foundationModelsMemoryTool()` / related helpers on iOS/macOS 26+

**Forbidden in app code** (package-only): `MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, `Wax` actor, `WaxSession`, structured-memory Swift types. Photo/video/structured memory for agents goes through MCP tools, not `import Wax`.

## Core workflow

```swift
import Foundation
import Wax

let url = URL.applicationSupportDirectory
    .appending(path: "MyApp")
    .appending(path: "memory.wax")

try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

// On iOS 18 / macOS 15+, MiniLM wires automatically for hybrid search.
let memory = try await Memory(at: url)

try await memory.save(
    "User prefers dark mode and Vim keybindings.",
    metadata: ["source": "settings"]
)

let results = try await memory.search("editor preferences")
if let diagnostics = results.diagnostics {
    // "hybrid(alpha=…)" or "text" when the vector lane was unavailable
    _ = diagnostics.effectiveMode
}

try await memory.flush()
try await memory.close()
```

### Embedder choices

```swift
// Automatic (default): MiniLM when supported, else text-only
let memory = try await Memory(at: url)

// Force built-in MiniLM (throws if unavailable on this OS/build)
let memory = try await Memory(at: url) { $0.embedding = .builtIn(.miniLM) }

// Custom embedder
let memory = try await Memory(at: url) { $0.embedding = .custom(MyEmbedder()) }

// Explicit text-only store
let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
```

### Search modes

| Mode | Behavior |
|------|----------|
| `.hybrid(alpha:)` (default) | Fuses text + vector; degrades to text if no embedder |
| `.textOnly` | Lexical / BM25 only — fast and deterministic |
| `.vectorOnly` | Semantic only — **throws** if vector search unavailable |

Always check `results.diagnostics` when mode matters.

## App lifecycle tips

- Keep one long-lived `Memory` per store (it is an `actor`); do not reopen on every keystroke.
- Call `flush()` after important writes if the process may be suspended; `close()` on teardown.
- Store path must be writable in the sandbox. Prefer Application Support for durable app data; Documents if the user should see/share the file.
- Wax makes **no network calls**. Do not add API-key scaffolding.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Importing / constructing `MemoryOrchestrator` | Use `Memory` only |
| Assuming hybrid always means semantic | Check `diagnostics.effectiveMode` / `stats()` |
| Using `.vectorOnly` on iOS 17 without a custom embedder | Provide `EmbeddingProvider` or use `.hybrid` / `.textOnly` |
| Forgetting sandbox directories | Create parent folders before `Memory(at:)` |
| Treating Wax as a cloud sync service | Single local `.wax` file — sync only if *you* copy/sync that file |

## References

- [references/public-api.md](references/public-api.md) — public surface detail
- [references/constraints.md](references/constraints.md) — offline / embedding / persistence limits
- Upstream docs: [Wax Getting Started](https://github.com/christopherkarani/Wax/blob/main/Sources/Wax/Wax.docc/Articles/GettingStarted.md)

## Templates

- [templates/init-store-embedder.md](templates/init-store-embedder.md)
- [templates/remember-recall-lifecycle.md](templates/remember-recall-lifecycle.md)
- [templates/hybrid-search.md](templates/hybrid-search.md)
- [templates/maintenance.md](templates/maintenance.md)
- [templates/video-rag-transcripts.md](templates/video-rag-transcripts.md) — package-only status note
