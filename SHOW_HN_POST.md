# Show HN Post

**Title:** `Show HN: Wax -- On-device multimodal RAG for iOS/macOS with Metal GPU search`

**URL:** `https://github.com/christopherkarani/Wax`

---

Hey HN,

I built Wax, an open-source Swift framework for on-device Retrieval-Augmented Generation. It indexes text, photos, and videos into a single portable file and searches them with sub-millisecond latency -- with no server, no API calls, and no data leaving the device.

**Why I built this:** Every RAG solution I found required either a cloud vector database (Pinecone, Weaviate) or a local server process (ChromaDB, Qdrant). I wanted something that works like SQLite -- import the library, open a file, query it. Except for multimodal content with hybrid search.

**What it does:**

- **Single-file storage (`.mv2s`)** -- Everything lives in one crash-safe binary file: embeddings, BM25 index, metadata, compressed payloads. You can sync it via iCloud, email it, or commit it to git. Dual-header atomic writes with generation counters mean you can kill -9 mid-write and never corrupt the database.

- **Metal GPU vector search** -- Vectors live directly in Apple Silicon unified memory (`MTLBuffer`). Zero CPU-GPU copy. Adaptive SIMD4/SIMD8 kernels based on embedding dimensions. GPU-side bitonic sort for top-K. Result: **sub-millisecond search on 10K+ vectors** (vs ~100ms on CPU). Falls back to USearch HNSW on non-Metal hardware.

- **Hybrid search with query-adaptive fusion** -- Four parallel search lanes (BM25, vector, timeline, structured memory) fused with Reciprocal Rank Fusion. A lightweight rule-based classifier detects query intent (factual -> boost BM25, temporal -> boost timeline, semantic -> boost vector). Deterministic tie-breaking means identical queries always produce identical results.

- **Photo RAG** -- Indexes your photo library with OCR, captions, GPS binning (~1km resolution), and per-region embeddings. Query "find that receipt from the restaurant" and it searches OCR text, image similarity, and location simultaneously. Fully offline -- iCloud-only photos get metadata-only indexing (marked as degraded, never silently downloaded).

- **Video RAG** -- Segments videos into configurable time windows, extracts keyframe embeddings, and maps transcripts to segments. Results include timecodes so you can jump to the exact moment. Capture-time semantics: "videos from last week" filters by recording date, not segment position.

- **Deterministic context assembly** -- `FastRAGContextBuilder` produces identical output for identical input under strict token budgets. Three-tier surrogate compression (full/gist/micro) adapts based on memory age and importance. Uses bundled cl100k_base BPE tokenization -- no network, no nondeterminism.

- **Bring your own model** -- Wax ships no ML models by default (optional built-in MiniLM via Swift package trait). You provide embedders, OCR, captions, and transcripts via protocols. Each provider declares `onDeviceOnly` or `networkOptional`, validated at init.

**Technical details:**

- 22K lines of Swift 6.2 (strict concurrency), 496 lines of Metal shaders
- Every orchestrator is a Swift actor -- thread safety proven at compile time
- Custom binary codec (little-endian, deterministic serialization, SHA256 checksums)
- Two-phase indexing: stage to WAL, commit atomically
- 91 test files covering integration, property-based, and stress scenarios
- iOS 26+ / macOS 26+

**Quick start:**

```swift
import Wax

let brain = try await MemoryOrchestrator(
    at: URL(fileURLWithPath: "brain.mv2s")
)

// Remember
try await brain.remember(
    "User prefers dark mode and gets headaches from bright screens",
    metadata: ["source": "onboarding"]
)

// Recall with RAG
let context = try await brain.recall(query: "user preferences")
for item in context.items {
    print("[\(item.kind)] \(item.text)")
}
```

For more control, the low-level API exposes the full storage engine:

```swift
import Wax
import WaxCore

let store = try await Wax.create(at: fileURL)
let session = try await WaxSession(wax: store, mode: .readWrite())

let content = Data("Meeting notes from Q4 planning...".utf8)
try await session.put(content, options: FrameMetaSubset(
    kind: "note.meeting",
    searchText: "Meeting notes from Q4 planning...",
    metadata: Metadata(["date": "2026-01-15"])
))
try await session.commit()

let response = try await session.search(
    SearchRequest(query: "Q4 planning decisions", topK: 5)
)
```

**What it's not:**
- Not a cloud service. No telemetry. No vendor lock-in.
- Not an LLM. Wax retrieves context for your LLM of choice.
- Not Python. This is native Swift, optimized for Apple Silicon.

Feedback welcome. The framework is early but the core architecture (storage format, search pipeline, concurrency model) is stable.

GitHub: https://github.com/christopherkarani/Wax
