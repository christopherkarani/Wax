---
name: wax
description: >
  Add Wax on-device memory and retrieval (RAG) to an iOS, iPadOS, or macOS app
  in Swift. Use when someone asks to make an app remember things, add local
  semantic search, search notes offline, build on-device RAG in SwiftUI/UIKit/
  AppKit, add the Wax Swift package in Xcode/SPM, open a .wax store, wire
  MiniLM or a custom EmbeddingProvider, tune hybrid vs text-only search,
  flush on background, or debug why recall looks lexical-only. Not for Wax MCP
  tools (remember, recall, handoff, session_start) — use wax-mcp. Not for
  package-only PhotoRAG/VideoRAG orchestrators — those are not app APIs.
license: Apache-2.0
metadata:
  author: christopherkarani
  product: Wax
  platforms: iOS,iPadOS,macOS
  compatibility: Swift 6.1+ / Xcode 16.4+; app target iOS 17+ or macOS 14+; SPM
---

# Wax (Apple Apps)

## Overview

Wax is a **local retrieval index** in one `.wax` file. Apps use `import Wax` → public `Memory` only. No servers, API keys, or network calls.

**Default path:** one long-lived `Memory` actor → `save` with unique metadata → `search` with `.hybrid()` → verify `diagnostics`/`stats()` → `flush` on background.

Wax is not a record store: it cannot enumerate frames. Keep your ordered transcript/model; use Wax for recall.

## Dependency (match this skill’s API)

Documents `Memory.Config.embedding` + `RAGContext.diagnostics` on current `main`. Released tag `0.1.25` still uses `Memory(at:embedding:)` / `builtInEmbedding:` and has **no** `diagnostics`.

Until a newer release ships that surface, depend on `main` (do **not** use `from: "0.1.25"` for this API):

```swift
.package(url: "https://github.com/christopherkarani/Wax.git", branch: "main")
```

Product: `Wax`. Toolchain: **Swift 6.1+ / Xcode 16.4+**. Platforms: iOS 17 / macOS 14; MiniLM needs iOS 18 / macOS 15 + default `MiniLMEmbeddings` (~44 MB).

Before naming types not shown below → `references/public-api.md`.  
Before App Store / multi-target builds → `references/app-integration.md`.  
When search/save misbehaves or you need limits → `references/constraints.md`.

## Integration checklist

- [ ] SPM → `Wax`; create parent directory for the store URL
- [ ] One shared `Memory` **actor** (exclusive file lock)
- [ ] `save(text, metadata:)` with a **unique** string id when identical text can repeat
- [ ] Own ordered transcript for UI replay
- [ ] `search` with `.hybrid()`; use `Memory.TimeRange` for “last week”
- [ ] Check `diagnostics.effectiveMode` — hybrid may run as `"text"`
- [ ] Gate writes if a vector-backed store lost its embedder (see Gotchas)
- [ ] `flush()` on iOS `.background`; `close()` only on controlled teardown

## Core workflow

```swift
import Foundation
import Wax

actor AppMemory {
    static let shared = AppMemory()
    private var memory: Memory?
    private var opening: Task<Memory, Error>?

    private let url = URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "App")
        .appending(path: "memory.wax")

    func handle() async throws -> Memory {
        if let memory { return memory }
        if let opening { return try await opening.value }
        let url = self.url
        let task = Task {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // .automatic → MiniLM when available; else text-only on a fresh store
            return try await Memory(at: url)
        }
        opening = task
        defer { opening = nil }
        let opened = try await task.value
        memory = opened
        return opened
    }

    func saveNote(_ text: String, id: String) async throws {
        let memory = try await handle()
        let stats = await memory.stats()
        // Existing vector index + no embedder → save throws missingEmbedder
        if stats.vectorSearchEnabled && !stats.queryEmbedderConfigured {
            throw WaxError.missingEmbedder
        }
        try await memory.save(text, metadata: [
            "id": id,
            "sent_at_ms": String(Int64(Date().timeIntervalSince1970 * 1000))
        ])
    }

    func search(_ query: String, afterMs: Int64? = nil, beforeMs: Int64? = nil) async throws -> Memory.Results {
        let memory = try await handle()
        let range: Memory.TimeRange? =
            (afterMs != nil || beforeMs != nil)
            ? Memory.TimeRange(afterMs: afterMs, beforeMs: beforeMs) : nil
        return try await memory.search(query, options: Memory.SearchOptions(
            topK: 20,
            timeRange: range,
            mode: .hybrid(alpha: 0.5) // higher → more lexical; lower → more semantic
        ))
    }

    func flush() async { try? await memory?.flush() }
    func shutdown() async {
        let m = memory; memory = nil
        try? await m?.close()
    }
}

// Render hits (Memory.Results == RAGContext)
func show(_ results: Memory.Results) {
    for item in results.items {
        print(item.metadata["id"] ?? "\(item.frameId)", item.text, item.sources)
    }
    print(results.diagnostics?.effectiveMode ?? "no diagnostics")
}

// iOS: flush on background — do not close every background
// .onChange(of: scenePhase) { _, phase in
//   if phase == .background { Task { await AppMemory.shared.flush() } }
// }
```

### Embedders

```swift
let memory = try await Memory(at: url) // automatic
let memory = try await Memory(at: url) { $0.embedding = .builtIn(.miniLM) } // throws if unavailable
let memory = try await Memory(at: url) { $0.embedding = .custom(MyEmbedder()) }
let memory = try await Memory(at: url) { $0.enableVectorSearch = false }
```

Custom provider → `templates/custom-embedder.swift` + `references/app-integration.md`.

### Search modes

| Mode | Behavior |
|------|----------|
| `.hybrid(alpha: 0.5)` | RRF; **alpha = text-lane weight**, `1-alpha` = vector; degrades to text if no embedder |
| `.textOnly` | Lexical only |
| `.vectorOnly` | Throws (`WaxError.io`) if vector search unavailable — does not degrade |

After search: `diagnostics.effectiveMode` is `"hybrid(alpha=0.500)"` or `"text"`. If `"text"`, check `queryEmbeddingState`.

`save` may create document + chunk frames — dedupe UI by metadata `id`. Prefer `Memory.TimeRange` over date-in-text. `delete(frameID:)` deletes one frame from a hit; sibling chunks may remain — filter UI against your transcript.

## Gotchas

- Package-only types (`MemoryOrchestrator`, photo/video orchestrators, `Wax` actor, `WaxSession`) are not usable from apps.
- Second `Memory(at: sameURL)` → `WaxError.lockUnavailable` (widgets / App Groups / previews).
- Flush on background; do not close every background.
- `requireOnDeviceProviders` defaults true; networked custom providers need `executionMode = .mayUseNetwork` **and** `requireOnDeviceProviders = false`.
- Embedder identity change on an existing store **throws at open** (`WaxError.io` binding mismatch). New file or re-ingest. (Silent mix only if custom `identity` is `nil`.)
- Store with an existing vector index reopened **without** an embedder keeps `vectorSearchEnabled` true → **`save` throws `missingEmbedder`**. Fix: `$0.enableVectorSearch = false`, or ensure an embedder, or gate writes on `stats()`.
- Unflushed WAL entries are recovered on next successful open; still flush on background so commits finish before suspension.

## Verify before shipping

1. `stats()` → embedder flags match the OS.
2. Hybrid search with no lexical overlap → `effectiveMode` has prefix `hybrid` and some `item.sources.contains(.vector)` on iOS 18+.
3. Text-only / iOS 17 path → hybrid reports `"text"`; forced `.vectorOnly` throws.

## References

- `references/public-api.md` — signatures, nested types, errors
- `references/app-integration.md` — size, traits, locking, backup, extensions
- `references/constraints.md` — offline / ingest / persistence limits
- `templates/custom-embedder.swift` — custom `EmbeddingProvider` only
