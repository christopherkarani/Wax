# Wax: Complete Feature Deep Dive

> On-device RAG for Swift. Documents, embeddings, BM25 and HNSW indexes in a single file.
> Swift 6.2 | iOS 26+ | macOS 26+ | Apache 2.0

---

## Table of Contents

1. [Core Concept](#1-core-concept)
2. [The `.mv2s` File Format](#2-the-mv2s-file-format)
3. [Write-Ahead Log (WAL)](#3-write-ahead-log-wal)
4. [Crash Recovery & Durability](#4-crash-recovery--durability)
5. [I/O Subsystem](#5-io-subsystem)
6. [Concurrency Model](#6-concurrency-model)
7. [Text Search (BM25/FTS5)](#7-text-search-bm25fts5)
8. [Vector Search (HNSW + Metal GPU)](#8-vector-search-hnsw--metal-gpu)
9. [MiniLM Embedder (CoreML)](#9-minilm-embedder-coreml)
10. [Unified Hybrid Search](#10-unified-hybrid-search)
11. [RAG Context Assembly](#11-rag-context-assembly)
12. [Token Counting & Budgeting](#12-token-counting--budgeting)
13. [Surrogate Tiers (Hierarchical Memory Compression)](#13-surrogate-tiers-hierarchical-memory-compression)
14. [Structured Memory (Entity-Fact Graph)](#14-structured-memory-entity-fact-graph)
15. [Photo RAG](#15-photo-rag)
16. [Video RAG](#16-video-rag)
17. [MCP Server (Claude Integration)](#17-mcp-server-claude-integration)
18. [WaxRepo (Semantic Git Search TUI)](#18-waxrepo-semantic-git-search-tui)
19. [CLI & Installation](#19-cli--installation)
20. [Embedding Memoization](#20-embedding-memoization)
21. [Access Stats & Importance Scoring](#21-access-stats--importance-scoring)
22. [Compression](#22-compression)
23. [Live-Set Rewriting (Deep Compaction)](#23-live-set-rewriting-deep-compaction)
24. [Fault Injection & Crash Harness](#24-fault-injection--crash-harness)
25. [Binary Codec](#25-binary-codec)
26. [Module Architecture](#26-module-architecture)
27. [Swift Traits](#27-swift-traits)
28. [Performance Benchmarks](#28-performance-benchmarks)
29. [Constants & Limits](#29-constants--limits)
30. [Key Innovations Summary](#30-key-innovations-summary)
31. [Complete API Reference](#31-complete-api-reference)
    - [31.1 WaxCore Module](#311-waxcore-module)
    - [31.2 WaxTextSearch Module](#312-waxtextsearch-module)
    - [31.3 WaxVectorSearch Module](#313-waxvectorsearch-module)
    - [31.4 WaxVectorSearchMiniLM Module](#314-waxvectorsearchminilm-module)
    - [31.5 Wax Module -- Sessions & Orchestration](#315-wax-module----sessions--orchestration)
    - [31.6 Wax Module -- RAG Pipeline](#316-wax-module----rag-pipeline)
    - [31.7 Wax Module -- Unified Search](#317-wax-module----unified-search)
    - [31.8 Wax Module -- PhotoRAG & VideoRAG](#318-wax-module----photorag--videorag)
    - [31.9 Wax Module -- Maintenance & Utilities](#319-wax-module----maintenance--utilities)

---

## 1. Core Concept

Wax is an on-device RAG (Retrieval-Augmented Generation) system that packs documents, BM25 full-text indexes, HNSW vector indexes, embeddings, structured entity graphs, and crash-recovery state into a **single `.mv2s` file** on the user's device.

**The problem it solves:** Adding memory to an iOS or macOS app typically means standing up a vector database, a text search index, and a persistence layer -- three services with separate setup, uptime dependencies, and potential data egress. Wax replaces all of that with one file.

```
Traditional RAG Stack:               Wax:
  ChromaDB                            brain.mv2s
  PostgreSQL                          (one file, everything inside)
  Redis
  Elasticsearch
  Docker
  ~5 services
```

**30-second demo:**

```swift
import Wax

let brain = try await MemoryOrchestrator(
    at: URL(fileURLWithPath: "brain.mv2s")
)

try await brain.remember(
    "User prefers dark mode and gets headaches from bright screens",
    metadata: ["source": "onboarding"]
)

let context = try await brain.recall(query: "user preferences")
// Ranked, token-budgeted context ready for LLM consumption
```

No Docker. No network calls. 100% on-device.

---

## 2. The `.mv2s` File Format

**Memory Vision 2.0 Storage** -- a custom binary file format designed for crash-safe, append-only RAG storage.

### Layout

```
Offset 0x0000           : Header Page A (4 KiB)  -- Dual-buffered
Offset 0x1000           : Header Page B (4 KiB)  -- Active page chosen by generation
Offset 0x2000           : WAL Ring Buffer (default 256 MiB, wrap-around)
                        : Document payloads (append-only, optional LZ4/LZFSE/deflate)
                        : Embeddings (float vectors, little-endian bulk copy)
End - N                 : TOC (Table of Contents, max 64 MiB)
End - 64                : Footer (64 bytes) + SHA256 checksum
```

### Header Page (4096 bytes)

Each header page contains:

| Field | Bytes | Description |
|-------|-------|-------------|
| Magic | 4 | `"MV2S"` (0x4D563253) |
| Format version | 2 | Little-endian UInt16 |
| Spec major/minor | 2 | Currently 1.0 |
| Header page generation | 8 | Monotonic counter for A/B selection |
| File generation | 8 | Incremented on each commit |
| Footer offset | 8 | Points to latest committed footer |
| WAL offset | 8 | Start of WAL ring (always 8192) |
| WAL size | 8 | Ring capacity (default 256 MiB) |
| WAL write position | 8 | Current write cursor |
| WAL checkpoint position | 8 | Last checkpoint cursor |
| WAL committed sequence | 8 | Highest committed sequence |
| TOC checksum | 32 | SHA256 of TOC |
| Header checksum | 32 | Self-referential SHA256 (excludes self) |
| WAL replay snapshot | 72 | Optional fast-path recovery state |
| Padding | ~3888 | Zeros to fill 4 KiB page |

### Footer (64 bytes)

| Field | Bytes | Description |
|-------|-------|-------------|
| Magic | 8 | `"MV2SFOOT"` |
| TOC length | 8 | Byte length of TOC |
| TOC hash | 32 | SHA256 of TOC body |
| Generation | 8 | File generation at commit time |
| WAL committed sequence | 8 | Sequence watermark |

### Table of Contents (TOC)

The TOC is a variable-length binary structure containing:
- **Frame metadata array** -- dense `[FrameMeta]` indexed by frame ID
- **Index manifests** -- pointers to lexical/vector/time indexes stored in the data region
- **Segment catalog** -- byte ranges + checksums for committed index blobs
- **Ticket reference** -- reserved for future licensing
- **Merkle root** -- reserved (32 bytes, currently zeros)
- **TOC checksum** -- final 32 bytes, `SHA256(toc_body + zero32)`

### FrameMeta (per-frame metadata)

Every stored frame carries rich metadata:

| Field | Description |
|-------|-------------|
| `id` | Dense sequential ID (0, 1, 2, ...) |
| `timestamp` | Creation time (milliseconds) |
| `anchorTs` | Optional reference timestamp |
| `kind` | Content type hint (string) |
| `track` | Track ID for version lineage |
| `payloadOffset/Length` | File position and byte size |
| `checksum` | SHA256 of canonical (uncompressed) content |
| `storedChecksum` | SHA256 of stored (possibly compressed) content |
| `canonicalEncoding` | Compression type (plain, lzfse, lz4, deflate) |
| `canonicalLength` | Original size before compression |
| `uri` | Source URL/URI |
| `title` | Display title |
| `metadata` | Key-value pairs |
| `searchText` | Full-text search index content |
| `tags` | Custom tag pairs |
| `labels` | Classification labels |
| `contentDates` | Associated date strings |
| `role` | document, chunk, blob, or system |
| `parentId` | Parent frame ID (for chunks) |
| `chunkIndex/Count` | Position within parent |
| `chunkManifest` | Binary chunk manifest |
| `status` | active or deleted |
| `supersedes` | Frame this one replaces |
| `supersededBy` | Frame that replaced this one |

---

## 3. Write-Ahead Log (WAL)

The WAL is an append-only ring buffer that ensures crash safety. All mutations go through the WAL before being committed to the TOC.

### WAL Record Format (48-byte header)

```
[0..8)    : sequence (UInt64) -- monotonic, > 0
[8..12)   : length (UInt32) -- payload length
[12..16)  : flags (UInt32) -- bit 0 = isPadding
[16..48)  : checksum (32 bytes) -- SHA256(payload)
```

### Record Types

| Type | Description |
|------|-------------|
| **Data** | Normal mutation record with payload |
| **Padding** | Alignment filler when wrapping around ring |
| **Sentinel** | All-zeros marker signaling the stable write tail |

### WAL Entry Opcodes

| Opcode | Value | Description |
|--------|-------|-------------|
| `putFrame` | 0x01 | Store a frame with full metadata subset |
| `deleteFrame` | 0x02 | Mark a frame as deleted |
| `supersedeFrame` | 0x03 | Link old frame to new replacement |
| `putEmbedding` | 0x04 | Store a float vector for a frame |

### Ring Buffer Mechanics

**Write algorithm:**
1. Check entry fits in WAL capacity
2. If remaining space < header size: wrap immediately, increment `wrapCount`
3. If remaining < entry size but >= header: insert padding record, then wrap
4. Write record + inline sentinel (if space allows) in single I/O operation
5. Advance `writePos` (modular within ring), track `pendingBytes`

**Batch writes** coalesce adjacent records into fewer I/O operations, reducing syscall overhead.

**Fsync policies** (`WALFsyncPolicy`):
- `.always` -- fsync after every WAL append (maximum durability, higher latency)
- `.onCommit` -- fsync after each commit (default, recommended for production)
- `.everyBytes(UInt64)` -- fsync after N bytes written (tunable durability/performance trade-off)

**Checkpoint:** Resets `pendingBytes = 0`, advances `checkpointPos` to `writePos`. Called after successful commit.

### Proactive Auto-Commit

When pending WAL bytes exceed a configurable threshold (percentage of WAL capacity), Wax automatically commits to prevent the ring from wrapping over uncommitted data. This is guarded to avoid committing when there are pending embeddings without staged vector indexes.

---

## 4. Crash Recovery & Durability

### Dual-Header Atomic Commit Protocol

On every commit:
1. Apply pending mutations into TOC (in-memory)
2. Write staged indexes (lex/vec) to data region
3. Write new TOC + Footer to end of file, fsync
4. Write the **inactive** header page with new generation number
5. Fsync again -- this single fsync atomically switches the active header

**If power is lost during step 4:** The old header page is still valid. On reopen, the higher-generation page wins. If neither has a higher generation, Page A is preferred.

**If power is lost during step 3:** The WAL contains all pending mutations. On reopen, they are replayed from the WAL.

### WAL Replay on Open

Decision tree:
1. **Persisted replay snapshot** -- If the header contains a `walReplaySnapshot` matching the committed generation + sequence, skip WAL scan entirely (fast path)
2. **Header cursor snapshot** -- If header cursors match WAL state, use without scanning
3. **Full WAL scan** -- Scan from `walCheckpointPos` to `walWritePos`, decode all pending mutations

### Graceful Decode Failure

If a pending WAL entry is checksummed-valid but fails structural decoding, the scanner skips it and continues position tracking. This prevents one corrupted pending mutation from blocking recovery of later valid mutations.

### Crash Scenarios Tested

| Scenario | Crash Point | Result After Recovery |
|----------|-------------|----------------------|
| TOC write | After TOC, before footer | Seed frame only (pending in WAL) |
| Footer write | After footer fsync, before header | Seed + child frame (footer committed) |
| Header write | After header, before final fsync | Seed + child frame (header committed) |

---

## 5. I/O Subsystem

### FDFile -- POSIX File Descriptor Wrapper

Low-level file operations with fault injection for testing:

| Operation | Description |
|-----------|-------------|
| `read(length:at:)` | May short-read at EOF |
| `readExactly(length:at:)` | Retries on EINTR until satisfied |
| `writeAll(_:at:)` | Retries on EINTR until all bytes written |
| `fsync()` | `F_FULLFSYNC` on macOS, `fsync()` on Linux |
| `size()` | Current file size |
| `truncate(to:)` | Shrink file |
| `ensureSize(atLeast:)` | Extend with zeros |
| `mapWritable(length:at:)` | Memory-mapped writable region (RAII) |

**Fault injection** for testing crash recovery:

```swift
enum FDFileReadFault {
    case eintr(retries: Int)   // Simulates interrupted syscall
    case eio                    // I/O error
    case shortRead(maxBytes: Int)  // Partial read
}

enum FDFileWriteFault {
    case eintr(retries: Int)
    case eio
    case enospc                 // Disk full
    case shortWrite(maxBytes: Int)
}
```

Faults are installed via `installFaultPlan(_:)` and consumed sequentially during I/O operations.

### BlockingIOExecutor

Runs blocking file I/O on a dedicated `DispatchQueue` with barrier semantics to avoid blocking Swift concurrency's cooperative thread pool:
- `runRead()` -- enqueues concurrently (multiple readers in parallel)
- `runWrite()` -- enqueues with `.barrier` flag (exclusive access)

### FileLock

POSIX `flock`-based advisory file locking for inter-process coordination:
- `acquire(at:mode:)` / `tryAcquire(at:mode:)` -- blocking and non-blocking variants
- `upgrade()` -- shared to exclusive
- `downgrade()` -- exclusive to shared
- EINTR-safe retry loops

---

## 6. Concurrency Model

Wax uses an **actor-per-subsystem** architecture with Swift 6.2 strict concurrency throughout.

### Actors

| Actor | Purpose |
|-------|---------|
| `Wax` | Primary file handle, all mutable state |
| `WaxSession` | Session-scoped view, writer lease management |
| `MemoryOrchestrator` | High-level RAG API |
| `FTS5SearchEngine` | SQLite FTS5 text search |
| `MetalVectorEngine` | GPU-accelerated vector search |
| `PhotoRAGOrchestrator` | Photo library RAG |
| `VideoRAGOrchestrator` | Video RAG |

### Synchronization Primitives

| Primitive | Implementation | Used For |
|-----------|---------------|----------|
| **AsyncReadWriteLock** | Actor with continuation queues | Operation-level safety inside `Wax` |
| **ReadWriteLock** | `pthread_rwlock_t` | Synchronous read/write coordination |
| **AsyncMutex** | Actor with waiter queue | Mutual exclusion (first-come queueing) |
| **UnfairLock** | `os_unfair_lock` / `pthread_mutex` | Hot-path spinlock |

### Writer Lease

`Wax` enforces single concurrent writer via `WriterPolicy`:
- `.fail` -- immediate error if writer exists
- `.wait` -- block until released
- `.timeout(milliseconds)` -- bounded wait

---

## 7. Text Search (BM25/FTS5)

### FTS5SearchEngine

Actor wrapping GRDB/SQLite with FTS5 full-text search.

**Batching strategy:**
- Text write operations batched up to **2,048 ops** before flush
- Structured memory operations batched up to **512 ops**
- Operations queued in dictionary (dedup by frameId) + ordered array
- Reads always trigger a flush if dirty

**BM25 scoring:**
- SQLite FTS5's `bm25()` returns negative ranks (higher magnitude = lower relevance)
- Wax inverts: `scoreFromBM25Rank()` returns `-rank` for "higher is better" semantics

**Safe FTS tokenization:**
- User queries tokenized into alphanumeric-only tokens
- Maximum **24 tokens** per query
- FTS operators stripped: `"and"`, `"or"`, `"not"`, `"near"`
- Prevents FTS injection attacks

**Schema:**
- Virtual FTS5 table `frames_fts` with single content column
- Mapping table `frame_mapping` links frameId to FTS rowid
- Magic number: `0x5741_5854` ("WAXT") in `PRAGMA application_id`

**Serialization:**
- `sqlite3_serialize()` / `sqlite3_deserialize()` for in-memory <-> binary blob conversion
- Direct buffer-based I/O (no temp files)

---

## 8. Vector Search (HNSW + Metal GPU)

### MetalVectorEngine -- GPU-Accelerated Search

**Zero-copy architecture:**
- Vectors stored directly in `MTLBuffer` with `storageModeShared` (Apple Silicon Unified Memory)
- GPU kernel reads directly from shared buffer -- no CPU-to-GPU copy per search
- Only metadata (`frameIds`, `frameIdToIndex`) kept in CPU memory

**Metal compute pipeline:**

Three cosine distance kernels with increasing optimization:

| Kernel | Strategy | Best For |
|--------|----------|----------|
| `cosineDistanceKernel` | Scalar loop | Baseline |
| `cosineDistanceKernelSIMD4` | `float4` SIMD | < 384 dims |
| `cosineDistanceKernelSIMD8` | Dual `float4` accumulators | >= 384 dims (MiniLM) |

**SIMD8 kernel innovation:** Uses two independent `float4` accumulators per thread to exploit instruction-level parallelism. Processes 8 floats per iteration, reducing dependency chains and enabling GPU pipelining. Uses FMA (fused multiply-add) for precision + speed.

**Top-K reduction:**
- **GPU path** (vectorCount >= 1000): Two-stage reduction
  1. Per-threadgroup partial top-K via max-heap
  2. Iterative merge via bitonic sort until final K remains
- **CPU path** (< 1000 vectors): Heap-based O(n log k) selection
- Adaptive switching based on vector count and k value

**Transient buffer pool:**
- Pool of **8 MTLBuffer** entries reused across concurrent searches
- Retention policy: keeps buffers up to `2x vectorCount` capacity
- Automatic eviction of oversized buffers

**Serialization format (Magic: "MV2V"):**
- Version 1, Encoding 2 (Metal-specific)
- Header (36 bytes): metric, dimensions, vectorCount, payload length
- Payload: Flattened float data + frameIds array

### USearchVectorEngine -- CPU HNSW Search

Wraps the USearch C++ HNSW library:
- Connectivity: **M=16** (balance between quality and memory)
- Quantization: F32 (full precision)
- Metric: configurable (cosine, dot, L2)
- **Batch streaming:** Chunks large batches (default 256) to avoid excessive lock hold times
- **Cross-engine migration:** Can load Metal-format vectors and rebuild HNSW index

### Buffer-Based USearch Serialization

Instead of the default file-based serialization, Wax uses direct C API access via Objective-C runtime to serialize/deserialize USearch indexes entirely in memory. This is **10-100x faster** than the file-based path.

---

## 9. MiniLM Embedder (CoreML)

Built-in on-device embedding via CoreML, gated behind the `MiniLMEmbeddings` Swift trait.

### Model

- **all-MiniLM-L6-v2**: 6-layer transformer, **384-dimensional** output
- Bundled as `.mlmodelc` compiled CoreML model
- **ANE-optimized**: Defaults to `cpuAndNeuralEngine` compute units (1.5-2x speedup on Apple Silicon Neural Engine)

### BERT Tokenizer

Two-stage tokenization:

1. **BasicTokenizer:**
   - Diacritic folding (e to e)
   - Lowercasing (except special tokens: [UNK], [SEP], [PAD], [CLS], [MASK])
   - Whitespace + punctuation splitting

2. **WordpieceTokenizer:**
   - Greedy longest-match subword segmentation
   - `##` prefix for continuation tokens
   - Max 100 chars per word, max 512 token sequence

### Adaptive Sequence Length Bucketing

Batch tokenization uses buckets (32, 64, 128, 256, 384, 512) to minimize padding overhead. Shorter inputs get shorter sequences, reducing wasted compute.

### Batch Inference

- `BatchInputBuffers` reused across calls to avoid `MLMultiArray` allocation
- `buildBatchInputsWithReuse()` reallocates only if shape changes
- Direct `UnsafeMutablePointer<Int32>` manipulation for fast buffer fills

### Embedding Decoding

- Fast path: Contiguous float32 -> direct buffer pointer slice
- Float16 conversion: Accelerate `vDSP` for 8-16x speedup vs manual
- Stride-aware indexing for non-contiguous CoreML output layouts

### Model Caching

Thread-safe `NSLock`-protected singleton cache keyed by `(computeUnits, allowLowPrecision)`. Prevents CoreML/Espresso deadlock from concurrent model loads on the same configuration.

### Prewarm

`prewarm()` initializes model state with dummy data, improving latency for the first real prediction. Runs single-sample + batch-sample (up to 32) prewarm passes.

---

## 10. Unified Hybrid Search

### Query-Adaptive Fusion

`UnifiedSearch` runs multiple search lanes in parallel and merges results using Reciprocal Rank Fusion (RRF) with **query-type-aware weights**.

### Query Classification

`RuleBasedQueryClassifier` -- deterministic, offline, regex-based:

| Query Type | Signal Words | Example |
|-----------|-------------|---------|
| **Temporal** | "when", "yesterday", "last", "recent" | "When was my last dentist appointment?" |
| **Factual** | "what is", "define", "definition" | "What is quantum computing?" |
| **Semantic** | "how", "why", "explain" | "How does photosynthesis work?" |
| **Exploratory** | Fallback | "Tell me about Mars" |

### Adaptive Fusion Weights

| Query Type | BM25 | Vector | Timeline | Structured |
|-----------|------|--------|----------|------------|
| Factual | 0.70 | 0.30 | -- | -- |
| Semantic | 0.30 | 0.70 | -- | -- |
| Temporal | 0.25 | 0.25 | 0.50 | -- |
| Exploratory | 0.40 | 0.50 | 0.10 | -- |

### Search Modes

| Mode | Description |
|------|-------------|
| `.textOnly` | BM25 only |
| `.vectorOnly` | Cosine similarity only (requires embedding) |
| `.hybrid(alpha)` | Weighted fusion (0.0=vector, 1.0=text) |

### RRF (Reciprocal Rank Fusion)

```
RRF_score(d) = sum over lanes: weight_lane / (k + rank_lane(d))
```

- Default k=60
- Candidate pool expanded to **3x topK** (max 1000) before fusion
- Order-independent (permutation invariant) -- tested property
- Idempotent -- tested property

### Parallel Execution

Each search lane runs concurrently:
1. **Text**: Primary FTS5 query + fallback query with result merging
2. **Vector**: Cosine similarity via Metal or CPU engine
3. **Structured memory**: Entity alias resolution + fact evidence frames
4. **Timeline**: Reverse-chronological fallback for temporal queries

---

## 11. RAG Context Assembly

### FastRAGContextBuilder

Deterministic RAG context assembly pipeline:

1. **Unified Search** -- run all lanes in parallel
2. **Optional reranking** -- answer-focused reranking for top candidates
3. **Expansion** -- fetch first result's full frame content (single expansion max -- ensures determinism)
4. **Surrogates** -- load hierarchical surrogate tiers with batch prefetch
5. **Snippets** -- fill remaining token budget with preview texts

**Determinism guarantee:** Only the first result is expanded. Same query always produces the same context. Testable via `FastRAGConfig.deterministicNowMs` to pin the clock for tier selection.

### Query Analysis

`QueryAnalyzer` extracts structured signals from queries:
- Normalized terms, entity terms
- Year literals, ISO dates
- Intent detection: `.asksLocation`, `.asksDate`, `.asksOwnership`, `.multiHop`
- Specificity scoring (0-1) based on word count, entities, quoted phrases

### Answer Extraction

`DeterministicAnswerExtractor` -- regex-based candidate extraction:
- Ownership patterns, launch dates, appointments, locations
- Lexical similarity scoring with term/entity/date coverage bonuses
- Intent-aware selection (e.g., "who owns X and when" returns both owner + date)
- Fallback: best sentence by lexical overlap

---

## 12. Token Counting & Budgeting

### Hybrid Tokenizer System

| Backend | Description |
|---------|-------------|
| **SwiftTiktoken** | Production default (external BPE library) |
| **NativeBpeTokenizer** | Fully offline `cl100k_base` (bundled in SPM) |
| **Comparison mode** | Validates both implementations (dev only) |

Environment override: `WAX_TOKENIZER_BACKEND` (tiktoken/native/compare)

### NativeBpeTokenizer Innovations

- Regex-based tokenization matching `cl100k_base` patterns
- BPE merge heap with rank-order tracking
- Per-piece LRU cache for subword merging
- Fallback to individual bytes for unknown tokens

### LRU Tokenization Cache

O(1) doubly-linked-list implementation with pre-allocated dictionary for capacity efficiency. Optimized for repeated encoding of the same texts during RAG assembly.

### Batch Operations

| Operation | Description |
|-----------|-------------|
| `countBatch` | Parallel token counting (>4 texts via TaskGroup) |
| `encodeBatch` | Parallel token generation |
| `truncateBatch` | Parallel truncation to max tokens |
| `countAndTruncateBatch` | Combined single-pass operation |

### Token Budget Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxContextTokens` | 1500 | Total context budget |
| `expansionMaxTokens` | 600 | Cap for expanded first result |
| `snippetMaxTokens` | 200 | Per-snippet cap |
| `surrogateMaxTokens` | 60 | Per-surrogate cap |

**Fill order:** expansion -> surrogates -> snippets (deterministic)

---

## 13. Surrogate Tiers (Hierarchical Memory Compression)

Wax generates hierarchical summaries for each document, enabling adaptive recall based on query needs and token budgets.

### Three Tiers

| Tier | Budget | Purpose |
|------|--------|---------|
| **Full** | ~100 tokens | Complete content (deep dives) |
| **Gist** | ~25 tokens | Key paragraphs (balanced recall) |
| **Micro** | ~8 tokens | One-liner entity + topic (quick context) |

### Surrogate Generation

`ExtractiveSurrogateGenerator` -- default extractive summarization implementation:
- Generates per-tier summaries
- `HierarchicalSurrogateGenerator` protocol for custom implementations
- Versioned with `algorithmID` for cache invalidation
- Generation timestamp for freshness tracking

### Tier Selection Policies

| Policy | Description |
|--------|-------------|
| `.disabled` | Always use full tier |
| `.ageOnly(AgeThresholds)` | Full (0-7d), Gist (7-30d), Micro (30d+) |
| `.importance(ImportanceThresholds)` | Score-based selection with age + frequency + recency |

**Query-aware boost:** Specificity score lifts importance for highly specific queries.

---

## 14. Structured Memory (Entity-Fact Graph)

A knowledge graph stored within FTS5/SQLite alongside text search data.

### Data Model

- **Entities**: Namespaced identifiers (`namespace:id`), with kind and aliases
- **Predicates**: Relationship type keys
- **Facts**: `(subject, predicate, object)` triples with temporal validity
- **Evidence**: Links facts to source frames with confidence scores and span offsets

### Fact Value Types

```swift
enum FactValue: Sendable, Equatable, Hashable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case timeMs(Int64)
    case entity(EntityKey)
}
```

### Bitemporal Queries

Facts support two time dimensions:
- **Valid time** (`valid_from_ms`, `valid_to_ms`): When the fact was true in the real world
- **System time** (`system_from_ms`, `system_to_ms`): When the fact was recorded

`asOf` queries retrieve facts valid at a specific point in time using half-open intervals: `[fromMs, toMs)`.

### Entity Resolution

- Normalized, case-insensitive alias matching
- Multiple entities can match a single alias
- Entity keys must follow `namespace:id` format (validated with allowed chars: `a-z A-Z 0-9 . _ : -`)

### Integration with Unified Search

When `enableStructuredMemory` is on, `UnifiedSearch` includes structured evidence in the fusion pipeline alongside BM25 and vector results.

---

## 15. Photo RAG

`PhotoRAGOrchestrator` -- actor-based photo library RAG with OCR + CLIP embeddings.

### Ingest Pipeline

1. **Root frame**: PHAsset metadata (location, EXIF, dimensions, capture time)
2. **OCR**: Vision-based text extraction (`VNRecognizeTextRequest`) into blocks + summary
3. **Captioning**: Short captions via optional provider
4. **Tags**: Derived from metadata + OCR context
5. **Regions**: Proposed bounding boxes from OCR blocks with per-region embeddings
6. **Thumbnails**: Resized for context output

### Multimodal Embedding

- Text embeddings for OCR/caption text
- Image embeddings for root + region crops
- Shared embedding space required (caller supplies a `MultimodalEmbeddingProvider`)
- Optional L2 normalization

### Search

- Hybrid text (OCR summary) + image embeddings
- Text/image weight fusion (configurable 0-1)
- Evidence tracking (which lane contributed the match)
- Region matching with normalized rectangles

### Features

- Asset ID deduplication (no re-ingest of existing photos)
- Location binning for spatial queries
- Concurrent asset ingest (configurable)
- Pixel size caps for embed/OCR/thumbnail/region

---

## 16. Video RAG

`VideoRAGOrchestrator` -- actor-based video RAG with transcript segmentation.

### Ingest Pipeline

1. **Root frame**: Video metadata (source URL, duration, capture time)
2. **Segments**: Configurable duration (default 10s) with overlap for continuity
3. **Transcripts**: Optional text per segment (caller supplies a `TranscriptProvider`)
4. **Keyframes**: Per-segment keyframe embeddings
5. **Thumbnails**: Optional keyframe images

### Search

- Hybrid text (transcript) + keyframe embeddings
- Timeline fallback (reverse-chronological)
- Segment-level ranking + summarization
- Time range and video ID filtering

### Configuration

- Segment duration and overlap
- Max segments per video
- Context budgets (max text tokens, thumbnails, transcript lines)
- Same embedding space required for text + keyframes

---

## 17. MCP Server (Claude Integration)

`WaxMCPServer` -- a stdio MCP (Model Context Protocol) server that bridges Claude to Wax.

### 18 MCP Tools

| Tool | Purpose |
|------|---------|
| `wax_remember` | Store text with metadata (max 128 KB) |
| `wax_recall` | RAG context assembly (limit 1-100, default 5) |
| `wax_search` | Direct search with ranked hits (topK 1-200) |
| `wax_flush` | Commit pending writes |
| `wax_stats` | Runtime/storage statistics |
| `wax_session_start` | Create scoped session (auto-UUID) |
| `wax_session_end` | End active session |
| `wax_handoff` | Store cross-session handoff context |
| `wax_handoff_latest` | Retrieve latest handoff (project-scoped) |
| `wax_entity_upsert` | Create/update entity with aliases |
| `wax_fact_assert` | Add fact to knowledge graph |
| `wax_fact_retract` | Retract fact by ID |
| `wax_facts_query` | Query facts with temporal filters |
| `wax_entity_resolve` | Resolve entity by alias |
| `wax_video_ingest` | Ingest video files (1-50 paths) |
| `wax_video_recall` | Query video segments with time ranges |
| `wax_photo_ingest` | Photo ingest (requires Soju) |
| `wax_photo_recall` | Photo recall (requires Soju) |

### Server Features

- **Path sandbox**: Store paths validated against safe-root to prevent directory traversal
- **Feature flags**: `WAX_MCP_FEATURE_STRUCTURED_MEMORY`, `WAX_MCP_FEATURE_ACCESS_STATS`, `WAX_MCP_FEATURE_LICENSE`
- **Graceful degradation**: Server continues if video/photo RAG initialization fails
- **License validation**: Format check + keychain storage + optional activation ping
- **Trial period**: 14-day trial stored in UserDefaults

### MultimodalAdapter

Converts images to text descriptions for embedding when no CLIP model is available:
- `VNClassifyImageRequest` -> top 5 labels (confidence >= 0.3)
- `VNRecognizeTextRequest` -> OCR text
- Constructs description: `"image labels: label1, label2. recognized text: ocr_text"`

---

## 18. WaxRepo (Semantic Git Search TUI)

A semantic git history search TUI built on Wax. Indexes commit history locally and enables natural-language search instead of `git log --grep`.

### Commands

| Command | Description |
|---------|-------------|
| `wax-repo index` | Parse git history and ingest into `.wax-repo/store.mv2s` |
| `wax-repo search` | Interactive TUI or single-query search |
| `wax-repo stats` | Show index statistics |

### Indexing

- **Incremental**: Tracks `last-indexed-hash` to avoid re-indexing
- `--full` flag for complete re-index
- Parses git log with custom format using **state machine parser** (no regex)
- Ingests commit subject + body + truncated diff (first 8 KB) per commit
- Structured metadata: hash, author, date, subject, files changed

### TUI (SwiftTUI)

```
wax-repo | semantic git search
[query input field                    ]

 > a1b2c3d  Fix authentication bug   2d ago
   e5f6g7h  Add user notifications   1w ago
   ...
 ─────────────────────────────────────────
   10 results, 42ms

   diff --git a/src/auth.swift ...
   + func validateToken() { ... }
   - func checkAuth() { ... }
```

- Real-time search with colored diff preview
- Hash (cyan), additions (green), deletions (red), hunks (cyan)
- Keyboard navigation with selection marker

---

## 19. CLI & Installation

### WaxCLI Commands

```
wax mcp serve       -- Start MCP server
wax mcp install     -- Build + register with Claude
wax mcp doctor      -- Validate setup
wax mcp uninstall   -- Remove from Claude
```

### `wax mcp install` Workflow

1. Build WaxMCPServer with `swift build --product WaxMCPServer --traits default,MCPServer`
2. Remove existing Claude registration (idempotent)
3. Register via `claude mcp add --transport stdio`
4. Inject feature flags and license keys as environment variables

### `wax mcp doctor`

Smoke-tests the entire MCP pipeline:
1. Check WaxMCPServer binary exists and is executable
2. Check `claude` CLI exists
3. Send MCP protocol `initialize` + `tools/list` to the server
4. Verify `wax_remember` tool appears in response
5. Report all failures

---

## 20. Embedding Memoization

`EmbeddingMemoizer` -- LRU cache wrapping any embedding provider.

### Design

- O(1) get/set via doubly-linked list + dictionary
- Per-entry key: FNV-1a (64-bit) hash of provider identity + model + dimensions + normalization + text
- Hit rate tracking for performance analysis
- Batch operations: `getBatch()`, `setBatch()`

### Configuration

- Capacity set via `OrchestratorConfig.embeddingCacheCapacity` (default 2048)
- Zero capacity = always miss (effectively disabled)
- LRU eviction: least-recently-used entries evicted when at capacity

---

## 21. Access Stats & Importance Scoring

### AccessStatsManager

Per-frame tracking:
- Access count (saturating addition, wraps at UInt32.max)
- Last access timestamp (milliseconds)
- First access timestamp (for age calculation)
- Dirty flag for lazy persistence (avoid redundant writes)

### ImportanceScorer

Weighted score combining three signals:

| Signal | Weight | Calculation |
|--------|--------|-------------|
| **Age decay** | configurable | Exponential decay (half-life: 1 week) |
| **Frequency** | configurable | Log-scale access count (capped at 1.0) |
| **Recency** | configurable | Exponential decay (half-life: 1 day) |

Formula: `score = w_age * age_score + w_freq * freq_score + w_recency * recency_score`

### Tier Selection Integration

Importance scores feed into `SurrogateTierSelector` to pick full/gist/micro tiers. High-importance + recently-accessed frames get the full tier; stale frames get micro.

---

## 22. Compression

### Supported Algorithms

| Algorithm | Platform | Description |
|-----------|----------|-------------|
| **LZFSE** | macOS/iOS | Apple proprietary, best ratio for Apple |
| **LZ4** | All | Fast, low compression ratio |
| **Deflate** | All | zlib wrapper, good general-purpose |

### Selective Compression

Wax only stores compressed data if `compressed_size < original_size`. Incompressible data (already compressed, encrypted) is stored uncompressed without penalty.

**Canonical form:** Always uncompressed, used for checksums. Stored form may be compressed for disk savings. Decompression is transparent on read.

### Linux Support

LZ4 and Deflate supported via C bindings (`wax_lz4_*`, `wax_deflate_*`). LZFSE is not available on Linux.

---

## 23. Live-Set Rewriting (Deep Compaction)

Scheduled maintenance that rewrites the entire live frame set to reclaim space from deleted/superseded frames.

### Process

1. Copy all live frames to new `.mv2s` file
2. Carry forward committed indexes (text + vector)
3. Drop dead frame payloads
4. Validate candidate file (deep verification)
5. Atomically replace old file
6. Rollback on verification failure

### Scheduling

```swift
LiveSetRewriteSchedule(
    enabled: true,
    checkEveryFlushes: 32,        // Check every N flushes
    minDeadPayloadBytes: 64 MB,   // Minimum dead payload before compaction
    minDeadPayloadFraction: 0.25, // At least 25% dead
    minimumCompactionGainBytes: 0,
    minimumIdleMs: 15_000,        // 15s idle window required
    minIntervalMs: 300_000,       // 5-minute cooldown
    verifyDeep: false
)
```

### Guards

- Deferred from `flush()` hot path (runs asynchronously)
- Candidate validation before replacement
- Automatic stale candidate pruning
- Idle window enforcement
- Dead payload threshold (bytes + fraction)
- Compaction gain validation

---

## 24. Fault Injection & Crash Harness

### WaxCrashHarness

Parent-child process model for deterministic crash injection testing:

1. **Parent** creates `.mv2s` file, writes seed frame, commits
2. **Child** opens file, writes additional frame, triggers commit
3. **Child killed by SIGKILL** at specific checkpoint (before/during/after commit phases)
4. **Parent** reopens file, validates recovery (frame count + content integrity)

### Crash Injection Points

Controlled via `WAX_CRASH_INJECT_CHECKPOINT` environment variable:
- After TOC write
- After footer fsync
- After header write
- Before final fsync

### FDFile Fault Plans

Deterministic I/O failure simulation:
- `.eio` -- I/O error
- `.enospc` -- disk full
- `.shortWrite(maxBytes:)` -- partial write
- `.eintr(retries:)` -- interrupted syscall

---

## 25. Binary Codec

Deterministic little-endian binary encoding used for all on-disk structures.

### BinaryEncoder

| Method | Description |
|--------|-------------|
| `encode(UInt8/16/32/64)` | Fixed-width little-endian |
| `encode(Int64)` | Signed 64-bit |
| `encode(String)` | UInt32 length prefix + UTF-8 |
| `encodeBytes(Data)` | UInt32 length prefix + raw bytes |
| `encodeFixedBytes(Data)` | Raw bytes (no length prefix) |
| `encode([T])` | UInt32 count + elements |
| `encode(T?)` | Tag byte (0/1) + payload |
| `pad(to:)` | Zero-fill to alignment |

### BinaryDecoder

- Cursor-based sequential reading
- **Tight validation** on every field: string length, array count, optional tags
- `finalize()` asserts no excess bytes remain
- Structured errors with field context

### Limits

| Limit | Value |
|-------|-------|
| Max string | 16 MiB |
| Max blob | 256 MiB |
| Max array count | 10 million |
| Max embedding dimensions | 1 million |

---

## 26. Module Architecture

```
WaxMCPServer / WaxCLI / WaxRepo
        |
      Wax  (orchestration & RAG -- public API surface)
     /   \
WaxTextSearch   WaxVectorSearch   WaxVectorSearchMiniLM
        \           /                    /
              WaxCore  (file format, WAL, I/O primitives)
```

| Module | Responsibility |
|--------|---------------|
| **WaxCore** | `.mv2s` file format, WAL ring buffer, FDFile I/O, crash recovery, binary codec, structured memory types, concurrency primitives |
| **WaxTextSearch** | BM25 full-text search via GRDB/SQLite FTS5, entity/fact storage, schema management |
| **WaxVectorSearch** | HNSW vector search (USearch CPU, Metal GPU), vector serialization, Metal shaders |
| **WaxVectorSearchMiniLM** | CoreML all-MiniLM-L6-v2 embedder, BERT tokenizer, model caching |
| **Wax** | MemoryOrchestrator, WaxSession, UnifiedSearch, FastRAGContextBuilder, chunking, token counting, surrogate tiers, access stats, PhotoRAG, VideoRAG |
| **WaxMCPServer** | MCP stdio server, tool schemas, license validation, multimodal adapter |
| **WaxCLI** | CLI commands for MCP install/serve/doctor/uninstall |
| **WaxRepo** | Semantic git search TUI, git log parser, SwiftTUI interface |
| **WaxCrashHarness** | Deterministic crash injection testing |

---

## 27. Swift Traits

| Trait | Description | Default |
|-------|-------------|---------|
| `MiniLMEmbeddings` | Includes CoreML MiniLM embedder | Yes |
| `MCPServer` | Gates WaxMCPServer executable (macOS only) | No |
| `WaxRepo` | Gates wax-repo TUI executable (macOS only) | No |

All targets use `StrictConcurrency` experimental Swift feature. Trait-gated code uses `#if` compiler directives (e.g., `#if MCPServer`).

---

## 28. Performance Benchmarks

Apple Silicon (M1 Pro):

```
Vector Search Latency (10K x 384-dim)
  Wax Metal (warm)     0.84ms
  Wax Metal (cold)     9.2ms
  Wax CPU              105ms
  SQLite FTS5          150ms

Cold Open -> First Query: 17ms
Hybrid Search @ 10K docs: 105ms
```

### Ingest Throughput

| Workload | Time | Throughput |
|----------|------|-----------|
| 200 docs (smoke) | 0.103s | ~1941 docs/s |
| 1000 docs (standard) | 0.309s | ~3236 docs/s |
| 5000 docs (stress) | 2.864s | ~1746 docs/s |
| 10K docs | 7.756s | ~1289 docs/s |

### Search Latency

| Workload | Time |
|----------|------|
| Warm CPU smoke | 1.5ms |
| Warm CPU standard | 3.3ms |
| Warm CPU stress | 7.2ms |
| 10K CPU hybrid | 103ms |

### Recall Latency (MemoryOrchestrator)

| Workload | Time |
|----------|------|
| Smoke | 103ms |
| Standard | 101ms |

---

## 29. Constants & Limits

| Constant | Value |
|----------|-------|
| Header page size | 4 KiB |
| Header region (A+B) | 8 KiB |
| WAL start offset | 8192 |
| Default WAL size | 256 MiB |
| Max frame payload | 256 MiB |
| Max string | 16 MiB |
| Max embedding dims | 1 million |
| Max TOC | 64 MiB |
| Max array count | 10 million |
| Max footer scan | 32 MiB |
| MCP content limit | 128 KB |
| MCP topK limit | 200 |
| MCP video paths limit | 50 |
| FTS token cap | 24 tokens |
| FTS text flush threshold | 2048 ops |
| FTS structured flush threshold | 512 ops |
| Metal buffer pool size | 8 buffers |
| MiniLM dimensions | 384 |
| MiniLM max sequence | 512 tokens |
| USearch connectivity (M) | 16 |

---

## 30. Key Innovations Summary

### Architecture Innovations

1. **Single-file RAG** -- Documents, embeddings, BM25 indexes, HNSW indexes, entity graphs, WAL, and crash-recovery state all in one `.mv2s` file. No Docker, no network, no sidecars.

2. **Dual-header atomic commits** -- Two header pages with generation numbers. On crash, the valid page wins. Never corrupt on power loss.

3. **WAL ring buffer with proactive auto-commit** -- Circular WAL with wrap-around prevents unbounded disk growth. Automatic commit when pending bytes approach capacity.

4. **WAL replay snapshot fast path** -- Persists WAL state on inactive header page. Skips full WAL scan on open when snapshot is fresh.

### Search & RAG Innovations

5. **Query-adaptive fusion** -- RuleBasedQueryClassifier detects query intent (factual/semantic/temporal/exploratory) and adjusts BM25/vector/timeline weights. "When was my dentist appointment?" boosts temporal; "Explain quantum computing" boosts vector.

6. **Deterministic RAG** -- Same query always produces the same context window. Single-expansion policy, fixed RRF parameters, `cl100k_base` BPE counting. Reproducible enough to benchmark and regression-test.

7. **Hierarchical surrogate tiers** -- Full/gist/micro summaries with age + importance-aware tier selection. Recent high-access frames get full context; stale frames get one-liners.

8. **Bitemporal structured memory** -- Entity-fact-predicate graph with both validity time and system time. "Who was the CEO in 2023?" is a first-class query.

### Performance Innovations

9. **Zero-copy Metal GPU search** -- Vectors stored directly in `MTLBuffer` with shared/unified memory. GPU kernel reads without CPU-to-GPU copy. 0.84ms at 10K vectors.

10. **SIMD8 dual-accumulator Metal kernel** -- Two independent `float4` accumulators per thread for 384-dim vectors, exploiting instruction-level parallelism and GPU pipelining.

11. **Adaptive GPU top-K reduction** -- Two-stage GPU path (per-threadgroup heap + bitonic sort merge) for 1000+ vectors; CPU heap for smaller sets.

12. **Buffer-based USearch serialization** -- Direct C API access for 10-100x faster serialization vs file-based path.

13. **Batch embedding with memoization** -- LRU cache keyed by content hash prevents recomputing embeddings. Batch API optimization provides 3-8x speedup over sequential.

### Developer Experience Innovations

14. **Fault injection testing** -- `FDFile.installFaultPlan()` enables deterministic I/O failures (`.eio`, `.enospc`, `.shortWrite`). Crash harness proves recovery under every failure mode.

15. **MCP Server with 18 tools** -- Full Claude integration via stdio MCP protocol. Remember, recall, search, entity graph, video/photo RAG, session management, handoff.

16. **Semantic git search TUI** -- `wax-repo` indexes git history with MiniLM embeddings and provides natural-language commit search with colored diff preview.

17. **ANE-optimized MiniLM** -- CoreML all-MiniLM-L6-v2 with Neural Engine compute units, adaptive sequence length bucketing, and buffer reuse for batch inference.

18. **Safe FTS tokenization** -- Strips FTS operators, caps at 24 tokens, prevents injection attacks on the SQLite FTS5 engine.

19. **Cross-engine migration** -- Metal-format vectors can be loaded into USearch CPU index for fallback, and vice versa. Transparent engine switching.

20. **Selective compression** -- Only compresses if result < original. LZFSE/LZ4/deflate support with transparent decompression. Canonical checksums computed on uncompressed data.

---

## 31. Complete API Reference

Cross-checked catalog of every public type, method, and property across all Wax modules.

---

### 31.1 WaxCore Module

#### `Wax` (actor)

Primary handle to a `.mv2s` file. All mutable file state lives here.

**Lifecycle**

| Method | Signature | Description |
|--------|-----------|-------------|
| `create` | `static func create(at: URL, walSize: UInt64 = Constants.defaultWalSize, options: WaxOptions = .init()) async throws -> Wax` | Create a new empty `.mv2s` file |
| `open` | `static func open(at: URL, options: WaxOptions = .init()) async throws -> Wax` | Open existing file with auto-repair |
| `open` | `static func open(at: URL, repair: Bool, options: WaxOptions = .init()) async throws -> Wax` | Open with optional repair control |
| `close` | `func close() async throws` | Auto-commits if dirty, closes FD, releases lock |

**Writer Lease**

| Method | Description |
|--------|-------------|
| `acquireWriterLease(policy: WaxWriterPolicy) -> UUID` | Acquire exclusive writer lease |
| `releaseWriterLease(_ leaseId: UUID)` | Release writer lease |

**Frame Writes**

| Method | Description |
|--------|-------------|
| `put(_:options:compression:) -> UInt64` | Store single frame (auto-timestamp) |
| `put(_:options:compression:timestampMs:) -> UInt64` | Store single frame (caller timestamp) |
| `putBatch(_:options:compression:) -> [UInt64]` | Batch store (auto-timestamp) |
| `putBatch(_:options:compression:timestampsMs:) -> [UInt64]` | Batch store (caller timestamps) |
| `delete(frameId:)` | Mark frame as deleted |
| `supersede(supersededId:supersedingId:)` | Record supersession (acyclicity enforced) |

**Embedding Writes**

| Method | Description |
|--------|-------------|
| `putEmbedding(frameId:vector:)` | Store embedding for frame |
| `putEmbeddingBatch(frameIds:vectors:)` | Batch store embeddings |
| `pendingEmbeddingMutations() -> [PutEmbedding]` | Get all pending embeddings |
| `pendingEmbeddingMutations(since:) -> PendingEmbeddingSnapshot` | Get pending since sequence |

**Index Staging**

| Method | Description |
|--------|-------------|
| `stageLexIndexForNextCommit(bytes:docCount:version:)` | Stage BM25 index |
| `stageVecIndexForNextCommit(bytes:vectorCount:dimension:similarity:)` | Stage HNSW index |
| `commit()` | Flush pending mutations + staged indexes to disk |

**Frame Reads**

| Method | Description |
|--------|-------------|
| `frameMetas() -> [FrameMeta]` | All committed frame metadata |
| `frameMetas(frameIds:) -> [UInt64: FrameMeta]` | Batch lookup committed |
| `frameMetasIncludingPending(frameIds:) -> [UInt64: FrameMeta]` | Batch lookup including pending |
| `frameMeta(frameId:) -> FrameMeta` | Single committed lookup |
| `frameMetaIncludingPending(frameId:) -> FrameMeta` | Single including pending |
| `pendingFrameMeta(frameId:) -> FrameMeta?` | Pending-only lookup |
| `frameContent(frameId:) -> Data` | Read full payload (auto-decompress) |
| `frameContentIncludingPending(frameId:) -> Data` | Read including pending |
| `frameContents(frameIds:) -> [UInt64: Data]` | Batch read |
| `framePreview(frameId:maxBytes:) -> Data` | Partial read |
| `framePreviews(frameIds:maxBytes:) -> [UInt64: Data]` | Batch partial read |
| `frameStoredContent(frameId:) -> Data` | Raw stored (may be compressed) |
| `frameStoredPreview(frameId:maxBytes:) -> Data` | Partial raw stored |
| `surrogateFrameId(sourceFrameId:) -> UInt64?` | Look up surrogate |
| `surrogateFrameIds(for:) -> [UInt64: UInt64]` | Batch surrogate lookup |

**Index Reads**

| Method | Description |
|--------|-------------|
| `committedLexIndexManifest() -> LexIndexManifest?` | BM25 manifest |
| `readCommittedLexIndexBytes() -> Data?` | Serialized BM25 |
| `readStagedLexIndexBytes() -> Data?` | Staged BM25 |
| `stagedLexIndexStamp() -> UInt64?` | Lex stage counter |
| `committedVecIndexManifest() -> VecIndexManifest?` | Vector manifest |
| `readCommittedVecIndexBytes() -> Data?` | Serialized HNSW |
| `readStagedVecIndexBytes() -> (bytes:dimension:similarity:)?` | Staged HNSW |
| `stagedVecIndexStamp() -> UInt64?` | Vec stage counter |

**Introspection**

| Method | Description |
|--------|-------------|
| `stats() -> WaxStats` | Frame count, pending, generation |
| `walStats() -> WaxWALStats` | Detailed WAL metrics |
| `fileURL() -> URL` | Backing file path |
| `timeline(_: TimelineQuery) -> [FrameMeta]` | Time-range query |
| `verify()` / `verify(deep:)` | File integrity check |
| `search(_: SearchRequest) -> SearchResponse` | Unified hybrid search |

---

#### `WaxOptions` (struct, Sendable)

```swift
public init(
    walFsyncPolicy: WALFsyncPolicy = .onCommit,
    walProactiveCommitThresholdPercent: UInt8? = 80,
    walProactiveCommitMaxWalSizeBytes: UInt64? = 4 * 1024 * 1024,
    walProactiveCommitMinPendingBytes: UInt64 = 128 * 1024,
    walReplayStateSnapshotEnabled: Bool = false,
    ioQueueLabel: String = "com.wax.io",
    ioQueueQos: DispatchQoS = .userInitiated
)
```

#### `WaxWriterPolicy` (enum, Sendable, Equatable)

| Case | Description |
|------|-------------|
| `.wait` | Block until lease available |
| `.fail` | Throw immediately if held |
| `.timeout(Duration)` | Bounded wait |

#### `WaxStats` (struct, Equatable, Sendable)

| Property | Type |
|----------|------|
| `frameCount` | `UInt64` |
| `pendingFrames` | `UInt64` |
| `generation` | `UInt64` |

#### `WaxWALStats` (struct, Equatable, Sendable)

| Property | Type | Description |
|----------|------|-------------|
| `walSize` | `UInt64` | Total ring size |
| `writePos` | `UInt64` | Current write position |
| `checkpointPos` | `UInt64` | Checkpoint position |
| `pendingBytes` | `UInt64` | Bytes pending commit |
| `committedSeq` | `UInt64` | Latest committed sequence |
| `lastSeq` | `UInt64` | Latest WAL sequence |
| `wrapCount` | `UInt64` | Ring wrap-arounds |
| `checkpointCount` | `UInt64` | Checkpoints performed |
| `sentinelWriteCount` | `UInt64` | Sentinel writes |
| `writeCallCount` | `UInt64` | Total WAL append calls |
| `autoCommitCount` | `UInt64` | Proactive auto-commits |
| `replaySnapshotHitCount` | `UInt64` | Fast-path replay hits |

#### `WaxError` (enum, Error, LocalizedError, Sendable)

| Case | Associated Values |
|------|-------------------|
| `invalidHeader` | `reason: String` |
| `invalidFooter` | `reason: String` |
| `invalidToc` | `reason: String` |
| `encodingError` | `reason: String` |
| `decodingError` | `reason: String` |
| `walCorruption` | `offset: UInt64, reason: String` |
| `checksumMismatch` | `String` |
| `lockUnavailable` | `String` |
| `capacityExceeded` | `limit: UInt64, requested: UInt64` |
| `frameNotFound` | `frameId: UInt64` |
| `io` | `String` |
| `writerBusy` | -- |
| `writerTimeout` | -- |

#### File Format Types

**`MV2SHeaderPage`** (struct): Dual-buffered 4 KiB header with `WALReplaySnapshot` optional sub-struct. Static `selectValidPage(pageA:pageB:)` picks highest-generation valid page.

**`MV2SFooter`** (struct): 64-byte footer with `tocLen`, `tocHash`, `generation`, `walCommittedSeq`. Encode/decode/hash-match methods.

**`MV2STOC`** (struct): Table of Contents holding `[FrameMeta]`, `IndexManifests`, optional `TimeIndexManifest`, `SegmentCatalog`, `TicketRef`, `merkleRoot`, and `tocChecksum`.

**`FrameMeta`** (struct): 28 stored properties per frame (see section 2 for field list). Binary codec via `BinaryEncoder`/`BinaryDecoder`.

**`IndexManifests`** (struct): Contains optional `LexIndexManifest` and `VecIndexManifest`.

**`LexIndexManifest`** (struct): `docCount`, `bytesOffset`, `bytesLength`, `checksum`, `version`.

**`VecIndexManifest`** (struct): `vectorCount`, `dimension`, `bytesOffset`, `bytesLength`, `checksum`, `similarity`.

**`SegmentCatalog`** (struct): Array of `SegmentCatalogEntry` (segmentId, offset, length, checksum, compression, kind).

**`FooterScanner`** (enum): Static utility for scanning `.mv2s` files to locate the last valid footer.

#### Enums

| Enum | Cases | Module |
|------|-------|--------|
| `CanonicalEncoding` | `plain(0)`, `lzfse(1)`, `lz4(2)`, `deflate(3)` | WaxCore |
| `FrameRole` | `document(0)`, `chunk(1)`, `blob(2)`, `system(3)` | WaxCore |
| `FrameStatus` | `active(0)`, `deleted(1)` | WaxCore |
| `SegmentCompression` | `none(0)`, `lzfse(1)`, `lz4(2)`, `deflate(3)` | WaxCore |
| `SegmentKind` | `lex(0)`, `vec(1)`, `time(2)`, `custom(3)` | WaxCore |
| `VecSimilarity` | `cosine(0)`, `dot(1)`, `l2(2)` | WaxCore |
| `CompressionKind` | `none`, `lzfse`, `lz4`, `deflate` | WaxCore |

#### WAL Types

**`WALRecord`** (enum): `.data(sequence:flags:payload)`, `.padding(sequence:skipBytes)`, `.sentinel`. 48-byte header with SHA256 checksum.

**`WALEntry`** (enum): `.putFrame(PutFrame)`, `.deleteFrame(DeleteFrame)`, `.supersedeFrame(SupersedeFrame)`, `.putEmbedding(PutEmbedding)`.

**`PutFrame`** (struct): frameId, timestampMs, options, payloadOffset/Length, encoding, checksums.

**`PutEmbedding`** (struct): frameId, dimension, vector.

**`PendingMutation`** (struct): sequence + WALEntry.

#### Concurrency Primitives

| Type | Kind | Description |
|------|------|-------------|
| `AsyncMutex` | Struct | Async-safe mutual exclusion with `withLock` |
| `AsyncReadWriteLock` | Actor | Async readers-writer lock with continuation queues |
| `ReadWriteLock` | Class | `pthread_rwlock_t` wrapper |
| `UnfairLock` | Class | `os_unfair_lock` / `pthread_mutex` wrapper with `tryAcquire` |

#### I/O Primitives

**`FDFile`** (final class): POSIX FD wrapper with `read`, `readExactly`, `writeAll`, `fsync`, `truncate`, `ensureSize`, `mapWritable`. Fault injection via `installFaultPlan(_:)`.

**`BlockingIOExecutor`** (struct, Sendable): DispatchQueue-backed executor with `runRead()` (concurrent) and `runWrite()` (barrier).

**`FileLock`** (final class): POSIX `flock` with `acquire`, `tryAcquire`, `upgrade`, `downgrade`, `release`. Modes: `.shared`, `.exclusive`.

#### Binary Codec

**`BinaryEncoder`** (struct): Little-endian encoding for UInt8/16/32/64, Int64, String (length-prefixed), Data (length-prefixed), arrays (count-prefixed), optionals (tag byte).

**`BinaryDecoder`** (struct): Cursor-based reading with tight validation. `finalize()` asserts no excess bytes.

**`BinaryCodable`** protocol: Combined `BinaryEncodable` + `BinaryDecodable`.

#### Structured Memory Types (WaxCore)

| Type | Kind | Description |
|------|------|-------------|
| `EntityKey` | Struct | `RawRepresentable<String>`, namespaced identifier |
| `EntityRowID` | Struct | `RawRepresentable<Int64>`, Comparable |
| `PredicateKey` | Struct | `RawRepresentable<String>` |
| `PredicateRowID` | Struct | `RawRepresentable<Int64>`, Comparable |
| `FactRowID` | Struct | `RawRepresentable<Int64>`, Comparable |
| `FactValue` | Enum | 7 cases: string, int, double, bool, data, timeMs, entity |
| `StructuredTimeRange` | Struct | `fromMs: Int64`, `toMs: Int64?` (nil = open-ended) |
| `StructuredEvidence` | Struct | Source frame, chunk index, span, extractor, confidence |
| `StructuredMemoryAsOf` | Struct | Bitemporal query point (`systemTimeMs`, `validTimeMs`) |
| `StructuredFact` | Struct | Subject-predicate-object triple |
| `StructuredFactHit` | Struct | Fact + evidence + isOpenEnded |
| `StructuredFactsResult` | Struct | `hits: [StructuredFactHit]`, `wasTruncated` |
| `StructuredEntityMatch` | Struct | `id`, `key`, `kind` |
| `StructuredEdgeDirection` | Enum | `.outbound`, `.inbound` |
| `EdgeHit` | Struct | `factId`, `predicate`, `direction`, `neighbor` |
| `StructuredEdgesResult` | Struct | `hits: [EdgeHit]`, `wasTruncated` |
| `StructuredMemoryCanonicalizer` | Enum | String/alias normalization |
| `StructuredMemoryHasher` | Enum | SHA256 fact/span hashing |
| `StructuredMemoryQueryContext` | Struct | `asOf`, `maxResults`, `maxTraversalEdges`, `maxDepth` |

#### Other WaxCore Types

**`FrameMetaSubset`** (struct): 18 optional frame metadata fields used in `put()` calls.

**`TagPair`** (struct): `key: String`, `value: String`.

**`Metadata`** (struct): `entries: [String: String]` key-value metadata.

**`TimelineQuery`** (struct): Time-range query with `limit`, `order` (.chronological/.reverseChronological), `after`, `before`, `includeDeleted`, `includeSuperseded`.

**`Constants`** (enum): All file format constants (see section 29).

**`SHA256Checksum`** (struct): Incremental SHA256 with `update()` and `finalize()`.

**`PayloadCompressor`** (enum): Static `compress()`/`decompress()` for LZFSE/LZ4/Deflate.

---

### 31.2 WaxTextSearch Module

#### `FTS5SearchEngine` (actor)

| Method | Signature |
|--------|-----------|
| `inMemory()` | `static func inMemory() throws -> FTS5SearchEngine` |
| `deserialize(from:)` | `static func deserialize(from: Data) throws -> FTS5SearchEngine` |
| `load(from:)` | `static func load(from: Wax) async throws -> FTS5SearchEngine` |
| `count()` | `func count() async throws -> Int` |
| `index(frameId:text:)` | `func index(frameId: UInt64, text: String) async throws` |
| `indexBatch(frameIds:texts:)` | `func indexBatch(frameIds: [UInt64], texts: [String]) async throws` |
| `remove(frameId:)` | `func remove(frameId: UInt64) async throws` |
| `search(query:topK:)` | `func search(query: String, topK: Int) async throws -> [TextSearchResult]` |
| `searchPlainText(query:topK:)` | `func searchPlainText(query: String, topK: Int) async throws -> [TextSearchResult]` |
| `searchFTSSyntax(query:topK:)` | `func searchFTSSyntax(query: String, topK: Int) async throws -> [TextSearchResult]` |
| Entity/Fact methods | Same as `WaxStructuredMemorySession` (see below) |
| `serialize(compact:)` | `func serialize(compact: Bool = false) async throws -> Data` |
| `stageForCommit(into:compact:)` | `func stageForCommit(into: Wax, compact: Bool = false) async throws` |

**Constants:** `maxResults = 10_000`, `flushThreshold = 2_048`, `structuredFlushThreshold = 512`, `plainTextTokenLimit = 24`.

#### `TextSearchResult` (struct, Equatable, Sendable)

```swift
public var frameId: UInt64
public var score: Double
public var snippet: String?
```

---

### 31.3 WaxVectorSearch Module

#### `VectorSearchEngine` (protocol, Sendable)

```swift
var dimensions: Int { get }
func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)]
func add(frameId: UInt64, vector: [Float]) async throws
func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws
func remove(frameId: UInt64) async throws
func stageForCommit(into wax: Wax) async throws
```

#### `MetalVectorEngine` (actor, VectorSearchEngine)

| Feature | Detail |
|---------|--------|
| `isAvailable` | Static check for Metal GPU support |
| `init(metric:dimensions:)` | Create empty engine |
| `load(from:metric:dimensions:)` | Load from committed Wax index |
| `add/addBatch/addBatchStreaming` | Insert vectors (streaming uses chunks of 256) |
| `search(vector:topK:)` | GPU cosine similarity search |
| `serialize()/deserialize(_:)` | Buffer-based serialization |
| `debugBufferPoolStats()` | Transient MTLBuffer pool diagnostics |

**GPU thresholds:** gpuTopKThreshold = 1,000; simd8DimensionThreshold = 384.

#### `USearchVectorEngine` (actor, VectorSearchEngine)

Same API surface as MetalVectorEngine. Uses USearch C++ HNSW library with M=16 connectivity, F32 quantization.

#### `VectorMetric` (enum, Sendable, Equatable)

| Case | Score Conversion |
|------|-----------------|
| `.cosine` | `score = 1 - distance` |
| `.dot` | `score = -distance` |
| `.l2` | `score = -distance` |

Methods: `toVecSimilarity()`, `toUSearchMetric()`, `score(fromDistance:)`.

#### `VectorSerializer` (enum)

| Method | Description |
|--------|-------------|
| `detectEncoding(from:)` | Detect USearch vs Metal encoding |
| `serializeUSearchIndex(_:metric:dimensions:vectorCount:)` | Serialize to MV2V blob |
| `decodeVecSegment(from:)` | Full decode (USearch or Metal) |
| `loadUSearchIndex(_:fromPayload:)` | Buffer-based load (10-100x faster) |

**Magic:** `"MV2V"` (0x4D563256). Encodings: 1=USearch, 2=Metal.

#### `EmbeddingProvider` (protocol, Sendable)

```swift
var dimensions: Int { get }
var normalize: Bool { get }
var identity: EmbeddingIdentity? { get }
var executionMode: ProviderExecutionMode { get }
func embed(_ text: String) async throws -> [Float]
```

#### `BatchEmbeddingProvider` (protocol, extends EmbeddingProvider)

```swift
func embed(batch texts: [String]) async throws -> [[Float]]
```

#### `MultimodalEmbeddingProvider` (protocol, Sendable)

```swift
var dimensions: Int { get }
var normalize: Bool { get }
var identity: EmbeddingIdentity? { get }
var executionMode: ProviderExecutionMode { get }
func embed(text: String) async throws -> [Float]
func embed(image: CGImage) async throws -> [Float]
```

#### `EmbeddingIdentity` (struct, Sendable, Equatable)

```swift
public var provider: String?   // e.g., "Wax", "Ollama"
public var model: String?      // e.g., "all-MiniLM-L6-v2"
public var dimensions: Int?    // e.g., 384
public var normalized: Bool?   // e.g., true
```

#### `ProviderExecutionMode` (enum, String, Sendable)

| Case | Description |
|------|-------------|
| `.onDeviceOnly` | No network calls |
| `.mayUseNetwork` | May call cloud APIs (rejected when `requireOnDeviceProviders = true`) |

#### `VectorEnginePreference` (enum, Sendable, Equatable)

| Case | Description |
|------|-------------|
| `.auto` | Runtime best-effort (Metal if available) |
| `.metalPreferred` | Prefer Metal GPU |
| `.cpuOnly` | Force CPU (USearch) |

#### Metal Compute Kernels

| Kernel | Strategy | Dims |
|--------|----------|------|
| `cosineDistanceKernel` | Scalar | Any |
| `cosineDistanceKernelOptimized` | Scalar + threadgroup cache + 4x unroll | Any |
| `cosineDistanceKernelSIMD4` | `float4` vectorization | div-by-4 |
| `cosineDistanceKernelSIMD8` | Dual `float4` accumulators (ILP) | >= 384 |
| `topKReduceDistances` | Per-threadgroup heap/bitonic selection | -- |
| `topKReduceEntries` | Merge stage for multi-pass top-K | -- |

---

### 31.4 WaxVectorSearchMiniLM Module

#### `MiniLMEmbedder` (actor, EmbeddingProvider, BatchEmbeddingProvider)

Availability: macOS 15.0+, iOS 18.0+

| Property | Value |
|----------|-------|
| `dimensions` | 384 (nonisolated) |
| `normalize` | true (nonisolated) |
| `identity` | `EmbeddingIdentity(provider: "Wax", model: "MiniLMAll", dimensions: 384, normalized: true)` |
| `maximumBatchSize` | 256 (static) |

| Method | Description |
|--------|-------------|
| `init()` | Load from bundle |
| `init(config: Config)` | Load with custom config (batch size, MLModelConfiguration) |
| `embed(_ text:) -> [Float]` | Single text embedding |
| `embed(batch:) -> [[Float]]` | Batch embedding with streaming |
| `prewarm(batchSize:)` | Pre-warm model with dummy data |
| `isUsingANE() -> Bool` | Check Neural Engine usage |
| `currentComputeUnits() -> MLComputeUnits` | Active compute units |

#### `BertTokenizer` (final class, @unchecked Sendable)

| Method | Description |
|--------|-------------|
| `init()` | Load bundled vocabulary (~30K tokens) |
| `tokenize(text:) -> [String]` | Two-stage tokenization (basic + wordpiece) |
| `buildModelTokens(sentence:) -> [Int]` | Full pipeline: tokenize + [CLS]/[SEP] + pad to 512 |
| `buildBatchInputs(sentences:maxSequenceLength:sequenceLengthBuckets:)` | Batch MLMultiArray construction |
| `buildBatchInputsWithReuse(sentences:...:reuse:)` | Buffer-reusing variant |
| `detokenize(tokens:) -> String` | Lossy reverse |

**Sequence length buckets:** [32, 64, 128, 256, 384, 512]

#### `MiniLMEmbeddings` (final class)

CoreML model wrapper around `all_MiniLM_L6_v2.mlmodelc`:
- `encode(sentence:) -> [Float]?` -- single embedding
- `encode(batch:) -> [[Float]]?` -- batch embedding
- `encode(batch:reuseBuffers:) -> [[Float]]?` -- buffer-reusing batch
- Thread-safe model cache (`ModelCache` singleton with `NSLock`)
- Float16 -> Float32 via Accelerate `vDSP`

#### `BatchInputBuffers` (struct, @unchecked Sendable)

Pre-allocated `MLMultiArray` pair for reuse across batch calls: `inputIds`, `attentionMask`, `batchSize`, `sequenceLength`.

---

### 31.5 Wax Module -- Sessions & Orchestration

#### `WaxSession` (actor)

Session-scoped view over a `Wax` instance.

**Configuration**

```swift
// Mode
enum Mode: Sendable, Equatable {
    case readOnly
    case readWrite(WriterPolicy = .wait)
}

// Config
struct Config: Sendable, Equatable {
    var enableTextSearch: Bool = true
    var enableVectorSearch: Bool = true
    var enableStructuredMemory: Bool = true
    var vectorEnginePreference: VectorEnginePreference = .auto
    var vectorMetric: VectorMetric = .cosine
    var vectorDimensions: Int? = nil
}
```

**Key Methods**

| Method | Description |
|--------|-------------|
| `init(wax:mode:config:)` | Open session |
| `close()` | Release resources |
| `search(_: SearchRequest) -> SearchResponse` | Unified search |
| `searchText(query:topK:) -> [TextSearchResult]` | BM25 text search |
| `put(_:options:compression:) -> UInt64` | Store frame |
| `put(_:embedding:identity:options:compression:) -> UInt64` | Store frame + embedding |
| `putBatch(contents:embeddings:...) -> [UInt64]` | Batch store + embeddings |
| `indexText(frameId:text:)` | Index text for BM25 |
| `upsertEntity(key:kind:aliases:nowMs:) -> EntityRowID` | Entity upsert |
| `assertFact(subject:predicate:object:...) -> FactRowID` | Assert fact |
| `retractFact(factId:atMs:)` | Retract fact |
| `facts(about:predicate:asOf:limit:) -> StructuredFactsResult` | Query facts |
| `stage(compact:)` / `commit(compact:)` | Stage and commit indexes |

**Convenience on Wax:**

```swift
func openSession(_ mode: WaxSession.Mode, config: WaxSession.Config) async throws -> WaxSession
func withSession<T>(_ mode:, config:, _ operation:) async throws -> T  // Auto-closes
```

#### `MemoryOrchestrator` (actor)

High-level text-RAG API wrapping `WaxSession`.

**Initialization**

```swift
init(at: URL, config: OrchestratorConfig = .default, embedder: (any EmbeddingProvider)? = nil) async throws
static func openMiniLM(at: URL, config: OrchestratorConfig = .default) async throws -> MemoryOrchestrator
static func openMiniLM(at: URL, overrides: MiniLMEmbeddings.Overrides, config: OrchestratorConfig = .default) async throws -> MemoryOrchestrator
```

**Core Methods**

| Method | Description |
|--------|-------------|
| `remember(_ content:metadata:)` | Chunk, embed, and ingest text |
| `remember(fileAt:metadata:)` | Ingest from local file |
| `remember(pdfAt:metadata:)` | Ingest from PDF |
| `recall(query:) -> RAGContext` | RAG context assembly |
| `recall(query:embedding:) -> RAGContext` | With pre-computed embedding |
| `recall(query:embeddingPolicy:) -> RAGContext` | With policy control |
| `search(query:mode:topK:frameFilter:) -> [MemorySearchHit]` | Direct search |
| `flush()` | Commit pending writes |
| `close()` | Flush + close |

**Session Management**

| Method | Description |
|--------|-------------|
| `startSession() -> UUID` | Begin scoped session |
| `endSession()` | End active session |
| `activeSessionId() -> UUID?` | Current session |

**Handoff**

| Method | Description |
|--------|-------------|
| `rememberHandoff(content:project:pendingTasks:sessionId:) -> UInt64` | Store handoff |
| `latestHandoff(project:) -> HandoffRecord?` | Retrieve latest |

**Structured Memory**

| Method | Description |
|--------|-------------|
| `upsertEntity(key:kind:aliases:commit:) -> EntityRowID` | Upsert entity |
| `assertFact(subject:predicate:object:validFromMs:validToMs:evidence:commit:) -> FactRowID` | Assert fact |
| `retractFact(factId:atMs:commit:)` | Retract fact |
| `facts(about:predicate:asOfMs:limit:) -> StructuredFactsResult` | Query facts |
| `resolveEntities(matchingAlias:limit:) -> [StructuredEntityMatch]` | Entity resolution |

**Statistics**

| Method | Description |
|--------|-------------|
| `runtimeStats() -> RuntimeStats` | Store + engine stats |
| `sessionRuntimeStats() -> SessionRuntimeStats` | Session-scoped stats |

**Maintenance (MaintenableMemory protocol)**

| Method | Description |
|--------|-------------|
| `optimizeSurrogates(options:generator:) -> MaintenanceReport` | Generate/update surrogates |
| `compactIndexes(options:) -> MaintenanceReport` | Compact text + vector indexes |
| `rewriteLiveSet(to:options:) -> LiveSetRewriteReport` | Deep compaction |
| `runScheduledLiveSetMaintenanceNow() -> ScheduledLiveSetMaintenanceReport` | Immediate maintenance |

#### `OrchestratorConfig` (struct, Sendable)

```swift
var enableTextSearch: Bool = true
var enableVectorSearch: Bool = true
var enableStructuredMemory: Bool = false
var enableAccessStatsScoring: Bool = false
var rag: FastRAGConfig = .init()
var chunking: ChunkingStrategy = .tokenCount(targetTokens: 400, overlapTokens: 40)
var ingestConcurrency: Int = 1
var ingestBatchSize: Int = 32
var embeddingCacheCapacity: Int = 2_048
var useMetalVectorSearch: Bool = true
var requireOnDeviceProviders: Bool = true
var liveSetRewriteSchedule: LiveSetRewriteSchedule = .disabled
```

#### `WaxPrewarm` (enum)

```swift
static func tokenizer() async
static func miniLM(sampleText: String = "hello") async throws  // #if canImport(WaxVectorSearchMiniLM)
```

---

### 31.6 Wax Module -- RAG Pipeline

#### `FastRAGConfig` (struct, Sendable, Equatable)

| Property | Default | Description |
|----------|---------|-------------|
| `mode` | `.fast` | `.fast` or `.denseCached` |
| `maxContextTokens` | 1500 | Total token budget |
| `expansionMaxTokens` | 600 | Expanded item budget |
| `expansionMaxBytes` | 2 MiB | Hard byte cap |
| `snippetMaxTokens` | 200 | Per-snippet cap |
| `maxSnippets` | 24 | Max snippet items |
| `maxSurrogates` | 8 | Max surrogates (denseCached mode) |
| `surrogateMaxTokens` | 60 | Per-surrogate cap |
| `searchTopK` | 24 | Search parameter |
| `searchMode` | `.hybrid(alpha: 0.5)` | Search mode |
| `rrfK` | 60 | RRF parameter |
| `previewMaxBytes` | 512 | Preview byte limit |
| `enableAnswerFocusedRanking` | true | Deterministic reranking |
| `answerRerankWindow` | 12 | Rerank window |
| `answerDistractorPenalty` | 0.30 | Distractor penalty |
| `tierSelectionPolicy` | `.importanceBalanced` | Surrogate tier selection |
| `enableQueryAwareTierSelection` | true | Query-aware selection |
| `deterministicNowMs` | nil | Fixed clock for tests |
| `strictDeterministicNow` | false | Require deterministic clock |

#### `FastRAGContextBuilder` (struct, Sendable)

```swift
func build(
    query: String,
    embedding: [Float]? = nil,
    vectorEnginePreference: VectorEnginePreference = .auto,
    wax: Wax,
    session: WaxSession? = nil,
    frameFilter: FrameFilter? = nil,
    accessStatsManager: AccessStatsManager? = nil,
    config: FastRAGConfig = .init()
) async throws -> RAGContext
```

Static helpers: `rerankCandidatesForAnswer()`, `shouldUseFullFrameForSnippet()`, `validateExpansionPayloadSize()`.

#### `RAGContext` (struct, Sendable, Equatable)

```swift
struct RAGContext {
    var query: String
    var items: [Item]
    var totalTokens: Int

    struct Item {
        var kind: ItemKind      // .snippet, .expanded, .surrogate
        var frameId: UInt64
        var score: Float
        var sources: [SearchResponse.Source]
        var text: String
    }
}
```

#### `TokenCounter` (actor)

| Method | Description |
|--------|-------------|
| `init(encoding:cacheCapacity:)` | Create with cl100k_base |
| `shared(encoding:cacheCapacity:)` | Shared singleton |
| `preload(encoding:) -> Bool` | Background preload |
| `count(_ text:) -> Int` | Count tokens |
| `truncate(_:maxTokens:) -> String` | Truncate to budget |
| `encode(_:) -> [UInt32]` | Text to tokens |
| `decode(_:) -> String` | Tokens to text |
| `countBatch/encodeBatch/truncateBatch` | Parallel batch variants |
| `countAndTruncateBatch` | Combined single-pass |

Max tokenization: 8 MiB per text.

#### `QueryAnalyzer` (struct, Sendable)

```swift
func analyze(query:) -> QuerySignals
func normalizedTerms(query:) -> [String]
func entityTerms(query:) -> Set<String>
func yearTerms(in:) -> Set<String>
func dateLiterals(in:) -> [String]
func normalizedDateKeys(in:) -> Set<String>
func containsDateLiteral(_:) -> Bool
func detectIntent(query:) -> QueryIntent
```

#### `QueryIntent` (OptionSet, Sendable)

| Case | Bit |
|------|-----|
| `.asksLocation` | 0 |
| `.asksDate` | 1 |
| `.asksOwnership` | 2 |
| `.multiHop` | 3 |

#### `QuerySignals` (struct, Sendable, Equatable)

```swift
var hasSpecificEntities: Bool
var wordCount: Int
var hasQuotedPhrases: Bool
var specificityScore: Float  // 0.0-1.0
```

#### `DeterministicAnswerExtractor` (struct, Sendable)

Regex-based answer extraction: ownership, launch dates, appointments, locations, allergies, preferences, pet names. Lexical similarity scoring with term/entity/date coverage.

#### Tier Selection Types

**`SurrogateTier`** (enum): `.full`, `.gist`, `.micro`

**`TierSelectionPolicy`** (enum): `.disabled`, `.ageOnly(AgeThresholds)`, `.importance(ImportanceThresholds)`

**`AgeThresholds`** (struct): `recentDays: Int = 7`, `oldDays: Int = 30`

**`ImportanceThresholds`** (struct): `fullThreshold: Float = 0.6`, `gistThreshold: Float = 0.3`

**`SurrogateTierSelector`** (struct): `selectTier(context:) -> SurrogateTier`, `extractTier(from:tier:) -> String?`

**`TierSelectionContext`** (struct): `frameTimestamp`, `accessStats?`, `querySignals?`, `nowMs`

**`ImportanceScorer`** (struct): Three-signal weighted scoring (age decay 1w half-life + frequency log-scale + recency 1d half-life). Returns `ImportanceScore` with component breakdown.

**`ImportanceScoringConfig`** (struct): `ageWeight: 0.3`, `frequencyWeight: 0.4`, `recencyWeight: 0.3`, `ageHalfLifeHours: 168`, `recencyHalfLifeHours: 24`.

#### `NativeBpeTokenizer` (final class, @unchecked Sendable)

Fully offline `cl100k_base` BPE tokenizer:
- `init(encoding:)` -- loads bundled `.tiktoken` file
- `encode(_ text:) -> [UInt32]` -- regex + BPE merge heap
- `decode(_:) -> String` -- token IDs to text
- Per-piece LRU cache for subword merging

---

### 31.7 Wax Module -- Unified Search

#### `SearchRequest` (struct, Sendable, Equatable)

```swift
var query: String?
var embedding: [Float]?
var vectorEnginePreference: VectorEnginePreference = .auto
var mode: SearchMode = .textOnly
var topK: Int = 10
var minScore: Float? = nil
var timeRange: TimeRange? = nil
var frameFilter: FrameFilter? = nil
var asOfMs: Int64 = Int64.max
var structuredMemory: StructuredMemorySearchOptions = .init()
var rrfK: Int = 60
var previewMaxBytes: Int = 512
var metadataLoadingThreshold: Int = 50
var allowTimelineFallback: Bool = false
var timelineFallbackLimit: Int = 10
var enableRankingDiagnostics: Bool = false
var rankingDiagnosticsTopK: Int = 10
```

#### `SearchResponse` (struct, Sendable, Equatable)

```swift
var results: [Result]

struct Result {
    var frameId: UInt64
    var score: Float
    var previewText: String?
    var sources: [Source]
    var rankingDiagnostics: RankingDiagnostics?
}

enum Source: String, CaseIterable {
    case text, vector, timeline, structuredMemory
}

struct RankingDiagnostics {
    var bestLaneRank: Int?
    var laneContributions: [RankingLaneContribution]
    var tieBreakReason: RankingTieBreakReason
}

struct RankingLaneContribution {
    var source: Source
    var weight: Float
    var rank: Int
    var rrfScore: Float
}

enum RankingTieBreakReason: String {
    case topResult, rerankComposite, fusedScore, bestLaneRank, frameID
}
```

#### `SearchMode` (enum, Sendable, Equatable)

| Case | Description |
|------|-------------|
| `.textOnly` | BM25 only |
| `.vectorOnly` | Vector similarity only |
| `.hybrid(alpha: Float)` | 0 = all vector, 1 = all text |

#### `TimeRange` (struct, Sendable, Equatable)

`after: Int64?`, `before: Int64?`. Method: `contains(_ timestamp:) -> Bool`.

#### `FrameFilter` (struct, Sendable, Equatable)

`includeDeleted`, `includeSuperseded`, `includeSurrogates`, `frameIds: Set<UInt64>?`, `metadataFilter: MetadataFilter?`.

#### `MetadataFilter` (struct, Sendable, Equatable)

`requiredEntries: [String: String]`, `requiredTags: [TagPair]`, `requiredLabels: [String]`.

#### `StructuredMemorySearchOptions` (struct, Sendable, Equatable)

`weight: Float = 0.2`, `maxEntityCandidates: Int = 16`, `maxFacts: Int = 64`, `maxEvidenceFrames: Int = 32`, `requireEvidenceSpan: Bool = false`.

#### `QueryType` (enum, String, CaseIterable, Sendable)

| Case | Signal |
|------|--------|
| `.factual` | "what is", "define" |
| `.semantic` | "how", "why", "explain" |
| `.temporal` | "when", "yesterday", "last" |
| `.exploratory` | Fallback |

#### `RuleBasedQueryClassifier` (enum)

`static func classify(_ query: String) -> QueryType`

#### `AdaptiveFusionConfig` (struct, Sendable)

`func weights(for queryType: QueryType) -> FusionWeights`

#### `FusionWeights` (struct, Sendable, Equatable)

`bm25: Float`, `vector: Float`, `temporal: Float`.

#### `HybridSearch` (enum)

```swift
static func rrfFusion(textResults:vectorResults:k:alpha:) -> [(UInt64, Float)]
static func rrfFusion(lists:k:) -> [(UInt64, Float)]  // Multi-list weighted RRF
```

#### `UnifiedSearchEngineCache` (actor)

Shared singleton cache for text/vector search engines. Keys by Wax instance + index checksum/stamp. Methods: `textEngine(for:)`, `vectorEngine(for:queryEmbeddingDimensions:preference:)`, `invalidate(for:)`, `snapshotStats()`, `snapshotEntryCounts()`.

---

### 31.8 Wax Module -- PhotoRAG & VideoRAG

#### `PhotoRAGOrchestrator` (actor)

```swift
init(storeURL:config:embedder:ocr:captioner:) async throws
func syncLibrary(scope: PhotoScope) async throws
func ingest(assets: [PHAsset]) async throws
func ingest(assetIDs: [String]) async throws
func recall(_ query: PhotoQuery) async throws -> PhotoRAGContext
func delete(assetID: String) async throws
func flush() async throws
```

#### `PhotoRAGConfig` (struct, Sendable, Equatable)

| Property | Default | Description |
|----------|---------|-------------|
| `pipelineVersion` | `"photo_rag_v1"` | Version string |
| `ingestConcurrency` | 2 | Parallel ingest |
| `embedMaxPixelSize` | 512 | Embed image size |
| `ocrMaxPixelSize` | 1024 | OCR image size |
| `thumbnailMaxPixelSize` | 256 | Thumbnail size |
| `enableOCR` | true | Enable OCR |
| `enableRegionEmbeddings` | true | Enable region crops |
| `maxRegionsPerPhoto` | 8 | Max regions |
| `maxOCRBlocksPerPhoto` | 64 | Max OCR blocks per photo |
| `maxOCRSummaryLines` | 32 | Max OCR summary lines |
| `regionEmbeddingConcurrency` | 4 | Parallel region embedding |
| `searchTopK` | 200 | Search candidates |
| `hybridAlpha` | 0.5 | Text vs image weight |
| `vectorEnginePreference` | `.auto` | Metal/CPU engine preference |
| `textEmbeddingWeight` | 0.6 | Text embedding weight |
| `requireOnDeviceProviders` | true | On-device only |
| `includeThumbnailsInContext` | true | Include thumbnails in context |
| `includeRegionCropsInContext` | true | Include region crops in context |
| `regionCropMaxPixelSize` | 1024 | Region crop size |
| `queryEmbeddingCacheCapacity` | 256 | Query embedding LRU cache |

#### PhotoRAG Types

| Type | Description |
|------|-------------|
| `PhotoQuery` | text?, image?, timeRange?, location?, filters, resultLimit, contextBudget |
| `PhotoRAGContext` | query, items, diagnostics (usedTextTokens, degradedResultCount) |
| `PhotoRAGItem` | assetID, score, evidence, summaryText, thumbnail?, regions |
| `PhotoRAGItem.Evidence` | `.vector`, `.text(snippet:)`, `.region(bbox:)`, `.timeline` |
| `PhotoNormalizedRect` | x, y, width, height (all [0,1], top-left origin) |
| `PhotoPixel` | data, format, width, height |
| `PhotoCoordinate` | latitude (-90..90), longitude (-180..180) |
| `PhotoLocationQuery` | center, radiusMeters |
| `PhotoScope` | `.fullLibrary`, `.assetIDs([String])` |
| `PhotoQueryImage` | data, format (.jpeg/.png/.heic/.other(uti:)) |
| `PhotoFilters` | Empty struct (reserved for future filter expressions) |
| `ContextBudget` | maxTextTokens:1200, maxImages:6, maxRegions:8, maxOCRLinesPerItem:8 |

#### PhotoRAG Protocols

**`OCRProvider`** (protocol, Sendable): `recognizeText(in: CGImage) async throws -> [RecognizedTextBlock]`, `executionMode`

**`CaptionProvider`** (protocol, Sendable): `caption(for: CGImage) async throws -> String`, `executionMode`

**`VisionOCRProvider`** (struct): Built-in OCR using `VNRecognizeTextRequest`, `.accurate` or `.fast` accuracy.

**`RecognizedTextBlock`** (struct): `text`, `bbox: PhotoNormalizedRect`, `confidence: Float`, `language: String?`

#### PhotoRAG Metadata Keys

`photos.asset_id`, `photo.capture_ms`, `photo.location.lat/lon`, `photo.camera.make/model`, `photo.lens`, `photo.width/height`, `photo.bbox.x/y/w/h`, etc.

#### PhotoRAG Frame Kinds

`photo.root`, `photo.ocr.block`, `photo.ocr.summary`, `photo.caption.short`, `photo.tags`, `photo.region`, `system.photos.sync_state`.

---

#### `VideoRAGOrchestrator` (actor)

```swift
init(storeURL:config:embedder:transcriptProvider:) async throws
func ingest(files: [VideoFile]) async throws
func syncLibrary(scope: VideoScope) async throws
func recall(_ query: VideoQuery) async throws -> VideoRAGContext
func delete(videoID: VideoID) async throws
func flush() async throws
```

#### `VideoRAGConfig` (struct, Sendable, Equatable)

| Property | Default | Description |
|----------|---------|-------------|
| `pipelineVersion` | `"video_rag_v1"` | Version string |
| `segmentDurationSeconds` | 10 | Segment length |
| `segmentOverlapSeconds` | 0 | Overlap between segments |
| `maxSegmentsPerVideo` | 360 | Max segments |
| `segmentWriteBatchSize` | 32 | Write batch size |
| `maxTranscriptBytesPerSegment` | 8192 | Transcript cap |
| `embedMaxPixelSize` | 512 | Keyframe embed size |
| `searchTopK` | 400 | Search candidates |
| `hybridAlpha` | 0.5 | Text vs keyframe weight |
| `vectorEnginePreference` | `.auto` | Metal/CPU engine preference |
| `timelineFallbackLimit` | 50 | Timeline fallback cap |
| `requireOnDeviceProviders` | true | On-device only |
| `includeThumbnailsInContext` | false | Include thumbnails in context |
| `thumbnailMaxPixelSize` | 256 | Thumbnail size |
| `queryEmbeddingCacheCapacity` | 256 | Query embedding LRU cache |

#### VideoRAG Types

| Type | Description |
|------|-------------|
| `VideoID` | `source: .photos/.file`, `id: String` |
| `VideoFile` | `id`, `url`, `captureDate?` |
| `VideoQuery` | text?, timeRange?, videoIDs?, resultLimit, segmentLimitPerVideo, contextBudget |
| `VideoRAGContext` | query, items, diagnostics (usedTextTokens, degradedVideoCount) |
| `VideoRAGItem` | videoID, score, evidence, summaryText, segments |
| `VideoSegmentHit` | startMs, endMs, score, evidence, transcriptSnippet?, thumbnail? |
| `VideoSegmentHit.Evidence` | `.vector`, `.text(snippet:)`, `.timeline` |
| `VideoContextBudget` | maxTextTokens:1200, maxThumbnails:0, maxTranscriptLinesPerSegment:8 |
| `VideoThumbnail` | data, format (.png/.jpeg), width, height |
| `VideoIngestError` | `.fileMissing`, `.unsupportedPlatform`, `.invalidVideo`, `.embedderDimensionMismatch` |

#### VideoRAG Protocols

**`VideoTranscriptProvider`** (protocol, Sendable): `transcript(for: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk]`, `executionMode`

**`VideoTranscriptRequest`** (struct): `videoID`, `localFileURL`, `durationMs?`

**`VideoTranscriptChunk`** (struct): `startMs`, `endMs`, `text`

#### VideoRAG Metadata Keys

`video.source`, `video.source_id`, `video.file_url`, `video.capture_ms`, `video.duration_ms`, `video.segment.index/count/start_ms/end_ms/mid_ms`, etc.

#### VideoRAG Frame Kinds

`video.root`, `video.segment`.

---

### 31.9 Wax Module -- Maintenance & Utilities

#### Surrogate Generation

**`SurrogateGenerator`** (protocol, Sendable): `algorithmID: String`, `generateSurrogate(sourceText:maxTokens:) -> String`

**`HierarchicalSurrogateGenerator`** (protocol, extends SurrogateGenerator): `generateTiers(sourceText:config:) -> SurrogateTiers`

**`ExtractiveSurrogateGenerator`** (struct): Default extractive implementation with MMR (Maximal Marginal Relevance) diversity selection and Jaccard similarity.

**`SurrogateTiers`** (struct, Codable): `full`, `gist`, `micro`, `version`, `generatedAtMs`

**`SurrogateTierConfig`** (struct):
- `.default` -- full:100, gist:25, micro:8 tokens
- `.compact` -- full:50, gist:15, micro:5 tokens
- `.verbose` -- full:150, gist:40, micro:12 tokens

#### Maintenance Reports

**`MaintenanceOptions`** (struct): `maxFrames?`, `maxWallTimeMs?`, `surrogateMaxTokens:60`, `overwriteExisting`, `enableHierarchicalSurrogates:true`, `tierConfig`

**`MaintenanceReport`** (struct): `scannedFrames`, `eligibleFrames`, `generatedSurrogates`, `supersededSurrogates`, `skippedUpToDate`, `didTimeout`

**`LiveSetRewriteOptions`** (struct): `overwriteDestination`, `dropNonLivePayloads:true`, `verifyDeep`

**`LiveSetRewriteReport`** (struct): Frame counts, byte sizes before/after, index copy flags, duration.

**`LiveSetRewriteSchedule`** (struct): `enabled`, `checkEveryFlushes:32`, `minDeadPayloadBytes:64MiB`, `minDeadPayloadFraction:0.25`, `minimumIdleMs:15000`, `minIntervalMs:300000`, `verifyDeep`, `destinationDirectory?`, `keepLatestCandidates:2`

**`ScheduledLiveSetMaintenanceReport`** (struct): `outcome` (disabled/cadenceSkipped/cooldownSkipped/idleSkipped/belowThreshold/alreadyRunningSkipped/rewriteSucceeded/rewriteFailed/validationFailedRolledBack), `triggeredByFlush`, `flushCount`, `deadPayloadBytes/Fraction`, `candidateURL?`, `rewriteReport?`, `rollbackPerformed`, `notes`

#### Text Chunking

**`ChunkingStrategy`** (enum): `.tokenCount(targetTokens: Int, overlapTokens: Int)`

**`TextChunker`** (enum): `static func chunk(text:strategy:) -> [String]`, `static func stream(text:strategy:) -> AsyncStream<String>`

#### File Ingest

**`PDFTextExtractor`** (enum): `static func extractText(url:maxPages:) -> (text: String, pageCount: Int)` (#if canImport(PDFKit))

**`FileIngestError`** (enum, Error): `.fileNotFound`, `.loadFailed`, `.unsupportedTextEncoding`, `.emptyContent`

**`PDFIngestError`** (enum, Error): `.fileNotFound`, `.loadFailed`, `.noExtractableText`

#### Access Stats

**`FrameAccessStats`** (struct, Codable): `frameId`, `accessCount: UInt32`, `lastAccessMs`, `firstAccessMs`. Method: `recordAccess(nowMs:)`.

**`AccessStatsManager`** (actor): `recordAccess(frameId:)`, `recordAccesses(frameIds:)`, `getStats(frameId:)`, `getStats(frameIds:)`, `pruneStats(keepingOnly:)`, `exportStats()`, `exportStatsIfDirty()`, `markPersisted()`, `importStats(_:)`.

#### Embedding Cache

**`EmbeddingMemoizer`** (actor): LRU cache with O(1) get/set via doubly-linked list.

| Method | Description |
|--------|-------------|
| `init(capacity:)` | Pre-allocated |
| `get(_: UInt64) -> [Float]?` | O(1) lookup + LRU promotion |
| `set(_:value:)` | O(1) insert + eviction |
| `getBatch/setBatch` | Batch variants |
| `hitRate -> Double` | Cache performance |
| `resetStats()` | Clear counters |

**`EmbeddingKey`** (enum): `static func make(text:identity:dimensions:normalized:) -> UInt64` -- FNV-1a 64-bit hash.

#### Vector Math

**`VectorMath`** (enum): All `@inlinable` static methods using Accelerate:

| Method | Description |
|--------|-------------|
| `normalizeL2/normalizeL2InPlace` | L2 normalization |
| `dotProduct` | Dot product |
| `cosineSimilarity` | Cosine similarity |
| `cosineSimilarityNormalized` | Fast path for pre-normalized vectors |
| `squaredEuclideanDistance` | L2 squared distance |
| `euclideanDistance` | L2 distance |
| `magnitude` | Vector magnitude |
| `isNormalizedL2(_:tolerance:)` | Check normalization |
| `add/subtract/scale` | Vector arithmetic |

#### Provider Validation

**`ProviderValidation`** (enum): `static func validateOnDevice(_ checks:orchestratorName:) throws` -- enforces `requireOnDeviceProviders` policy.

#### Diagnostics

**`WaxDiagnostics`** (enum): `static func logSwallowed(_:context:fallback:)` -- structured error logging for swallowed errors.
