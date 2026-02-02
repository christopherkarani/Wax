

![unnamed-11](https://github.com/user-attachments/assets/5740a66d-21c2-4980-b6be-06ab1ff1bc68)

# 🍯 Wax  
### The Swift-native, single-file memory engine for AI

**Persistent, on-device RAG — without servers, databases, or pipelines.**

| 🧠 On-device memory | 🔍 Hybrid search | 💾 Single-file persistence |
|---|---|---|

Wax is a **portable AI memory system** that packages:
- your data
- embeddings
- search indexes
- metadata
- and recovery logs  

into **one deterministic file**.

Instead of shipping fragile RAG stacks or depending on server-side vector databases,  
**Wax lets AI retrieve knowledge directly from disk — fast, offline, and reproducibly.**

Your agent doesn’t *query infrastructure*.  
It **carries its memory with it.**

⭐ If this repo is useful, please consider starring it — it genuinely helps.

---

## Why Wax exists

Most RAG systems assume:
- 🌐 cloud inference
- 🧱 external vector databases
- 🕸 network latency
- 🔓 data leaving the device
- 🧮 non-deterministic context assembly

Wax flips that model:

- **100% on-device**
- **single-file state**
- **crash-safe by default**
- **deterministic retrieval**
- **Swift-native concurrency**

This makes Wax ideal for **agents, assistants, research tools, and privacy-first apps** that need *real memory*, not prompt hacks.

---

## 📊 Performance (Apple Silicon)

Wax is designed for **interactive latency**, not server throughput.

| Benchmark | Result | Notes |
|---------|--------|-------|
| **Hybrid search @ 10K docs** | 105ms | Near-constant scaling |
| **Metal GPU vector search** | 1.42ms | 10K × 384-dim |
| **Cold open → first query** | 17ms p50 | Ready instantly |
| **GPU warm vs cold** | 6.7× faster | Lazy sync + SIMD8 |
| **Buffer serialization** | 16.5× faster | vs file I/O |

<details>
<summary><b>Full benchmark breakdown</b></summary>

### Core RAG Pipeline

| Test | Avg Latency | RSD |
|------|-------------|-----|
| Hybrid Search @ 1K docs | 105ms | 3.4% |
| FastRAG DenseCached | 105ms | 3.4% |
| FastRAG Fast Mode | 106ms | 3.1% |
| Orchestrator Ingest (batched) | 309ms | 1.7% |
| Cold Open + First Search | 599ms | — |

### Metal GPU Performance

| Metric | Value |
|--------|-------|
| Search latency (1K × 128d) | 1.29ms avg |
| Latency per vector | 0.0013ms |
| Cold sync (10K × 384d) | 9.5ms |
| Warm search (10K × 384d) | 1.42ms |
| Memory saved per warm query | 14.6 MB |

*Benchmarks run on Apple Silicon. Run `swift test --filter RAGPerformanceBenchmarks` to reproduce.*

</details>

---

## ✨ What makes Wax different

**Stop shipping AI that forgets.**

Wax gives your users AI that:
- remembers across launches
- survives crashes
- behaves deterministically
- works offline
- scales without infra

**The core advantages:**

- 🧠 **One file, complete memory**  
  A single `.mv2s` file contains data, indexes, and WAL — nothing else required.

- 🔒 **Crash-safe persistence**  
  Power loss, app kills, and upgrades are first-class concerns, not edge cases.

- ⚡ **Hybrid retrieval engine**  
  Lexical + vector + temporal fusion, tuned for on-device latency.

- 🧮 **Deterministic RAG**  
  Stable token counts and reproducible contexts — ideal for research and testing.

- 🎭 **Swift-native design**  
  Actor-isolated, async-first, written for Swift 6.2 concurrency.

- 🧩 **Composable by design**  
  Use Wax as a store, a search engine, or a full RAG pipeline.

---

## 🚀 Perfect for

- **AI assistants** that remember users over time  
- **Offline-first apps** with serious search requirements  
- **Privacy-critical products** where data never leaves the device  
- **Research tooling** that needs reproducible retrieval  
- **Agent workflows** that require durable state

---

If Wax saved you time, removed infrastructure, or made on-device AI simpler,  
**consider starring the repo** ⭐ — it helps guide the project’s direction.

## Architectural Choices

- **Actor-owned core (`Wax`)**: isolates mutable state and I/O, making correctness the default on mobile.
- **Append-only frames + WAL**: fast writes, safe recovery, and predictable performance under load.
- **Two-phase indexing**: stage, then commit; keeps ingestion fast while guaranteeing atomic index updates.
- **Adaptive hybrid fusion**: query-type–aware weighting (text/vector/temporal) improves relevance without user tuning.
- **Deterministic RAG builder**: single expansion + ranked snippets + surrogate support gives stable, testable contexts.
- **Protocol-driven embeddings**: swap local models without touching the core store or search paths.

## Researcher Notes

- Deterministic token counting and truncation (cl100k_base).
- Unified retrieval with query-type adaptive fusion.
- Reproducible RAG contexts (single expansion, ranked snippets, surrogate support).

## Requirements

- Swift 6.2
- iOS 26 / macOS 26

## Installation

Add Wax as a Swift Package dependency.

```swift
.package(url: ["<REPO_URL>"](https://github.com/christopherkarani/Wax), from: "0.1.1")
```

Then add targets as needed:

```swift
.product(name: "Wax", package: "Wax")
```

## Contributing

We welcome issues and PRs. For local validation:

```bash
cd Wax
swift test
```

If you're exploring the MV2S format or retrieval research, start with `MV2S_SPEC.md` and the phase docs. We are especially interested in:
- Retrieval quality evaluations and reproducibility studies
- On-device memory benchmarks
- New embedding adapters and pruning/compaction strategies
