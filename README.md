
<p align="center">
  <img src="https://github.com/user-attachments/assets/5740a66d-21c2-4980-b6be-06ab1ff1bc68" width="120" alt="Wax Logo">
</p>

<h1 align="center">Wax</h1>

<p align="center">
  On-device RAG for Swift. Documents, embeddings, BM25 and HNSW indexes in a single file.
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
  <img src="https://img.shields.io/badge/license-Apache_2.0-green.svg" alt="License">
</p>

---

## 30-Second Demo

```swift
import Wax

// Create a memory file (text search, works out of the box)
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

Want hybrid vector + text search? Use the built-in MiniLM embedder:

```swift
// Hybrid search with on-device embeddings (MiniLM, 384-dim)
let brain = try await MemoryOrchestrator.openMiniLM(
    at: URL(fileURLWithPath: "brain.mv2s")
)
```

No Docker. No network calls.

---

## The Problem

Adding memory to an iOS or macOS app typically means standing up a vector database, a text search index, and a persistence layer — three services with separate setup, uptime dependencies, and potential data egress.

Wax stores all of it in a single `.mv2s` file on the user's device.

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
| **Fast** | 0.84ms vector search @ 10K docs (Metal GPU) |
| **Durable** | Kill -9 safe, power-loss safe, tested |
| **Deterministic** | Same query = same context, every time |
| **Portable** | One `.mv2s` file — move it, backup it, ship it |
| **Private** | 100% on-device. Zero network calls. |

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

### Core Benchmark Baselines (as of February 17, 2026)

These are reproducible XCTest benchmark baselines captured from the current Wax benchmark harness.

#### Ingest throughput (`testIngestHybridBatchedPerformance`)

| Workload | Time | Throughput |
|:---|---:|---:|
| smoke (200 docs) | `0.103s` | `~1941.7 docs/s` |
| standard (1000 docs) | `0.309s` | `~3236.2 docs/s` |
| stress (5000 docs) | `2.864s` | `~1745.8 docs/s` |
| 10k | `7.756s` | `~1289.3 docs/s` |

#### Search latency

| Workload | Time | Throughput |
|:---|---:|---:|
| warm CPU smoke | `0.0015s` | `~666.7 ops/s` |
| warm CPU standard | `0.0033s` | `~303.0 ops/s` |
| warm CPU stress | `0.0072s` | `~138.9 ops/s` |
| 10k CPU hybrid iteration | `0.103s` | `~9.7 ops/s` |

#### Recall latency (`testMemoryOrchestratorRecallPerformance`)

| Workload | Time |
|:---|---:|
| smoke | `0.103s` |
| standard | `0.101s` |

Stress recall is currently harness-blocked (`signal 11`) and treated as a known benchmark issue.

#### FastRAG builder

| Mode | Time |
|:---|---:|
| fast mode | `0.102s` |
| dense cached | `0.102s` |

For benchmark commands, profiling traces, and methodology, see:
- `Tasks/hot-path-specialization-investigation.md`

---

## WAL Compaction and Storage Health (2026-02)

Wax includes a WAL/storage health track focused on commit latency tails, long-run file growth, and recovery behavior:

- No-op index compaction guards to avoid unnecessary index rewrites.
- Single-pass WAL replay with guarded replay snapshot fast path.
- Proactive WAL-pressure commits for targeted workloads (guarded rollout).
- Scheduled `rewriteLiveSet` maintenance with dead-payload thresholds, validation, and rollback.

### Measured outcomes

- Repeated unchanged index compaction growth improved from `+61,768,464` bytes over 8 runs (`~7.72MB/run`) to bounded drift (test-gated).
- Commit latency improved in most matrix workloads in recent runs (examples: `medium_hybrid` p95 `-13.9%`, `large_text_10k` p95 `-8.0%`, `sustained_write_text` p95 `-5.7%`).
- Reopen/recovery p95 is generally flat-to-improved across the matrix.
- `sustained_write_hybrid` remains workload-sensitive, so proactive/scheduled maintenance stays guarded by default.

### Safe rollout defaults

- Proactive pressure commits are tuned for targeted workloads and validated with percentile guardrails.
- Replay snapshot open-path optimization is additive and guarded.
- Scheduled live-set rewrite is configurable and runs deferred from the `flush()` hot path.
- Rewrite candidates are automatically validated and rolled back on verification failure.

### Configure scheduled live-set rewrite

```swift
import Wax

var config = OrchestratorConfig.default
config.liveSetRewriteSchedule = LiveSetRewriteSchedule(
    enabled: true,
    checkEveryFlushes: 32,
    minDeadPayloadBytes: 64 * 1024 * 1024,
    minDeadPayloadFraction: 0.25,
    minimumCompactionGainBytes: 0,
    minimumIdleMs: 15_000,
    minIntervalMs: 5 * 60_000,
    verifyDeep: false
)
```

### Reproduce benchmark matrix

```bash
WAX_BENCHMARK_WAL_COMPACTION=1 \
WAX_BENCHMARK_WAL_OUTPUT=/tmp/wal-matrix.json \
swift test --filter WALCompactionBenchmarks.testWALCompactionWorkloadMatrix
```

```bash
WAX_BENCHMARK_WAL_GUARDRAILS=1 \
swift test --filter WALCompactionBenchmarks.testProactivePressureCommitGuardrails
```

```bash
WAX_BENCHMARK_WAL_REOPEN_GUARDRAILS=1 \
swift test --filter WALCompactionBenchmarks.testReplayStateSnapshotGuardrails
```

See `Tasks/wal-compaction-investigation.md` in the repo for methodology and baseline artifacts.

---

## Quick Start

### 1. Add to Package.swift

```swift
.package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.6")
```

### 2. Choose Your Memory Type

<details>
<summary><b>Text Memory</b> — Documents, notes, conversations</summary>

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
<summary><b>Photo Memory</b> — Photo library with OCR + CLIP embeddings</summary>

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
<summary><b>Video Memory</b> — Video segments with transcripts</summary>

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

Wax packs everything into a single `.mv2s` file — the equivalent of SQLite for AI memory: one file that contains your documents, the search indexes, and enough crash-recovery state to survive a kill signal.

The file contains:

- Raw documents
- Embeddings (any dimension, any provider)
- BM25 full-text search index (FTS5)
- HNSW vector index (USearch)
- Write-ahead log for crash recovery
- Metadata and entity graph

**The file format:**
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

## Features

**Query-Adaptive Hybrid Search**

Wax runs multiple search lanes in parallel — BM25, vector, temporal, structured evidence — and fuses results based on query type.

"When was my last dentist appointment?" → boosts temporal + structured
"Explain quantum computing" → boosts vector + BM25

**Tiered Memory Compression (Surrogates)**

Wax generates hierarchical summaries for each document:
- `full` — Complete document (for deep dives)
- `gist` — Key paragraphs (for balanced recall)
- `micro` — One-liner (for quick context)

At query time, it picks the right tier based on query signals and remaining token budget.

**Deterministic Token Budgeting**

Strict `cl100k_base` token counting. Same query produces the same context window, every time — reproducible enough to benchmark and regression-test.

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

## Sift

Sift is a semantic git history search CLI built on Wax. It indexes commit history locally and lets you search with natural language instead of `git log --grep`.

- Repo: `https://github.com/christopherkarani/Sift`

```bash
brew tap christopherkarani/sift
brew install wax

wax tui
wax when did we add notifications feature
```

---

Built by [Christopher Karani](https://github.com/christopherkarani)
