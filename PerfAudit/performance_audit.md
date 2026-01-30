# Wax RAG Performance Audit (On-Device Bias)

Date: 2026-01-30

Ground truth logs: `PerfAudit/Raw/*.log` (see `PerfAudit/baseline_results.md`).

---

## 1) Performance Score (0–100)

**Score: 58 / 100**

### Scoring metric (deterministic rubric)

Each category is scored from 0–10, then weighted.

| Category | Weight | What “10/10” means on-device | Current evidence | Score |
|---|---:|---|---|---:|
| **Cold start** | 25% | Embedder usable <200ms; cold open hybrid search <25ms @ 5k docs | MiniLM cold start **3.17s**; cold open hybrid **54ms @ 5k docs** | 3/10 |
| **Steady-state embed throughput** | 20% | True batching: batch-32 is ≥2.5x faster than sequential; ≥300 texts/sec | Batch scaling flat (**~113–115 texts/sec**); batch vs seq **1.06x** | 4/10 |
| **Vector recall latency** | 15% | <2ms @ 10k vectors (topK~24), stable | Metal warm **0.58ms @ 10k/384** | 9/10 |
| **Hybrid recall latency (open + search)** | 10% | <50ms @ 5k docs; <150ms @ 50k docs | **54ms @ 5k** | 7/10 |
| **Ingest throughput (index + IO)** | 15% | 10k hybrid ingest <1s with real embedder excluded; scales sub-quadratic | 10k hybrid **1.64s**, batched **0.72s** | 6/10 |
| **Memory + copies** | 10% | No full-index memcpy on open; peak RSS for hybrid query <100MB | Peak ~**22MB** for unified search; FTS deserialize does full malloc+memcpy | 6/10 |
| **Benchmark observability** | 5% | Microbench coverage for <10ms paths; avoids harness floors | Many measures floor at **~0.103s** | 4/10 |

Weighted total rounds to **58/100**.

### What’s good / acceptable / unacceptable (and what to do)

#### Good (keep, but harden)

1) **Metal vector search query latency is excellent** (0.58ms @ 10k/384 warm).
- **A**: Keep Metal search, but add **size-based engine selection** (Metal for small/hot, USearch for large) + add search scaling benchmarks.
- **B**: Keep Metal always, but implement GPU top‑k to avoid CPU scan at large N (complex; power risk).
- **D**: Leave as-is and accept that brute-force Metal won’t scale past moderate N.

#### Acceptable (needs targeted upgrades)

1) **Cold open hybrid search** is usable at 5k docs (54ms), but has headroom and scaling risk.
- **A**: Remove index open copies (FTS mmap/readonly deserialize); target **<25ms @ 5k**.
- **B**: Background prewarm of unified search engines during app idle; reduces perceived latency, not true cost.
- **C**: Increase caching/keep-alive window; improves UX but increases memory/power.

2) **10k hybrid ingest** is okay (0.72–1.64s excluding real embedder), but scaling is threatened.
- **A**: Fix MetalVectorEngine add/remove complexity (O(1) mapping + swap-remove).
- **B**: Force `.cpuOnly` default for vector engine during ingest; loses GPU benefits, avoids Metal ingest path.
- **C**: Keep current; accept blowups beyond ~10k.

#### Unacceptable (must fix)

1) **MiniLM cold start is 3.17s** (kills first interaction and first ingest).
- **A**: Ship device-specialized compiled model (`.mlmodelc`) and eliminate runtime `compileModel` fallback.
- **B**: Cache compiled model on disk after first compile (still first-run pain; app review risk if not managed).
- **F**: Keep runtime compile; unacceptable for on-device RAG UX.

2) **“Batch embedding” doesn’t batch** (1.06x speedup).
- **A**: Convert model + inputs to fixed shapes with batch dimension; use proper batch prediction; aim ≥2.5x @ batch‑32.
- **B**: Multi-instance model pipeline (2–4 model instances) with bounded concurrency; memory-heavy.
- **D**: Keep current; throughput won’t improve materially.

---

## 2) Benchmark Analysis Summary

Ground truth highlights (numbers are direct from logs):

- **MiniLM dominates real RAG throughput + has huge cold start**:
  - cold start mean **3.17s**; steady embed **9.8ms** (`RAGMiniLMBenchmarks_standard.log`).
  - “Batch” scaling is flat **~8.66–8.87ms/text** across batch sizes 8..64 (**~113–115 texts/sec**) and only **1.06x** vs sequential (`BatchEmbeddingBenchmark.log`).
- **Metal vector search is fast and the lazy GPU sync optimization is real**:
  - warm search **0.58ms @ 10k vectors/384 dims**, **7.3x** faster than cold (4.27ms) (`MetalVectorEngineBenchmark.log`).
- **Cold-open hybrid search scales with corpus size** (open + search):
  - **3.4ms @ 200 docs**, **11.6ms @ 1k**, **54.3ms @ 5k** (`RAGPerformanceBenchmarks_*`).
- **10k ingest scaling (excluding real embedding)**:
  - text-only **1.03s**, hybrid **1.64s**, hybrid batched **0.72s** (`RAGPerformanceBenchmarks_10k.log`).
- **Unified search memory is good in the measured regime**:
  - peak physical memory **~22MB** for hybrid query (`UnifiedSearchHybrid_with_metrics.log`).
- **USearch buffer-based serialization is already a big win**:
  - total **8.1x** faster than file-based round-trip (`BufferSerializationBenchmark.log`).
- **Benchmark harness is masking sub‑10ms paths**:
  - many `measureAsync` timings floor at **~0.103s** (XCTest overhead) → current suite can’t guide micro-optimizations reliably.

---

## 3) Primary Bottleneck Diagnosis

### Dominant limiter: embedding (Core ML MiniLM) — cold start + lack of true batching

**Why it exists**

- **Cold start**: `MiniLMEmbeddings.loadModel` falls back to runtime `MLModel.compileModel(...)` when `all-MiniLM-L6-v2.mlmodelc` isn’t present (`Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift:96–134`).
  - This aligns with the measured **3.17s** cold start.
- **Throughput**: the “batch” path builds N separate `all_MiniLM_L6_v2Input` objects and calls `model.predictions(inputs:)` (`MiniLMEmbeddings.swift:40–66`).
  - Bench shows batch size doesn’t change ms/text → the model + runtime aren’t exploiting batch compute.

**What’s algorithmic vs implementation**

- Algorithmic reality: transformer inference dominates RAG on-device; you don’t win back 10x by micro-optimizing Swift loops.
- Implementation failure: current “batch” is not a true tensor batch, so we leave performance on the table (flat scaling).

### Secondary limiter: MetalVectorEngine ingestion is asymptotically wrong (scaling time bomb)

**Why it exists**

- Adds do `frameIds.firstIndex(of:)` (linear scan) per vector (`MetalVectorEngine.swift:189–249`).
- Removes shift the backing arrays by calling `vectors.remove(at:)` `dimensions` times (`MetalVectorEngine.swift:275–288`).

**Impact**

- Current 10k ingest benchmarks still “pass”, but the asymptotic behavior makes 50k–200k regimes collapse.

### Systemic risk: text index open duplicates memory (FTS5 deserialize copy)

**Why it exists**

- `FTS5Serializer.deserialize` mallocs and memcpy’s the full database image before `sqlite3_deserialize` (`Sources/WaxTextSearch/FTS5Serializer.swift:24–53`).

**Impact**

- For larger corpora, cold open and peak RSS will degrade sharply.

---

## 4) High-Impact Fixes (Step-Function Wins)

### Fix 1 — Eliminate MiniLM runtime compilation (cold start collapse)

- **What to change**
  - Ensure `Bundle.module` ships `all-MiniLM-L6-v2.mlmodelc` (device-specialized) and load it directly.
  - Remove/avoid the runtime fallback that copies `model.mlmodel` + `weight.bin` to temp and calls `MLModel.compileModel(...)`.
- **Why it will work**
  - Compilation dominates cold start; removing it eliminates seconds of work.
  - Core ML also benefits from pre-specialization + caching of device-optimized variants.
- **Expected impact**
  - Cold start: **3.17s → sub‑200ms** on modern devices (target gate).
- **Trade-offs / risks**
  - Build pipeline complexity (need to generate & include `mlmodelc` / or ensure packaging does it).
  - Must validate model runs on iOS targets and isn’t “macOS-only specialized”.

### Fix 2 — True batch embedding (change model shape + runtime usage)

- **What to change**
  - Convert MiniLM CoreML model to accept **batch dimension** and **fixed sequence length** (or enumerated shapes).
  - Emit inputs as a single `MLMultiArray` `[B, T]` for `input_ids` and `attention_mask`, padded to fixed `T`.
  - Use the correct Core ML batch prediction path for a single forward pass per batch.
- **Why it will work**
  - Batch compute amortizes overhead and allows ANE/GPU kernels to run more efficiently.
- **Expected impact**
  - Batch‑32 should be **≥2.5x faster** than sequential; docs/sec should move from **~115 → 250–400** (device-dependent).
- **Trade-offs / risks**
  - More padding work; must select `T` (e.g., 128/256) that matches chunking strategy.
  - Dynamic shapes can block ANE unless using enumerated/fixed shapes.

### Fix 3 — MetalVectorEngine: O(1) indexing + swap-remove (ingest scaling)

- **What to change**
  - Maintain `indexByFrameId: [UInt64: Int]` (or a custom open-addressing map) and keep vectors in a contiguous buffer.
  - Remove by swapping last element into removed slot; update map.
- **Why it will work**
  - Deletes the O(N^2) add path and O(N) remove shifts.
- **Expected impact**
  - 10k ingest drops materially; 100k ingest becomes feasible without catastrophic blowups.
- **Trade-offs / risks**
  - Order of `frameIds` becomes unstable (fine if not relied on); serialization format must encode order or tolerate it.

### Fix 4 — Text index open: zero-copy / mmap strategy

- **What to change**
  - Introduce a read-only “search-only” open path that **does not malloc+memcpy** the entire sqlite DB.
  - Use `sqlite3_deserialize` readonly (or a custom VFS) backed by a stable, mmapped region of the MV2S file.
- **Why it will work**
  - Removes a full memory copy and lowers cold-open latency and RSS.
- **Expected impact**
  - Cold open hybrid search at stress scale (5k docs) moves toward **<25ms** and scales to larger corpora under tighter RSS.
- **Trade-offs / risks**
  - Requires careful lifetime management of the mapped bytes.
  - Updates require copy-on-write or separate mutable DB.

---

## External Research Digest (Used To Justify The Plan)

### Metal 4 (Jan 2026)

- Metal 4 introduces **tensor support and ML encoders** to run inference networks directly in shaders, targeting lower overhead and better resource management.
  - Apple Newsroom: `https://www.apple.com/newsroom/2025/06/apple-supercharges-its-tools-and-technologies-for-developers/`
  - Apple Developer overview: `https://developer.apple.com/metal/`

### Core ML shapes / batching constraints

- Core ML performance is strongly influenced by **input shape specialization**. `coremltools` recommends **enumerated/fixed shapes** for best performance and documents runtime specialization/caching behavior.
  - Flexible inputs guide: `https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html`
  - Model prediction guide (specialization/caching): `https://apple.github.io/coremltools/docs-guides/source/model-prediction.html`

### SQLite deserialize constraints

- SQLite’s `sqlite3_deserialize` supports flags like READONLY/RESIZEABLE/FREEONCLOSE; using it with a copied malloc buffer is worst-case for cold-open RSS.
  - SQLite C API: `https://www.sqlite.org/c3ref/deserialize.html`

### Vector index quantization (USearch)

- USearch supports quantization (`f16`, `i8`) with speed/memory gains and metric constraints for `i8`.
  - USearch quantization docs: `https://unum-cloud.github.io/usearch/quantization.html`
  - USearch similarity/metrics docs: `https://unum-cloud.github.io/usearch/similarity.html`

### Comparable system: MemVid v2

- MemVid v2 reports **sub‑ms search latency** at 50k docs and uses a multi-index MV2 file format with embedded WAL and vector/text indexes.
  - Docs: `https://memvid.com/`
  - File format spec (docs.rs excerpt): `https://docs.rs/memvid-core/latest/memvid_core/index.html`

---

## Deterministic Optimization Plan (Ordered Steps + Gates)

This is written so multiple engineers can execute in parallel with clear pass/fail gates.

### Step 0 — Lock baseline and stop measuring noise (benchmark suite hardening)

**Goal:** Make benchmarks actionable for <10ms paths.

- **Change**
  - Add `timedSamples` microbench tests for:
    - text search (`FTS5SearchEngine.search`)
    - vector search (USearch + Metal)
    - unified hybrid search
    - `FastRAGContextBuilder.build` (fast + denseCached)
  - Gate behind env: `WAX_BENCHMARK_MICRO=1`.
- **Files**
  - `Tests/WaxIntegrationTests/RAGBenchmarks.swift`
  - `Tests/WaxIntegrationTests/RAGBenchmarkSupport.swift`
- **Benchmark gates**
  - New logs print `🧪 ...` lines with mean/p95.
  - For any microbench, require **p95** reported (not just mean).
- **Risk**
  - Increased CI time if always enabled → keep opt-in via env.

### Step 1 — MiniLM cold start: remove runtime compilation path

**Goal:** `minilm_cold_start` mean < **0.20s**.

- **Change**
  - Ensure `all-MiniLM-L6-v2.mlmodelc` is shipped in `Sources/WaxVectorSearchMiniLM/Resources/`.
  - Update build/conversion pipeline so the compiled model exists for all targets.
  - In `MiniLMEmbeddings.loadModel`, treat missing `.mlmodelc` as a **build error** in release builds (do not compile at runtime).
- **Files**
  - `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift`
  - `MODEL_CONVERSION.md` (document the compiled artifact)
  - `Package.swift` (resource inclusion if needed)
- **Benchmark gates**
  - `RAGMiniLMBenchmarks`: `minilm_cold_start` mean < 0.20s; p95 < 0.30s.
- **Risk**
  - Platform-specific compilation artifacts; validate on iOS device.

### Step 2 — True batch embedding (shape + API rewrite)

**Goal:** Batch‑32 ≥ **2.5x** faster than sequential; ≥ **250 texts/sec** steady-state.

- **Change**
  1) Pick a fixed `maxSeqLen` aligned to chunking (e.g. 128 or 256 tokens).
  2) Convert model to accept `[B, T]` and export with fixed/enumerated shapes.
  3) Rewrite tokenizer to emit padded tensors:
     - `input_ids: MLMultiArray(Int32, shape: [B, T])`
     - `attention_mask: MLMultiArray(Int32, shape: [B, T])`
  4) Change `MiniLMEmbeddings.encode(batch:)` to run a **single forward pass** per batch.
- **Files**
  - `Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift`
  - `Sources/WaxVectorSearchMiniLM/CoreML/BertTokenizer.swift`
  - `MODEL_CONVERSION.md`
- **Benchmark gates**
  - `BatchEmbeddingBenchmark`:
    - Batch‑32: ms/text improves by ≥2.5x vs sequential
    - Throughput ≥250 texts/sec on the same machine profile
- **Risk**
  - Padding overhead; choose `T` carefully.
  - Dynamic shapes can fall off ANE; must keep shapes fixed/enumerated.

### Step 3 — MetalVectorEngine ingest redesign (kill O(N^2))

**Goal:** addBatch 100k is bounded and predictable; no quadratic blowup.

- **Change**
  - Replace `frameIds.firstIndex(of:)` with:
    - `indexByFrameId: [UInt64: Int]`
    - vectors stored as contiguous `[Float]` (or `ContiguousArray<Float>`)
  - Implement swap-remove:
    - remove index i by swapping last vector into i and updating both `frameIds` + map
- **Files**
  - `Sources/WaxVectorSearch/MetalVectorEngine.swift`
  - `Sources/Wax/VectorSearchSession.swift` (if any assumptions about ordering)
- **Benchmarks to add**
  - `MetalVectorEngineIngestBenchmark`:
    - addBatch 10k/50k/100k
    - random remove 1k ids
- **Benchmark gates**
  - 100k addBatch completes in <5s on dev Mac; scaling is ~O(N).
- **Risk**
  - Serialization order changes; must preserve correctness of frameId↔vector mapping.

### Step 4 — Vector engine policy: choose Metal vs USearch by size + power

**Goal:** avoid brute-force GPU for large N; preserve low latency for small N.

- **Change**
  - Add heuristics in `WaxVectorSearchSession`:
    - If `vectorCount >= threshold` (e.g. 50k), prefer USearch for queries.
    - Keep Metal for “hot segment” (recent embeddings) and merge results (two-stage topK).
- **Files**
  - `Sources/Wax/VectorSearchSession.swift`
  - `Sources/Wax/UnifiedSearch/*` (hybrid merge)
- **Benchmark gates**
  - New benchmark: `VectorSearchScalingBenchmark` (Metal vs USearch) at 10k/50k/100k.
  - Ensure p95 query latency doesn’t regress at 10k; improves at 100k.
- **Risk**
  - Complexity in merging topK; must keep scoring consistent.

### Step 5 — USearch quantization (memory + bandwidth step change)

**Goal:** reduce vec index memory and improve search throughput.

- **Change**
  - Add config knob for USearch quantization:
    - `.f16` default for most devices
    - `.i8` optional for cosine/dot metrics when quality is acceptable
- **Files**
  - `Sources/WaxVectorSearch/USearchVectorEngine.swift`
  - `Sources/Wax/Orchestrator/OrchestratorConfig.swift` (expose knob)
- **Benchmark gates**
  - New: `USearchQuantizationBenchmark` (recall latency + memory footprint).
- **Risk**
  - Accuracy trade-off; must validate retrieval quality.

### Step 6 — FTS index open: remove full memcpy on open (RSS win)

**Goal:** cut cold-open RSS + time for large corpora.

- **Change**
  - Provide two modes:
    - **Read-only search session**: mmap lex blob, deserialize readonly.
    - **Mutable ingest session**: existing copy-on-write behavior.
- **Files**
  - `Sources/WaxTextSearch/FTS5Serializer.swift`
  - `Sources/WaxTextSearch/FTS5SearchEngine.swift`
  - `Sources/WaxCore/*` (to expose mmapped segment reader)
- **Benchmark gates**
  - New: `TextIndexOpenBenchmark`:
    - open+search p95 improves by ≥2x at stress scale.
- **Risk**
  - Lifetime and concurrency correctness; must add crash-safety tests.

### Step 7 — Micro-optimizations (only after Tier‑1/2 land)

**Goal:** reduce overhead after architectural fixes.

- Replace `TokenizationCache` with O(1) LRU (dict + linked list); gate via `OptimizationComparisonBenchmark`.
- Audit `EmbeddingMemoizer` allocations and key construction; precompute hash; avoid `String` copies.
- Remove redundant normalization work:
  - If embeddings are guaranteed normalized, skip vector magnitude in Metal shader.

---

## Areas To Optimize For “Extreme Performance”

Ordered by expected ROI for on-device RAG:

1) **Core ML embedder cold start** (packaging + specialization)
2) **True batch embedding** (model + tensor IO shape)
3) **MetalVectorEngine ingest complexity** (O(N^2) → O(N))
4) **Vector engine policy** (Metal brute force vs ANN; 2-tier index)
5) **Text index open path** (eliminate full-memory copies)
6) **I/O + commit strategy** (avoid full index rewrite per commit at scale; segment + compaction)
7) **Tokenization + chunking efficiency** (cache, reuse, batch tokenization)
8) **Memory layout / allocations** across ingest pipeline (contiguous buffers, fewer Data copies)
9) **Concurrency model** (bounded pipeline parallelism; avoid actor hop overhead on hot paths)
