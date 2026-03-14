<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
    <img src="docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax is a high-performance, single-file memory layer for AI agents on Apple platforms.</strong><br/>
  On-device, private, and portable — no server, no cloud, zero infrastructure.
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=Swift" alt="Swift" /></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square" alt="Platforms" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="locales/README.es.md">Español</a> · <a href="locales/README.fr.md">Français</a> · <a href="locales/README.ja.md">日本語</a> · <a href="locales/README.ko.md">한국어</a> · <a href="locales/README.pt.md">Português</a> · <a href="locales/README.zh-CN.md">中文</a>
</p>
<!-- HEADER:END -->

---

## What is Wax?

Wax is a Swift-native persistence engine designed for the next generation of AI agents. It encapsulates documents, high-dimensional embeddings, and structured knowledge into a single, portable `.wax` file.

Unlike traditional databases that require complex setups or cloud dependencies, Wax provides a **unified memory layer** that lives entirely on-device, leveraging Metal-accelerated inference for sub-10ms recall latency.

### Why Wax?

| Feature          | Wax                    | SQLite (FTS5)          | Cloud Vector DBs       |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **Search**       | Hybrid (Text + Vector) | Text Only*             | Vector Only*           |
| **Latency**      | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **Privacy**      | 100% Local             | 100% Local             | Cloud-hosted           |
| **Setup**        | Zero Config            | Low                    | Complex (API Keys)     |
| **Architecture** | Apple Silicon Native   | Generic                | Varies                 |

### 📦 Why a Single `.wax` File?
Most RAG systems require a database, a vector store, and a file server. Wax bundles everything—documents, metadata, and high-dimensional indices—into one portable binary.
*   **Zero Infrastructure:** No Docker, no DB setup, no cloud bill.
*   **Truly Portable:** AirDrop your agent's memory to another Mac, or sync it via iCloud.
*   **Atomic:** One file to backup, one file to version control, one file to delete.

---

## Performance

Wax is tuned for the M-series architecture, providing near-instantaneous recall even with large-scale local indices.

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
> Full benchmark report: [docs/benchmarks/2026-03-06-performance-results.md](docs/benchmarks/2026-03-06-performance-results.md)

---

## Architecture

Wax uses a **"Database of Databases"** model. It manages its own frame-based storage format while embedding specialized search engines (SQLite FTS5 and Metal-accelerated HNSW) as serialized blobs within the main file.

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

1. **Atomic Resilience**: Dual-headers and WAL ensure that even if the process crashes mid-write, the store remains consistent.
2. **Unified Retrieval**: A single query triggers parallel execution across the BM25 (text) and HNSW (vector) engines.
3. **Structured Knowledge**: Built-in EAV (Entity-Attribute-Value) storage for persistent facts and long-term reasoning.

---

## Quick Start

### Swift

Copy and paste this into a `main.swift` file to get started immediately.

```swift
import Wax

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL(fileURLWithPath: "agent.wax")

        // 1. Open a memory store
        let memory = try await Memory(at: url)

        // 2. Save a memory
        try await memory.save("The user is building a habit tracker in SwiftUI.")

        // 3. Search with hybrid recall (text + vector)
        let results = try await memory.search("What is the user building?")

        if let best = results.items.first {
            print("Found: \(best.text)")
            // Output: "Found: The user is building a habit tracker in SwiftUI."
        }

        try await memory.close()
    }
}
```

Looking to store persistent facts and long-term reasoning? See [Structured Memory](Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md).

### AI Coding Assistants

If you use an AI coding assistant like **Claude Code**, **Cursor**, or **Windsurf**, you can get up to speed instantly with the bundled **Wax skill** — it teaches your assistant the full Wax API, constraints, and best practices so it writes correct Wax code on the first try.

**Install the skill (Claude Code):**

```bash
# From within your project directory
claude install-skill https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax
```

Once installed, your assistant automatically knows how to use `Memory`, `VideoRAGOrchestrator`, `PhotoRAGOrchestrator`, hybrid search, structured memory, and the MCP server — no copy-pasting docs.

**Or paste this prompt to get started from scratch:**

<details>
<summary>Wax starter prompt (click to expand, then copy)</summary>

```text
I'm integrating the Wax framework (https://github.com/christopherkarani/Wax) into my Swift project.
Wax is an on-device, single-file (.wax) memory and RAG engine for Apple platforms.

Here's what I need you to know:
- The public API is the `Memory` actor — import `Wax` and use `Memory(at: url)` to open a store.
- Use `.save(_:)` to persist text and `.search(_:)` to retrieve ranked results as `RAGContext`.
- Wax ships with on-device MiniLM embeddings (384-dim, CoreML) enabled by default for hybrid search (BM25 text + HNSW vector). Pass `enableVectorSearch: false` in `Memory.Config` for text-only mode.
- Configuration is done through `Memory.Config` (text search, vector search, structured memory, enrichment) and `Memory.SearchOptions` (topK, retrieval mode, time range, surrogates).
- For video RAG, use `VideoRAGOrchestrator` with a `MultimodalEmbeddingProvider` and `VideoTranscriptProvider`.
- For photo RAG, use `PhotoRAGOrchestrator` with the Photos framework.
- Lifecycle: always call `.flush()` to persist pending writes, and `.close()` when done.
- The `.wax` file is the single source of truth — data, indices, and WAL in one portable binary. No server, no cloud, no infrastructure.
- Everything runs on-device with Metal-accelerated vector search. Typical recall latency is ~6ms (p95).

Please read the Wax source code in my project's dependencies to understand the full API surface before writing any integration code.
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
