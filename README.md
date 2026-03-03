<div align="center">
<img src="Resources/website/static/img/banner.svg" width="800" alt="Wax Banner" />

<br/>

<img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat&logo=swift&logoColor=white" />
<img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-blue?style=flat&logo=apple" />
<img src="https://img.shields.io/badge/license-MIT-green?style=flat" />
<img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat" />

<br/><br/>

# 🕯️ Wax

### On-device memory for iOS & macOS AI agents.
No server. No cloud. One file.

<br/>

</div>

---

Most iOS AI apps lose their memory the moment the user closes them. Wax fixes that — giving your agents persistent, searchable, private memory that lives entirely on-device in a single portable file.

```swift
import Wax
import WaxVectorSearchMiniLM

let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

// Store a memory
try await memory.remember("User prefers concise answers and hates bullet points.")

// Retrieve the most relevant context — semantically
let context = try await memory.recall(query: "communication preferences")
```

---

## Performance

<div align="center">
<img src="Resources/website/static/img/benchmarks.svg" width="800" alt="Wax Performance Benchmarks" />
</div>

<br/>

## Why Wax

Building AI agents on Apple platforms means juggling Core Data for persistence, FAISS or Annoy for vector search, and a tokenizer for context budgets — none of which talk to each other. Or you spin up Chroma or Pinecone and suddenly your app has a server dependency, network calls, and a privacy story you can't tell users.

Wax packages all of it into one self-contained file:

| Capability | Without Wax | With Wax |
|---|---|---|
| Document storage | Core Data / SQLite | ✅ Built-in |
| Semantic search | External FAISS / Annoy | ✅ Built-in (HNSW) |
| Full-text search | Another index | ✅ Built-in (BM25) |
| Token budgeting | Manual | ✅ Automatic |
| Crash safety | You figure it out | ✅ WAL + dual headers |
| Server required | Often | ✅ Never |

---

## Architecture

<div align="center">
<img src="https://raw.githubusercontent.com/christopherkarani/Wax/main/Resources/website/static/img/architecture.svg" width="800" alt="Wax Deep Architecture" />
</div>

<br/>

## Features

- **Hybrid retrieval** — BM25 keyword search fused with HNSW vector similarity. Gets the right memory, even when wording differs.
- **On-device embeddings** — Powered by MiniLM, running locally. No API calls, no latency, no cost.
- **Metal acceleration** — Embedding and search use Apple Silicon GPU when available.
- **Token budgets** — Set a hard limit. Wax automatically trims and compresses context to fit, every time.
- **Tiered surrogates** — Store full text, a gist, or a micro-summary. Trade recall for speed at query time.
- **Single portable file** — The whole memory store is one `.wax` file. Back it up, sync it, move it.
- **Crash-safe by design** — Append-only format with write-ahead logging and dual headers. No corruption on unexpected exits.
- **Swift 6 concurrency** — Fully `async/await` native with `Sendable` conformances throughout.

---

## Installation

**Swift Package Manager**

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

Or in Xcode: **File → Add Package Dependencies** → paste the repo URL.

## MCP Installer (npm)

```bash
npx -y waxmcp@latest mcp install --scope user
```

## Claude Code Integration

After installing the MCP server, add this to your `CLAUDE.md` so Claude Code uses Wax as its memory:

<details>
<summary><strong>CLAUDE.md snippet</strong> (click to expand)</summary>

```markdown
## Rules

1. **Session start** — call `wax_handoff_latest` to resume prior context
2. **Before answering** — call `wax_recall` to check what you already know. Always try this first.
3. **When you learn something durable** — call `wax_remember`. Worth storing: user preferences, project decisions, architectural patterns, conventions, people/roles. Not worth storing: transient debugging, one-off commands.
4. **When corrected** — call `wax_forget` with what changed (e.g. "we don't use Redux anymore")
5. **Session end** — call `wax_handoff` with summary + pending tasks

## Tools

| Tool | When |
|------|------|
| `wax_remember` | User states a preference, makes a decision, or you learn a stable pattern. `project` to scope. |
| `wax_recall` | Before answering anything that might have prior context. Use `graph: true` for relationship-aware search. |
| `wax_forget` | User corrects you or facts become outdated. Natural language or `fact_id`. |
| `wax_context` | Need the full picture of a specific entity (person, project, library). |
| `wax_reflect` | Audit what you know — entity counts, top predicates, memory health. |
| `wax_handoff` | Session ending. Pass `pending_tasks` array for continuity. |
| `wax_handoff_latest` | Session starting. Loads last handoff. |
```

</details>

---

## Quick Start

```swift
import Wax
import WaxVectorSearchMiniLM

// 1. Open (or create) a memory store
let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "myagent.wax")
)

// 2. Store memories
try await memory.remember("The user's name is Alex and they live in Toronto.")
try await memory.remember("Alex dislikes formal language. Keep responses casual.")
try await memory.remember("Alex is building a habit tracker in SwiftUI.")

// 3. Retrieve relevant context for a prompt
let context = try await memory.recall(query: "how should I address the user?")
print(context.items.map(\.text))
```

---

## Use Cases

- **Conversational agents** that remember preferences, history, and facts across sessions
- **Note-taking apps** with semantic search ("find everything I wrote about WWDC")
- **Photo & video apps** that index captions and transcripts for natural-language lookup
- **Personal assistants** that learn user habits without sending data off-device
- **RAG pipelines** built entirely on-device for sensitive or offline-first applications

---

## Requirements

| | Minimum |
|---|---|
| Swift | 6.2 |
| iOS | 17.0 |
| macOS | 14.0 |
| Xcode | 16.0 |

Apple Silicon recommended for GPU-accelerated embedding. Intel Macs fall back to CPU seamlessly.

---

## Comparison

| | Wax | ChromaDB | Pinecone | Core Data + FAISS |
|---|---|---|---|---|
| On-device | ✅ | ❌ | ❌ | ✅ |
| No server | ✅ | ❌ | ❌ | ✅ |
| Hybrid search | ✅ | ✅ | ✅ | Manual |
| Token budgeting | ✅ | ❌ | ❌ | ❌ |
| Single file | ✅ | ❌ | ❌ | ❌ |
| Swift-native API | ✅ | ❌ | ❌ | Partial |
| Privacy (data stays on device) | ✅ | ❌ | ❌ | ✅ |

---

## Roadmap

- [ ] CloudKit sync (opt-in, encrypted)
- [ ] iCloud Drive `.wax` document support
- [ ] Memory clustering and deduplication
- [ ] Quantized embedding models for smaller footprint
- [ ] Instruments template for memory profiling

---

## Contributing

Issues and PRs are welcome. If you're building something with Wax, open a Discussion — would love to see what you're working on.

---

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=christopherkarani/wax&type=date&legend=top-left)](https://www.star-history.com/#christopherkarani/wax&type=date&legend=top-left)

## License

Apache 2.0 © [Christopher Karani](https://github.com/christopherkarani)

---

<div align="center">
<sub>Built for developers who believe user data belongs on the user's device.</sub>
</div>
