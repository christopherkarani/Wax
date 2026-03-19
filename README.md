<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/docs/assets/banner-dark.svg">
    <img src="Resources/docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax is a high-performance, single-file memory layer for AI agents on Apple platforms.</strong><br/>
  On-device, private, and portable. No server and no cloud dependency.
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=Swift" alt="Swift" /></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square" alt="Platforms" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
  <a href="https://discord.gg/NHgNh7HJ6M"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FNHgNh7HJ6M%3Fwith_counts%3Dtrue&query=%24.approximate_presence_count&suffix=%20online&logo=discord&label=Discord&color=5865F2&style=flat-square" alt="Discord" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="Resources/locales/README.es.md">Español</a> · <a href="Resources/locales/README.fr.md">Français</a> · <a href="Resources/locales/README.ja.md">日本語</a> · <a href="Resources/locales/README.ko.md">한국어</a> · <a href="Resources/locales/README.pt.md">Português</a> · <a href="Resources/locales/README.zh-CN.md">中文</a>
</p>
<!-- HEADER:END -->

---

## What is Wax?

Wax is a Swift-native persistence engine for AI agents. It stores documents, embeddings, and structured knowledge in a single portable `.wax` file.

The goal is simple: keep memory local, keep setup light, and keep recall fast enough to stay in the loop.

### Why Wax?

| Feature          | Wax                    | SQLite (FTS5)          | Cloud Vector DBs       |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **Search**       | Hybrid (Text + Vector) | Text Only*             | Vector Only*           |
| **Latency**      | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **Privacy**      | 100% Local             | 100% Local             | Cloud-hosted           |
| **Setup**        | Zero Config            | Low                    | Complex (API Keys)     |
| **Architecture** | Apple Silicon Native   | Generic                | Varies                 |

### Why a single `.wax` file?
Most RAG systems end up with a database, a vector store, and a file server. Wax keeps the moving pieces smaller by bundling documents, metadata, and indexes into one binary.
*   **Less setup:** no Docker stack and no separate database to babysit.
*   **Portable:** move the file with AirDrop, iCloud, or whatever sync layer you already use.
*   **Atomic:** backup, copy, or delete one file instead of chasing state across services.

---

## Performance

Wax is tuned for M-series hardware and local recall.

### Recall Latency (p95)
*Lower is better. Measured in milliseconds.*

```text
Wax (Hybrid)  |██ 6.1ms
SQLite (Text) |████ 12ms
Cloud RAG     |██████████████████████████████████████████████████ 150ms+
```

### Cold Open Time (p95)
*Lower is better. Measured in milliseconds.*

```text
Wax           |███ 9.2ms
Traditional   |██████████████████████████████████████ 120ms+
```

> [!TIP]
> **Ingest Throughput:** Wax handles **85.9 docs/s** with full hybrid indexing on an M3 Max.
> Full benchmark report: [Resources/docs/benchmarks/2026-03-06-performance-results.md](Resources/docs/benchmarks/2026-03-06-performance-results.md)

---

## Architecture

Wax uses a frame-based container format and embeds the search engines it needs inside the main file: SQLite FTS5 for text and a Metal-accelerated HNSW index for vectors.

### Internal File Layout

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                          Dual Header Pages (A/B)                         │
│   (Magic, Version, Generation, Pointers to WAL & TOC, Checksums)         │
├──────────────────────────────────────────────────────────────────────────┤
│                          WAL (Write-Ahead Log)                           │
│   (Atomic ring buffer for crash-resilient uncommitted mutations)         │
├──────────────────────────────────────────────────────────────────────────┤
│                          Compressed Data Frames                          │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ Frame 0 (LZ4)    │  │ Frame 1 (LZ4)    │  │ Frame 2 (LZ4)    │ ...   │
│   │ [Raw Document]   │  │ [Metadata/JSON]  │  │ [System Info]    │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                          Hybrid Search Indices                           │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ SQLite FTS5 Blob             │  │ Metal HNSW Index             │     │
│   │ (Text Search + EAV Facts)    │  │ (Vector Search)              │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                          TOC (Table of Contents)                         │
│   (Index of all frames, parent-child relations, and engine manifests)    │
└──────────────────────────────────────────────────────────────────────────┘
```

1. **Atomic resilience:** dual headers and the WAL keep the store consistent even if the process dies mid-write.
2. **Unified retrieval:** one query fans out to both the BM25 text index and the HNSW vector index.
3. **Structured knowledge:** built-in EAV (Entity-Attribute-Value) storage handles durable facts and long-term reasoning.

---

## Quick Start

### Swift

```swift
import Wax

// Use a sandbox-safe, writable location (works in apps and CLI tools)
let url = URL.documentsDirectory.appending(path: "agent.wax")

// 1. Open a memory store
let memory = try await Memory(at: url)

// 2. Save a memory
try await memory.save("The user is building a habit tracker in SwiftUI.")

// 3. Search with hybrid recall (text + vector)
let results = try await memory.search("What is the user building?")

if let best = results.items.first {
    print("Found: \(best.text)")
    print("Document ID: \(best.metadata["id"] ?? "unknown")")
    // → "Found: The user is building a habit tracker in SwiftUI."
}

try await memory.close()
```

<details>
<summary><strong>SwiftUI example</strong></summary>

```swift
import SwiftUI
import Wax

struct ContentView: View {
    @State private var result = "Searching…"

    var body: some View {
        Text(result)
            .task {
                do {
                    let url = URL.documentsDirectory.appending(path: "agent.wax")
                    let memory = try await Memory(at: url)

                    try await memory.save("The user is building a habit tracker in SwiftUI.")
                    let context = try await memory.search("What is the user building?")

                    result = context.items.first?.text ?? "Nothing found"
                    try await memory.close()
                } catch {
                    result = "Error: \(error.localizedDescription)"
                }
            }
    }
}
```

</details>

<details>
<summary><strong>CLI tool (main.swift)</strong></summary>

```swift
import Wax

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL.documentsDirectory.appending(path: "agent.wax")
        let memory = try await Memory(at: url)

        try await memory.save("The user is building a habit tracker in SwiftUI.")

        let results = try await memory.search("What is the user building?")
        if let best = results.items.first {
            print("Found: \(best.text)")
        }

        try await memory.close()
    }
}
```

</details>

Looking to store persistent facts and long-term reasoning? See [Structured Memory](Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md).

### AI Coding Assistants

If you use an AI coding assistant like **Claude Code**, **Cursor**, or **Windsurf**, there are two good setup paths:

- Use the **Wax MCP server** when you want persistent memory, session handoffs, and cross-session search inside the assistant.
- Use the bundled **Wax skill** when you want the assistant to write correct Wax framework code directly against the Swift API.

**Install the MCP server (Claude Code):**

```bash
npx -y waxmcp@latest mcp install --scope user
```

**Install the skill (Claude Code):**

```bash
# From within your project directory
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax
```

Once installed, your assistant can work against `Memory`, `VideoRAGOrchestrator`, `PhotoRAGOrchestrator`, hybrid search, structured memory, and the MCP server without extra prompt scaffolding.

**Or paste this prompt to get started from scratch:**

<details>
<summary>Wax starter prompt (click to expand, then copy)</summary>

```text
Use the Wax MCP server for persistent memory in this repo.

Workflow rules:
- At session start, call `wax_handoff_latest` first to load prior context, then call `wax_session_start` once and keep the returned `session_id`.
- Use `wax_remember` to store decisions, discoveries, and short factual notes. If the memory is session-scoped, pass `session_id` as a top-level argument. Do not put `session_id` inside `metadata`.
- Use `wax_recall` for assembled context and `wax_search` for raw ranked hits.
- Prefer `mode: "hybrid"` when semantic retrieval helps. Use `mode: "text"` when I want a fast or deterministic lexical lookup.
- If you batch writes with `commit: false`, call `wax_flush` before any `wax_recall` or `wax_search`.
- Use `wax_handoff` near the end of the session with `content`, optional `project`, and `pending_tasks`, then call `wax_session_end`.
- Use `wax_corpus_search` only when you need cross-session retrieval across many session `.wax` files, such as `~/.wax/sessions`. It rebuilds or refreshes a shared corpus store and returns provenance metadata under `wax.corpus.*` so you can trace hits back to the source session store and frame.
- Use structured memory tools (`wax_entity_upsert`, `wax_fact_assert`, `wax_fact_retract`, `wax_facts_query`, `wax_entity_resolve`) for stable entities and facts, not transient debugging notes.

Behavior expectations:
- Read existing handoffs and recall results before asking me to restate prior context.
- Keep memory writes concise, factual, and scoped to the task.
- When a cross-session result looks relevant, cite the provenance metadata so we know which session store it came from.
```

</details>

---

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

---

## Ecosystem Tools

### 🤖 MCP Server
Wax provides a first-class **Model Context Protocol (MCP)** server. Connect your local memory to Claude Code or any MCP-compatible agent.

```bash
npx -y waxmcp@latest mcp install --scope user
```

For the recommended Claude Code prompt and setup flow, see [Resources/docs/wax-mcp-setup.md](Resources/docs/wax-mcp-setup.md).

### 🔍 WaxRepo
A semantic search TUI for your git history. Index any repository and find code or commits using natural language.

```bash
# From within any git repo
wax-repo index
wax-repo search "where did we implement the WAL?"
```

---

## License

Wax is released under the Apache License 2.0. See [LICENSE](LICENSE) for details.

<div align="center">
<sub>Built for developers who believe user data belongs on the user's device.</sub>
</div>
