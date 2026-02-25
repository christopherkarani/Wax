# Photo RAG

Build a semantic search layer over photo libraries with OCR, captions, and CLIP embeddings.

## Overview

``PhotoRAGOrchestrator`` provides retrieval-augmented generation for photo libraries. It ingests photos from the Photos framework or local files, extracts text (OCR), generates captions, computes embeddings, and enables natural-language queries over the photo collection.

## Architecture

Each photo is represented as a hierarchy of frames:

| Frame Kind | Content |
|------------|---------|
| `root` | Photo metadata (asset ID, capture date, camera, GPS) |
| `ocrBlock` | Individual OCR text blocks |
| `ocrSummary` | Concatenated OCR text for the full image |
| `captionShort` | Short image caption |
| `tags` | Detected tags/labels |
| `region` | Bounding box regions of interest |
| `syncState` | Library sync checkpoint |

## Setup

```swift
let orchestrator = try await PhotoRAGOrchestrator(
    storeURL: storeURL,
    config: PhotoRAGConfig(),
    embedder: clipEmbedder,       // Multimodal embedding provider
    ocr: myOCRProvider,           // Optional OCR provider
    captioner: myCaptionProvider  // Optional caption provider
)
```

### Providers

- **Embedder** — Any `EmbeddingProvider` that works with image descriptions (e.g., CLIP-based)
- **OCR** — Extracts text from images (optional)
- **Captioner** — Generates natural-language descriptions of images (optional)

## Ingestion

### From Photos Framework

Sync and ingest from the user's photo library:

```swift
// Sync library metadata
try await orchestrator.syncLibrary(scope: .all)

// Ingest specific assets
try await orchestrator.ingest(assetIDs: ["asset-id-1", "asset-id-2"])
```

### Metadata

Each ingested photo stores rich metadata:

| Key | Description |
|-----|-------------|
| `assetID` | Photos library asset identifier |
| `captureMs` | Capture timestamp in milliseconds |
| `isLocal` | Whether the asset is available locally |
| `lat`, `lon` | GPS coordinates |
| `gpsAccuracyM` | GPS accuracy in meters |
| `cameraMake`, `cameraModel` | Camera hardware |
| `lensModel` | Lens identification |
| `width`, `height` | Image dimensions |
| `orientation` | EXIF orientation |
| `pipelineVersion` | Ingestion pipeline version |

## Querying

```swift
let context = try await orchestrator.recall(PhotoQuery(
    text: "photos with handwritten notes",
    topK: 10
))

for item in context.items {
    print("Asset: \(item.assetID), Score: \(item.score)")
    print("OCR text: \(item.ocrText ?? "none")")
}
```

The query pipeline:
1. Embeds the query text
2. Searches across OCR text (BM25) and image embeddings (vector similarity)
3. Fuses results with RRF
4. Returns ranked photos with surrogates and pixel payloads

## Configuration

``PhotoRAGConfig`` controls ingestion and search:

| Parameter | Description |
|-----------|-------------|
| `thumbnailSize` | Pixel size for thumbnail extraction |
| `fullSize` | Pixel size for full-resolution extraction |
| `enableOCR` | Whether to run OCR on ingested photos |
| `enableRegions` | Whether to extract bounding box regions |
| `ingestConcurrency` | Parallel ingestion tasks |
| `vectorEnginePreference` | CPU vs GPU vector engine |
| `hybridAlpha` | BM25 vs vector blend (0 = vector, 1 = text) |
| `searchTopK` | Candidates to retrieve |
| `requireOnDeviceProviders` | Reject network-dependent providers |
