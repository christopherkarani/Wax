

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
| **Metal GPU vector search (warm)** | 0.84ms | 10K × 384-dim |
| **Cold open → first query** | 17ms p50 | Ready for interactive use |
| **GPU warm vs cold** | 10.9× faster | Lazy sync |
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
| Search latency (1K × 128d) | 1.86ms avg |
| Latency per vector | 0.0019ms |
| Cold sync (10K × 384d) | 9.19ms |
| Warm search (10K × 384d) | 0.84ms |
| Memory saved per warm query | 14.6 MB |

*Benchmarks run on Apple Silicon. Run `swift test --filter RAGPerformanceBenchmarks` to reproduce.*  
*Optional benchmark suites are opt-in via env flags: `WAX_BENCHMARK_MINILM=1`, `WAX_BENCHMARK_METAL=1`, `WAX_BENCHMARK_10K=1`, `WAX_BENCHMARK_METRICS=1`, `WAX_BENCHMARK_SAMPLES=1`, `WAX_BENCHMARK_OPTIMIZATION=1`.*

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

- ⚡ **Query-adaptive hybrid retrieval**  
  Unified search fuses lexical (BM25), vector, temporal, and structured-evidence lanes with query-type–aware weights.

- 🧮 **Deterministic RAG**  
  Strict token budgets (cl100k_base) + deterministic tie-breaks → reproducible contexts you can test and benchmark.

- 🎭 **Tiered memory compression (surrogates)**  
  Generate hierarchical surrogates (`full` / `gist` / `micro`) offline, keep them up-to-date, and select the right tier at retrieval time.

- 🚀 **GPU-accelerated vector search (Metal)**  
  Zero-copy, unified-memory search for interactive latency (with automatic CPU fallback).

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
- **Append-only frames + ring-buffer WAL**: fast writes, crash-safe recovery, and predictable on-device performance.
- **Two-phase indexing**: stage → commit for atomic index updates (vector + FTS + structured memory).
- **Unified search**: one request, multiple lanes (text/vector/temporal/structured evidence) with deterministic fusion.
- **Deterministic RAG builder**: single expansion + tiered surrogates + ranked snippets under a strict token budget.
- **Protocol-driven embeddings**: swap providers (and batch embedders) without touching storage or retrieval code paths.

## Researcher Notes

- Deterministic token counting and truncation (cl100k_base).
- Unified retrieval with query-type adaptive fusion.
- Reproducible RAG contexts (single expansion, surrogates, ranked snippets).

## Requirements

- Swift 6.2
- iOS 26 / macOS 26

## Installation

Add Wax as a Swift Package dependency.

```swift
.package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.1")
```

Then add targets as needed:

```swift
.product(name: "Wax", package: "Wax")
```

## PDF Ingestion

```swift
import Wax

let storeURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("wax-memory")
    .appendingPathExtension("mv2s")
var config = OrchestratorConfig.default
config.enableVectorSearch = false
let orchestrator = try await MemoryOrchestrator(at: storeURL, config: config)
try await orchestrator.remember(
    pdfAt: URL(fileURLWithPath: "/path/to/report.pdf"),
    metadata: ["source": "report"]
)
let ctx = try await orchestrator.recall(query: "key findings")
try await orchestrator.flush()
```

*Note: v1 supports text-based PDFs only (no OCR).*

## Contributing

We welcome issues and PRs. For local validation:

```bash
cd Wax
swift test
```

If you're exploring the file format or retrieval research, start with the core engine (`Sources/WaxCore/`) and the benchmarks (`Tests/WaxIntegrationTests/`). We are especially interested in:
- Retrieval quality evaluations and reproducibility studies
- On-device memory benchmarks
- New embedding adapters and pruning/compaction strategies
