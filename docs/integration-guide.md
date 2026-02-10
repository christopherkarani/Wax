# Wax Integration Guide: Composing PhotoRAG, VideoRAG, and PDF Ingestion

## Overview

Wax provides three specialized ingestion/retrieval systems that share a common storage engine but operate independently. This guide explains how they compose, when to use each, and how to build a unified multimodal memory layer on top of them.

## Architecture at a Glance

```
┌─────────────────────────────────────────────────────┐
│                  Host Application                    │
│                                                      │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ │
│  │ PhotoRAG     │ │ VideoRAG     │ │ MemoryOrch.  │ │
│  │ Orchestrator │ │ Orchestrator │ │ (Text + PDF) │ │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘ │
│         │                │                │          │
│         └────────────────┼────────────────┘          │
│                          │                           │
│              ┌───────────▼────────────┐              │
│              │     Wax (.mv2s file)    │              │
│              │   Shared storage engine │              │
│              └────────────────────────┘              │
└─────────────────────────────────────────────────────┘
```

Each orchestrator owns its own `Wax` instance and `.mv2s` file. They do **not** share a single database. This is a deliberate design choice: isolation means one orchestrator's crash, corruption, or schema change cannot affect others.

## The Three Systems

### 1. PhotoRAGOrchestrator

**What it indexes:** PHAsset photos from the user's Photos library.

**Input:** Asset IDs (strings) fetched on `@MainActor`.

**Storage per photo:**
- `photo.root` frame: metadata (capture time, GPS, camera info, dimensions)
- `photo.ocr.block` frames: individual OCR text blocks with bounding boxes
- `photo.ocr.summary` frame: concatenated OCR text (text-indexed)
- `photo.caption.short` frame: host-supplied or fallback caption
- `photo.tags` frame: tag list
- `photo.region` frames: crop regions with per-region embeddings

**Query capabilities:**
- Text search (BM25 over OCR text + captions)
- Vector search (multimodal embeddings)
- Location radius filtering
- Time range filtering
- Constraint-only queries (location + time, no text needed)

**Key API:**
```swift
let photoRAG = try await PhotoRAGOrchestrator(
    storeURL: photoStoreURL,
    embedder: myMultimodalEmbedder,
    ocrProvider: VisionOCRProvider()  // default
)

// Ingest
try await photoRAG.ingest(assetIDs: ["asset-id-1", "asset-id-2"])

// Recall
let context = try await photoRAG.recall(PhotoQuery(text: "sunset over mountains"))
```

### 2. VideoRAGOrchestrator

**What it indexes:** Local video files and Photos library videos.

**Input:** `VideoFile` structs (file URL + ID) or PHAsset IDs.

**Storage per video:**
- `video.root` frame: metadata (source, duration, capture time)
- `video.segment` frames: one per time window (default 10s), each with keyframe embedding + mapped transcript text

**Query capabilities:**
- Text search (BM25 over transcript text)
- Vector search (keyframe embeddings)
- Time range filtering (by video capture time)
- Video ID allowlist filtering
- Results grouped by video with timecoded segment hits

**Key API:**
```swift
let videoRAG = try await VideoRAGOrchestrator(
    storeURL: videoStoreURL,
    embedder: myMultimodalEmbedder,
    transcriptProvider: myTranscriptProvider  // host-supplied
)

// Ingest file
try await videoRAG.ingest(files: [VideoFile(id: "vid-1", url: videoURL)])

// Recall
let context = try await videoRAG.recall(VideoQuery(text: "cooking pasta"))
```

### 3. MemoryOrchestrator + PDF Extension

**What it indexes:** Free-form text and PDF documents.

**Input:** Strings or PDF file URLs.

**Storage per document:**
- Document frame (role: `.document`): full text content
- Chunk frames (role: `.chunk`): text chunks with optional embeddings

**Query capabilities:**
- Text search (BM25)
- Vector search (if embedder provided)
- FastRAG context assembly (expansion + surrogates + snippets)

**Key API:**
```swift
let memoryRAG = try await MemoryOrchestrator(
    at: textStoreURL,
    config: .default,
    embedder: myTextEmbedder  // optional
)

// Ingest text
try await memoryRAG.remember("Meeting notes from today...")

// Ingest PDF
try await memoryRAG.remember(pdfAt: pdfURL, metadata: ["source": "manual"])

// Recall
let context = try await memoryRAG.recall(query: "action items from meeting")
```

## Composing the Three Systems

### Pattern: Unified Multimodal Memory

The recommended composition pattern is a thin coordinator that dispatches queries across all three systems and merges results:

```swift
actor UnifiedMemory {
    private let photos: PhotoRAGOrchestrator
    private let videos: VideoRAGOrchestrator
    private let text: MemoryOrchestrator

    func search(query: String) async throws -> UnifiedResult {
        // Fan out queries in parallel
        async let photoCtx = photos.recall(PhotoQuery(text: query))
        async let videoCtx = videos.recall(VideoQuery(text: query))
        async let textCtx  = text.recall(query: query)

        return UnifiedResult(
            photos: try await photoCtx,
            videos: try await videoCtx,
            text:   try await textCtx
        )
    }
}
```

### Why Separate Stores?

Each orchestrator maintains its own `.mv2s` file for several reasons:

1. **Failure isolation:** A corrupt photo index does not take down text search.
2. **Independent lifecycles:** Photos can be re-synced without affecting video or text stores.
3. **Domain-specific frame kinds:** `photo.root`, `video.segment`, and text chunks use incompatible frame hierarchies that would conflict in a single store.
4. **Embedding spaces:** Photo/video use multimodal embeddings; text may use a text-only embedder with different dimensions.

### Shared Embedder

PhotoRAG and VideoRAG can (and often should) share the same `MultimodalEmbeddingProvider` instance. The embedder is `Sendable` and stateless after initialization:

```swift
// MiniLMEmbeddings conforms to EmbeddingProvider (text-only), NOT
// MultimodalEmbeddingProvider. PhotoRAG and VideoRAG require a
// MultimodalEmbeddingProvider that supports both embed(text:) and
// embed(image:). You must supply your own type that conforms to
// MultimodalEmbeddingProvider.
let embedder: MyMultimodalEmbedder = ...  // host-supplied

let photos = try await PhotoRAGOrchestrator(storeURL: photoURL, embedder: embedder)
let videos = try await VideoRAGOrchestrator(storeURL: videoURL, embedder: embedder)
```

Text-only `MemoryOrchestrator` can use `MiniLMEmbeddings` (or any `EmbeddingProvider`) directly. The `EmbeddingIdentity` stored with each frame ensures that mixed-embedder stores are handled correctly.

## Provider Architecture

All three systems use protocol-driven providers that the host app supplies:

| Provider | Used By | Purpose | Default Available? |
|----------|---------|---------|-------------------|
| `MultimodalEmbeddingProvider` | PhotoRAG, VideoRAG | Text + image embeddings | No (host must supply) |
| `EmbeddingProvider` | MemoryOrchestrator | Text embeddings | No (host must supply) |
| `OCRProvider` | PhotoRAG | Text recognition | Yes (`VisionOCRProvider`) |
| `CaptionProvider` | PhotoRAG | Image captioning | No (host must supply) |
| `VideoTranscriptProvider` | VideoRAG | Audio transcription | No (host must supply) |

All providers enforce `ProviderExecutionMode` (default: `.onDeviceOnly`). Providers that need network access must explicitly declare `.hybrid` or `.cloudOnly` mode, and the orchestrator must have `requireOnDeviceProviders = false`.

## Lifecycle Management

Each orchestrator must be flushed when done. For a composed system:

```swift
func shutdown() async throws {
    // Order does not matter; they are independent
    try await photos.flush()
    try await videos.flush()
    try await text.flush()
}
```

The `flush()` method commits pending writes (staged index entries) to the underlying store. Failing to flush risks losing uncommitted data.

## Metadata Conventions

Each system uses namespaced metadata keys to avoid collisions:

| System | Prefix | Examples |
|--------|--------|----------|
| PhotoRAG | `photo.*` | `photo.location.lat`, `photo.capture_ms`, `photo.camera.make` |
| VideoRAG | `video.*` | `video.segment.start_ms`, `video.duration_ms`, `video.source_id` |
| PDF | `source_*`, `pdf_*` | `source_kind`, `source_uri`, `pdf_page_count` |
| Text | `session_id` | Session tagging for conversation grouping |

If you ever need to query across systems in a single store (not recommended for production), these prefixes prevent key collisions.

## Common Patterns

### Pattern: Ingest-Time Deduplication

Both PhotoRAG and VideoRAG implement supersede-not-delete semantics. Re-ingesting an asset with the same ID supersedes the old root frame. This means:

- You can safely call `ingest()` with overlapping asset sets.
- Old data is not deleted but marked superseded and excluded from results.
- The index grows monotonically; periodic maintenance may be needed for very large libraries.

### Pattern: Capture-Time Queries

All three systems support time-based queries, but they use capture time (when the photo was taken / video was recorded), not ingest time. This enables natural queries like "photos from last Christmas" regardless of when they were indexed.

### Pattern: Graceful Degradation

PhotoRAG and VideoRAG handle iCloud-only assets gracefully:
- Metadata is always indexed (capture time, GPS, camera info).
- Embeddings and OCR/transcripts are skipped for non-local assets.
- Degraded items appear in results but are flagged in diagnostics.

This allows comprehensive library coverage even when not all assets are downloaded.

### Pattern: Budget-Constrained Output

All three systems produce output under strict token budgets:

- **PhotoRAG:** `ContextBudget` controls max text tokens, thumbnails, and region crops.
- **VideoRAG:** `VideoContextBudget` controls max text tokens, thumbnails, and transcript lines per segment.
- **MemoryOrchestrator:** `FastRAGConfig.maxContextTokens` controls total context size with tiered surrogate selection.

This ensures that composed outputs fit within LLM context windows regardless of how many sources contribute.

## Error Handling

The three systems use minimal, domain-specific error types:

| System | Error Type | Key Cases |
|--------|-----------|-----------|
| PhotoRAG | Standard Swift errors | Embedder validation, Photos API errors |
| VideoRAG | `VideoIngestError` | File missing, unsupported platform, invalid video, dimension mismatch |
| PDF | `PDFIngestError` | File not found, load failed, no extractable text |
| Core | `WaxError` | I/O, corruption, capacity, concurrency (14 cases covering all storage failures) |

All errors conform to `LocalizedError` for user-facing messages. When composing, catch domain-specific errors first, then fall through to `WaxError` for storage-level issues.
