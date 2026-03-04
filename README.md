<!-- HEADER:START -->
<div align="center">
<img src="Resources/website/static/img/banner.svg" width="800" alt="Wax Banner" />
</div>
<!-- HEADER:END -->

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax is a single-file memory layer for AI agents on Apple platforms.</strong><br/>
  On-device, private, and portable — no server, no cloud, one <code>.wax</code> file.
</p>

<!-- NAV:START -->
<p align="center">
  <a href="https://wax.sh">Website</a>
  ·
  <a href="https://wax.sh/docs">Docs</a>
  ·
  <a href="https://github.com/christopherkarani/Wax/discussions">Discussions</a>
</p>
<!-- NAV:END -->

<!-- BADGES:START -->
<p align="center">
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=SPM" alt="Swift Package" /></a>
  <a href="https://www.npmjs.com/package/waxmcp"><img src="https://img.shields.io/npm/v/waxmcp?style=flat-square&logo=npm" alt="npm" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
  <a href="https://github.com/christopherkarani/Wax/network/members"><img src="https://img.shields.io/github/forks/christopherkarani/Wax?style=flat-square&logo=github" alt="Forks" /></a>
  <a href="https://github.com/christopherkarani/Wax/issues"><img src="https://img.shields.io/github/issues/christopherkarani/Wax?style=flat-square&logo=github" alt="Issues" /></a>
</p>
<!-- BADGES:END -->

---

## What is Wax?

Most iOS AI apps lose their memory the moment the user closes them. Wax fixes that.

Wax is a portable AI memory system that packages documents, embeddings, search indices, and metadata into a single `.wax` file. Instead of juggling Core Data, FAISS, Pinecone, or spinning up vector database servers, Wax gives your agents persistent, searchable, private memory that lives entirely on-device.

The result is a Swift-native, infrastructure-free memory layer that gives AI agents long-term memory they can carry anywhere — no network calls, no API keys, no privacy trade-offs.


## What are Smart Frames?

Wax organizes AI memory as an **append-only sequence of Smart Frames**, inspired by video encoding.

A Smart Frame is an immutable unit that stores content along with timestamps, checksums, embeddings, and metadata. Frames support tiered surrogates — store full text, a gist, or a micro-summary and trade recall for speed at query time.

This frame-based design enables:

- Append-only writes without modifying or corrupting existing data
- Timeline-style inspection of how knowledge evolves
- Crash safety through committed, immutable frames and WAL
- Efficient compression using LZ4/zlib
- Dual-header redundancy for corruption resilience


## Core Concepts

- **Hybrid Retrieval** — BM25 keyword search fused with HNSW vector similarity. Gets the right memory, even when wording differs.

- **On-Device Embeddings** — Powered by MiniLM, running locally via CoreML and Metal. No API calls, no latency, no cost.

- **Token Budgets** — Set a hard limit. Wax automatically trims and compresses context to fit, every time.

- **Knowledge Graph** — Entity-relationship triples with fact versioning. Assert, retract, and query structured knowledge alongside unstructured memory.

- **Session Handoffs** — First-class session lifecycle with `handoff` / `handoff-latest` for seamless continuity across conversations.

- **Single Portable File** — The whole memory store is one `.wax` file. Back it up, sync it, move it.


## Use Cases

- **Conversational agents** that remember preferences, history, and facts across sessions
- **Note-taking apps** with semantic search ("find everything I wrote about WWDC")
- **Personal assistants** that learn user habits without sending data off-device
- **RAG pipelines** built entirely on-device for sensitive or offline-first applications
- **Claude Code / MCP agents** with persistent long-term memory via the MCP server
- **Video RAG** — index transcripts and captions for natural-language video search


## SDKs & CLI

| Package | Install | Description |
|---|---|---|
| **Swift SDK** | Swift Package Manager | Core library for iOS & macOS apps |
| **MCP Server** | `npx -y waxmcp@latest mcp install` | Claude Code / MCP integration |
| **CLI** | `npx -y waxmcp@latest` | Terminal commands for remember, recall, search |

---

## Installation

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Wax", package: "Wax"),
            .product(name: "WaxVectorSearchMiniLM", package: "Wax")
        ]
    )
]
```

Or in Xcode: **File > Add Package Dependencies** > paste the repo URL.

### MCP Server (Claude Code)

```bash
npx -y waxmcp@latest mcp install --scope user
```

### Modules

| Module | Purpose |
|---|---|
| `Wax` | Full orchestrator with hybrid search, RAG, knowledge graph |
| `WaxCore` | Low-level frame storage, WAL, commit engine |
| `WaxTextSearch` | BM25 full-text search (GRDB + FTS5) |
| `WaxVectorSearch` | HNSW vector similarity search (USearch) |
| `WaxVectorSearchMiniLM` | On-device MiniLM embedding provider |

---

## Quick Start

```swift
import Wax
import WaxVectorSearchMiniLM

// 1. Open (or create) a memory store
let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

// 2. Store memories
try await memory.remember("User prefers concise answers and hates bullet points.")
try await memory.remember("The user's name is Alex and they live in Toronto.")
try await memory.remember("Alex is building a habit tracker in SwiftUI.")

// 3. Retrieve relevant context — semantically
let context = try await memory.recall(query: "how should I address the user?")
print(context.items.map(\.text))
// ["The user's name is Alex and they live in Toronto.",
//  "User prefers concise answers and hates bullet points."]
```

### Knowledge Graph

```swift
// Create entities
try await memory.upsertEntity(key: "person:alex", kind: "person", aliases: ["Alex", "the user"])

// Assert facts
try await memory.assertFact(subject: "person:alex", predicate: "lives_in", object: "Toronto")
try await memory.assertFact(subject: "person:alex", predicate: "building", object: "habit tracker")

// Query facts
let facts = try await memory.facts(subject: "person:alex")
```

### Session Handoffs

```swift
// End of session — save context for next time
try await memory.rememberHandoff(
    summary: "Helped Alex debug a SwiftUI layout issue",
    project: "habit-tracker",
    pendingTasks: ["Fix the tab bar animation", "Add onboarding flow"]
)

// Start of next session — pick up where you left off
if let handoff = try await memory.latestHandoff(project: "habit-tracker") {
    print(handoff.summary)
    print(handoff.pendingTasks)
}
```

---

## Claude Code Integration

After installing the MCP server, add this to your `CLAUDE.md` so Claude Code uses Wax as its memory:

<details>
<summary><strong>CLAUDE.md snippet</strong> (click to expand)</summary>

```markdown
## Rules

1. **Session start** — call `wax_handoff_latest` to resume prior context
2. **Before answering** — call `wax_recall` to check what you already know
3. **When you learn something durable** — call `wax_remember`
4. **When corrected** — call `wax_forget` with what changed
5. **Session end** — call `wax_handoff` with summary + pending tasks

## Tools

| Tool | When |
|------|------|
| `wax_remember` | User states a preference, makes a decision, or you learn a stable pattern |
| `wax_recall` | Before answering anything that might have prior context |
| `wax_forget` | User corrects you or facts become outdated |
| `wax_context` | Need the full picture of a specific entity |
| `wax_reflect` | Audit what you know — entity counts, top predicates, memory health |
| `wax_handoff` | Session ending. Pass `pending_tasks` array for continuity |
| `wax_handoff_latest` | Session starting. Loads last handoff |
```

</details>

---

## Architecture

<div align="center">
<img src="https://raw.githubusercontent.com/christopherkarani/Wax/main/Resources/website/static/img/architecture.svg" width="800" alt="Wax Architecture" />
</div>

---

## Performance

<div align="center">
<img src="Resources/website/static/img/benchmarks.svg" width="800" alt="Wax Performance Benchmarks" />
</div>

---

## File Format

Everything lives in a single `.wax` file:

```
┌────────────────────────────┐
│ Header Pages (dual)        │  Magic, version, TOC pointer
├────────────────────────────┤
│ WAL Ring Buffer             │  Crash recovery
├────────────────────────────┤
│ Data Segments              │  LZ4/zlib compressed frames
├────────────────────────────┤
│ Text Index                 │  FTS5 full-text (BM25)
├────────────────────────────┤
│ Vector Index               │  HNSW embeddings (USearch)
├────────────────────────────┤
│ Knowledge Graph            │  Entity-fact triples
├────────────────────────────┤
│ TOC (Footer)               │  Segment offsets + checksums
└────────────────────────────┘
```

No `.wal`, `.lock`, `.shm`, or sidecar files. Ever.

---

## Comparison

| | Wax | ChromaDB | Pinecone | Core Data + FAISS |
|---|---|---|---|---|
| On-device | Yes | No | No | Yes |
| No server | Yes | No | No | Yes |
| Hybrid search | Yes | Yes | Yes | Manual |
| Token budgeting | Yes | No | No | No |
| Knowledge graph | Yes | No | No | No |
| Single file | Yes | No | No | No |
| Swift-native API | Yes | No | No | Partial |
| MCP server | Yes | No | No | No |
| Privacy (data stays on device) | Yes | No | No | Yes |

---

## Requirements

| | Minimum |
|---|---|
| Swift | 6.1+ |
| iOS | 18.0 |
| macOS | 15.0 |
| Xcode | 16.0 |

Apple Silicon recommended for Metal-accelerated embedding. Intel Macs fall back to CPU seamlessly.

---

## Roadmap

- [ ] CloudKit sync (opt-in, encrypted)
- [ ] iCloud Drive `.wax` document support
- [ ] Memory clustering and deduplication
- [ ] Quantized embedding models for smaller footprint
- [ ] Instruments template for memory profiling

---

## Contributing

Issues and PRs are welcome. If you're building something with Wax, [open a Discussion](https://github.com/christopherkarani/Wax/discussions) — would love to see what you're working on.

---

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=christopherkarani/wax&type=date&legend=top-left)](https://www.star-history.com/#christopherkarani/wax&type=date&legend=top-left)

---

## License

Apache License 2.0 — see the [LICENSE](LICENSE) file for details.

---

<div align="center">
<sub>Built for developers who believe user data belongs on the user's device.</sub>
</div>
