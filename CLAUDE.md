# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Build (default, includes MiniLM embedder)
swift build

# Build MCP server (macOS only)
swift build --product WaxMCPServer --traits MCPServer

# Build semantic git search TUI (macOS only)
swift build --product WaxRepo --traits WaxRepo

# Run all tests (parallel recommended)
swift test --parallel

# Run by module
swift test --filter WaxCoreTests
swift test --filter WaxIntegrationTests
swift test --filter WaxMCPServerTests

# Run a single test
swift test --filter WaxCoreTests/WALRingTests/testWrapAround

# Run with MiniLM CoreML tests (opt-in, slow)
WAX_TEST_MINILM=1 swift test

# Production readiness gate (full suite, no benchmark classes)
./scripts/quality/production_readiness_gates.sh full

# Soak / burn smoke tests
./scripts/quality/production_readiness_gates.sh soak-smoke
./scripts/quality/production_readiness_gates.sh burn-smoke
```

Benchmark test classes are excluded from `swift test` by default. They include `RAGBenchmarks`, `WALCompactionBenchmarks`, `MetalVectorEngineBenchmark`, etc. Run them individually with `--filter`. The production gate script skips them via regex: `(RAGBenchmarks|RAGBenchmarksMiniLM|WALCompactionBenchmarks|LongMemoryBenchmarkHarness|BatchEmbeddingBenchmark|MetalVectorEngineBenchmark|OptimizationComparisonBenchmark|TokenizerBenchmark|BufferSerializationBenchmark)`.

## Architecture Overview

Wax is an on-device RAG system that stores documents, BM25 indexes, HNSW vector indexes, and embeddings in a single `.mv2s` file (Memory Vision 2.0 Storage). It targets iOS 26+ / macOS 26+ and is written in Swift 6.2 with strict concurrency throughout.

### Module Dependency Graph

```
WaxMCPServer / WaxCLI / WaxRepo
        ↓
      Wax  (orchestration & RAG — public API surface)
     /   \
WaxTextSearch   WaxVectorSearch   WaxVectorSearchMiniLM
        \           /                    /
              WaxCore  (file format, WAL, I/O primitives)
```

| Module | Responsibility |
|---|---|
| `WaxCore` | `.mv2s` file format, WAL ring buffer, FDFile I/O, crash recovery, FrameMeta binary codec, structured memory types |
| `WaxTextSearch` | BM25 full-text search via GRDB/SQLite FTS5; entity/fact storage |
| `WaxVectorSearch` | HNSW vector search (`USearchVectorEngine` CPU, `MetalVectorEngine` GPU) |
| `WaxVectorSearchMiniLM` | CoreML MiniLM embedder (all-MiniLM-L6-v2, 384-dim) — Swift Trait gated |
| `Wax` | `MemoryOrchestrator`, `WaxSession`, `UnifiedSearch`, `FastRAGContextBuilder`, chunking, token counting, surrogate tiers, access stats |
| `WaxMCPServer` | stdio MCP server bridging Claude to Wax via `MemoryOrchestrator` |

### Swift Traits

- `MiniLMEmbeddings` — default; includes CoreML embedder
- `MCPServer` — gates `WaxMCPServer` executable (macOS only)
- `WaxRepo` — gates `wax-repo` TUI executable (macOS only)

All targets use `StrictConcurrency` experimental Swift feature.

## Key Abstractions

### `Wax` actor (`Sources/WaxCore/Wax.swift`)
Primary handle to a `.mv2s` file. Manages the file descriptor, dual headers, WAL ring, TOC, and writer lease queue. All mutable file state lives here. Use `Wax.create(at:)` or `Wax.open(at:)`.

### `WaxSession` actor (`Sources/Wax/WaxSession.swift`)
Session-scoped view over a `Wax` instance. Modes: `.readOnly` or `.readWrite(WriterPolicy)`. Only one `.readWrite` session holds the writer lease at a time. Always call `close()` explicitly for read-write sessions; `deinit` does a best-effort release. Lazily loads text/vector engines on first use.

### `MemoryOrchestrator` actor (`Sources/Wax/Orchestrator/MemoryOrchestrator.swift`)
High-level text-RAG API. Wraps a `WaxSession` (always `.readWrite(.wait)`), a `FastRAGContextBuilder`, an optional embedder with memoization, and scheduled live-set maintenance. `remember()` chunks text, embeds in parallel, and batch-writes frames. **Batch writes are not atomic** — partial ingest on failure leaves orphaned chunks; callers must validate or supersede on error.

### `FastRAGContextBuilder` (`Sources/Wax/RAG/FastRAGContextBuilder.swift`)
Deterministic RAG context assembly. Runs `UnifiedSearch`, optionally reranks, expands the top result, prefetches surrogate tiers (full/gist/micro), and fills a token budget using `cl100k_base` BPE counting. Only the first result is expanded (determinism). Use `FastRAGConfig.deterministicNowMs` for reproducible tier selection in tests.

### `UnifiedSearch` (`Sources/Wax/UnifiedSearch/UnifiedSearch.swift`)
Runs BM25 + vector + structured + temporal searches in parallel, then merges via Reciprocal Rank Fusion (RRF). Query intent is classified by `RuleBasedQueryClassifier` to apply adaptive fusion weights. Candidate pool is expanded to `3 × topK` (max 1000) before fusion.

### `FTS5SearchEngine` actor (`Sources/WaxTextSearch/FTS5SearchEngine.swift`)
GRDB SQLite FTS5 wrapper. Pending ops are batched (flush threshold: 2048 text, 512 structured) to amortize transaction overhead. Reads always trigger a flush if dirty. BM25 scores returned as higher-is-better (SQLite's negative rank is inverted). Safe FTS tokenization caps at 24 tokens and strips FTS operators.

### `MetalVectorEngine` actor (`Sources/WaxVectorSearch/MetalVectorEngine.swift`)
GPU-accelerated cosine similarity search. Vectors stored directly in `MTLBuffer` (Unified Memory, zero-copy). Uses a SIMD8 Metal kernel for 384+-dim vectors. A pool of 8 transient buffers is reused across concurrent searches. GPU top-K reduction is used for 1000+ vectors; CPU heap otherwise. Only cosine metric is supported currently.

### `WALEntryCodec` (`Sources/WaxCore/WAL/WALEntryCodec.swift`)
Binary codec for WAL entries: `putFrame`, `deleteFrame`, `supersedeFrame`, `putEmbedding`. Each entry is checksummed with SHA256. Float arrays use little-endian bulk copy (Apple targets only).

### `PhotoRAGOrchestrator` actor (`Sources/Wax/PhotoRAG/PhotoRAGOrchestrator.swift`)
Photo library RAG. Indexes photos with OCR text + CLIP embeddings (caller supplies a `MultimodalEmbeddingProvider`). Uses `PhotoFrameKind` roles and `PhotoMetadataKey` metadata conventions. Built-in `VisionOCRProvider` for on-device OCR.

### `VideoRAGOrchestrator` actor (`Sources/Wax/VideoRAG/VideoRAGOrchestrator.swift`)
Video RAG. Ingests video files by extracting transcripts (caller supplies a `TranscriptProvider`), chunking by segments, and embedding. Uses `VideoFrameKind` roles and `VideoMetadataKey` metadata conventions.

### Structured Memory (`Sources/WaxCore/StructuredMemory/`)
Entity-fact-predicate graph stored in FTS5. Entities are namespaced (`namespace:id`), facts are `(entity, predicate, value)` triples with temporal `asOf` support. `StructuredMemorySession` on `WaxSession` provides CRUD. `UnifiedSearch` includes structured evidence in fusion when `enableStructuredMemory` is on.

### `OrchestratorConfig` (`Sources/Wax/Orchestrator/OrchestratorConfig.swift`)
Central configuration for `MemoryOrchestrator`. Controls which search engines are enabled (`enableTextSearch`, `enableVectorSearch`, `enableStructuredMemory`), chunking strategy, ingest concurrency/batch size, Metal preference, embedding cache capacity, on-device provider enforcement, and live-set rewrite scheduling.

### `BlockingIOExecutor` (`Sources/WaxCore/IO/BlockingIOExecutor.swift`)
Runs blocking file I/O on a dedicated thread pool to avoid blocking Swift concurrency's cooperative threads. All `FDFile` reads/writes go through this.

### `EmbeddingMemoizer` (`Sources/Wax/Embeddings/EmbeddingMemoizer.swift`)
LRU cache for embeddings keyed by content hash. Wraps any embedding provider to avoid recomputing embeddings for duplicate or recently-seen text. Capacity configured via `OrchestratorConfig.embeddingCacheCapacity`.

## `.mv2s` File Format

```
Offset 0      : Header Page A (4 KB)  ─┐ Dual-buffered; active page
Offset 4096   : Header Page B (4 KB)  ─┘ determined by generation number
Offset 8192   : WAL Ring Buffer (default 256 MiB, wrap-around)
               : Document payloads (append-only, optional LZ4/deflate)
               : Embeddings
               : ...
End of file   : TOC (Table of Contents, max 64 MiB)
               : Footer (64 bytes) + SHA256 checksum
```

**Dual headers**: on every commit the inactive header is written then made active by incrementing the generation number — never corrupt on power loss.

**WAL**: append-only ring buffer. On open, Wax checks for a `walReplaySnapshot` in the header (fast-path recovery); otherwise scans from `walCheckpointPos` to `walWritePos`. Proactive auto-commit triggers when pending WAL bytes exceed a configurable threshold.

**FrameMeta**: every stored frame has a `FrameMeta` with payload offset/length, SHA256 checksum, optional compression metadata, role (`document`/`chunk`), parent/chunk hierarchy, and supersession links.

## Concurrency Model

- **Actor-per-subsystem**: `Wax`, `WaxSession`, `FTS5SearchEngine`, `MetalVectorEngine`, `MemoryOrchestrator` are all actors.
- **Writer lease**: `Wax` enforces one concurrent writer via `WriterPolicy` (`.wait`, `.fail`, `.timeout`).
- **`AsyncReadWriteLock`**: readers coexist; writers exclusive — used inside `Wax` for op-level safety.
- **`FileLock`**: POSIX `fcntl` for inter-process coordination on the `.mv2s` file.

## Constants & Limits (`Sources/WaxCore/Constants.swift`)

| Constant | Value |
|---|---|
| Header page size | 4 KB |
| Header region (A+B) | 8 KB |
| WAL start offset | 8192 |
| Default WAL size | 256 MiB |
| Max frame payload | 256 MiB |
| Max string | 16 MiB |
| Max embedding dims | 1 M |
| Max TOC | 64 MiB |
| Max array count | 10 M |

## MCP Server Tools (`Sources/WaxMCPServer/WaxMCPTools.swift`)

Tools: `wax_remember`, `wax_recall`, `wax_search`, `wax_flush`, `wax_stats`, `wax_session_start/end`, `wax_handoff/handoff_latest`, `wax_entity_upsert`, `wax_fact_assert/retract`, `wax_facts_query`, `wax_entity_resolve`, `wax_video_ingest/recall`, `wax_photo_ingest/recall`.

Key limits: content 128 KB, topK ≤ 200, video paths ≤ 50 per call, entity/predicate IDs ≤ 256 bytes (`a-z A-Z 0-9 . _ : -`), entity keys must be namespaced (`namespace:id`).

## Testing Patterns

- **Framework**: Tests use Swift Testing (`@Test`, `#expect`, `#require`), not XCTest. Import `Testing`, not `XCTest`. Use `@Test func` not `func testX()`. Some legacy benchmark/stability tests still use XCTest (run with `--enable-xctest --disable-swift-testing`).
- **Crash injection**: `FDFile` supports `installFaultPlan(_:)` with `.eio`, `.enospc`, `.shortWrite`, etc. for deterministic failure simulation.
- **WAL replay testing**: `WaxCrashHarness` executable (`Sources/WaxCrashHarness/main.swift`) runs crash injection scenarios end-to-end.
- **MiniLM tests**: gated behind `WAX_TEST_MINILM=1` env var; slow due to CoreML model load.
- **Deterministic RAG tests**: set `FastRAGConfig.deterministicNowMs` to pin the clock for tier selection.
- **Benchmark isolation**: benchmark test classes must be run explicitly with `--filter`; the production gate script skips them via regex.
- **Temp file cleanup**: tests should create `.mv2s` files in a temp directory and clean up. Use `FileManager.default.temporaryDirectory` with a unique subdirectory.

## Key Dependencies

| Package | Used for |
|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite FTS5 full-text search and structured memory storage |
| [USearch](https://github.com/unum-cloud/USearch) | CPU-based HNSW vector index |
| [swift-tiktoken](https://github.com/DePasqualeOrg/swift-tiktoken) | `cl100k_base` BPE token counting for RAG budgets |
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA256 checksums for WAL entries and frame integrity |
| [swift-sdk (MCP)](https://github.com/modelcontextprotocol/swift-sdk) | MCP protocol for `WaxMCPServer` (trait-gated) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | CLI argument parsing for executables |
