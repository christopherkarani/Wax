
<p align="center">
  <img src="https://github.com/user-attachments/assets/5740a66d-21c2-4980-b6be-06ab1ff1bc68" width="120" alt="Wax Logo">
</p>

<h1 align="center">Wax</h1>

<p align="center">
  <strong>The SQLite for AI memory.</strong><br>
  One file. Full RAG. Zero infrastructure.
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#performance">Performance</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#installation">Install</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2-orange.svg" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/platforms-iOS%2026%20%7C%20macOS%2026-blue.svg" alt="Platforms">
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License">
</p>

---

## 30-Second Demo

```swift
import Wax

// Create a memory file
let brain = try await MemoryOrchestrator(
    at: URL(fileURLWithPath: "brain.mv2s")
)

// Remember something
try await brain.remember(
    "User prefers dark mode and gets headaches from bright screens",
    metadata: ["source": "onboarding"]
)

// Recall with RAG
let context = try await brain.recall(query: "user preferences")
// → "User prefers dark mode and gets headaches from bright screens"
//   + relevant context, ranked and token-budgeted
```

**That's it.** No Docker. No vector DB. No network calls.

---

## The Problem

You wanted to add memory to your AI app.

3 hours later you're still configuring Docker Compose for a vector database that crashes if you look at it wrong, sends your data to who-knows-where, and needs a DevOps team to keep running.

**Wax replaces your entire RAG stack with a file format.**

```
Traditional RAG Stack:                     Wax:
┌─────────────┐                           ┌─────────────┐
│  Your App   │                           │  Your App   │
├─────────────┤                           ├─────────────┤
│  ChromaDB   │                           │             │
│  PostgreSQL │        vs.                │   brain.    │
│  Redis      │                           │    mv2s     │
│  Elasticsearch│                         │             │
│  Docker     │                           │             │
└─────────────┘                           └─────────────┘
     ~5 services                              1 file
```

---

## Why Wax?

| | |
|:---|:---|
| ⚡ **Fast** | 0.84ms vector search @ 10K docs (Metal GPU) |
| 🛡️ **Durable** | Kill -9 safe, power-loss safe, tested |
| 🎯 **Deterministic** | Same query = same context, every time |
| 📦 **Portable** | One `.mv2s` file — move it, backup it, ship it |
| 🔒 **Private** | 100% on-device. Zero network calls. |

---

## Performance

Apple Silicon (M1 Pro)

```
Vector Search Latency (10K × 384-dim)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Wax Metal (warm)     ████░░░░░░░░░░░░░░░░  0.84ms
Wax Metal (cold)     █████████████████░░░  9.2ms
Wax CPU              ███████████░░░░░░░░░  105ms
SQLite FTS5          ██████████████████░░  150ms
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Cold Open → First Query: 17ms
Hybrid Search @ 10K docs: 105ms
```

*No, that's not a typo. GPU vector search really is sub-millisecond.*

---

## Quick Start

### 1. Add to Package.swift

```swift
.package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.1")
```

### 2. Choose Your Memory Type

<details>
<summary><b>📝 Text Memory</b> — Documents, notes, conversations</summary>

```swift
import Wax

let orchestrator = try await MemoryOrchestrator(at: storeURL)

// Ingest
try await orchestrator.remember(documentText, metadata: ["source": "report.pdf"])

// Recall
let context = try await orchestrator.recall(query: "key findings")
for item in context.items {
    print("[\(item.kind)] \(item.text)")
}
```
</details>

<details>
<summary><b>📸 Photo Memory</b> — Photo library with OCR + CLIP embeddings</summary>

```swift
import Wax

let photoRAG = try await PhotoRAGOrchestrator(
    storeURL: storeURL,
    config: .default,
    embedder: MyCLIPEmbedder()  // Your CoreML model
)

// Index local photos (offline-only)
try await photoRAG.syncLibrary(scope: .fullLibrary)

// Search
let ctx = try await photoRAG.recall(.init(text: "Costco receipt"))
```
</details>

<details>
<summary><b>🎬 Video Memory</b> — Video segments with transcripts</summary>

```swift
import Wax

let videoRAG = try await VideoRAGOrchestrator(
    storeURL: storeURL,
    config: .default,
    embedder: MyEmbedder(),
    transcriptProvider: MyTranscriber()
)

// Ingest
try await videoRAG.ingest(files: [videoFile])

// Search by content or transcript
let ctx = try await videoRAG.recall(.init(text: "project timeline discussion"))
```
</details>

---

## How It Works

Wax packs everything into a **single `.mv2s` file**:

- ✅ Your raw documents
- ✅ Embeddings (any dimension, any provider)
- ✅ BM25 full-text search index (FTS5)
- ✅ HNSW vector index (USearch)
- ✅ Write-ahead log for crash recovery
- ✅ Metadata & entity graph

**The file format is:**
- **Append-only** — Fast writes, no fragmentation
- **Checksum-verified** — Every byte validated
- **Dual-header** — Atomic updates, never corrupt
- **Self-contained** — No external dependencies

```
┌─────────────────────────────────────────┐
│  Header Page A (4KB)                    │
│  Header Page B (4KB) ← atomic switch    │
├─────────────────────────────────────────┤
│  WAL Ring Buffer                        │
│  (crash recovery log)                   │
├─────────────────────────────────────────┤
│  Document Payloads (compressed)         │
│  Embeddings                             │
├─────────────────────────────────────────┤
│  TOC (Table of Contents)                │
│  Footer + Checksum                      │
└─────────────────────────────────────────┘
```

---

## Comparison

| Feature | Wax | Chroma | Core Data + FAISS | Pinecone |
|--------:|:---:|:------:|:-----------------:|:--------:|
| Single file | ✅ | ❌ | ❌ | ❌ |
| Works offline | ✅ | ⚠️ | ✅ | ❌ |
| Crash-safe | ✅ | ❌ | ⚠️ | N/A |
| GPU vector search | ✅ | ❌ | ❌ | ❌ |
| No server required | ✅ | ✅ | ✅ | ❌ |
| Swift-native | ✅ | ❌ | ✅ | ❌ |
| Deterministic RAG | ✅ | ❌ | ❌ | ❌ |

---

## Features That Actually Matter

**🧠 Query-Adaptive Hybrid Search**

Wax doesn't just do vector search. It runs multiple lanes in parallel (BM25, vector, temporal, structured evidence) and fuses results based on query type.

"When was my last dentist appointment?" → boosts temporal + structured  
"Explain quantum computing" → boosts vector + BM25

**🎭 Tiered Memory Compression (Surrogates)**

Not all context is equal. Wax generates hierarchical summaries:
- `full` — Complete document (for deep dives)
- `gist` — Key paragraphs (for balanced recall)
- `micro` — One-liner (for quick context)

At query time, it picks the right tier based on query signals and remaining token budget.

**🎯 Deterministic Token Budgeting**

Strict `cl100k_base` token counting. No "oops, context window exceeded." No non-deterministic truncation. Reproducible RAG you can test and benchmark.

---

## Perfect For

- 🤖 **AI assistants** that remember users across launches
- 📱 **Offline-first apps** with serious search requirements
- 🔒 **Privacy-critical products** where data never leaves the device
- 🧪 **Research tooling** that needs reproducible retrieval
- 🎮 **Agent workflows** that require durable state

---

## Requirements

- Swift 6.2
- iOS 26 / macOS 26
- Apple Silicon (for Metal GPU features)

---

## Contributing

```bash
git clone https://github.com/christopherkarani/Wax.git
cd Wax
swift test
```

MiniLM CoreML tests are opt-in:
```bash
WAX_TEST_MINILM=1 swift test
```

---

<div align="center">

### Ready to stop shipping databases?

**[⭐ Star Wax on GitHub](https://github.com/christopherkarani/Wax)** • **[📖 Read the Docs](gemini.md)** • **[🐛 Report Issues](../../issues)**

Built with 🍯 by [Christopher Karani](https://github.com/christopherkarani)

</div>
