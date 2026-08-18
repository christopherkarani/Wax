---
sidebar_position: 1
title: "Photo RAG"
sidebar_label: "Photo RAG"
---

Use the experimental `PhotoMemory` facade to ingest photos and recall ranked photo context.

## Status

Photo RAG is experimental public API on Darwin (`canImport(ImageIO)`). Application code uses `PhotoMemory` and `BuiltInMultimodalEmbeddings`. For video, use `VideoMemory` with the same embedder factory. `PhotoRAGOrchestrator` is package-only and not public API — do not construct it in app or docs samples.

```swift
let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
let photos = try await PhotoMemory(at: storeURL, embedder: embedder, ocr: VisionOCRProvider())
try await photos.ingest(files: [PhotoFile(id: "receipt-1", url: imageURL)])
let context = try await photos.recall(PhotoQuery(text: "coffee receipt"))
try await photos.close()
```

## Overview

`PhotoMemory` builds retrieval-augmented context over photo libraries. It ingests Photos assets or local images, extracts metadata and OCR text, attaches optional captions and metadata tags, computes multimodal embeddings, and prepares ranked photo context for natural-language queries.

## Architecture

Each photo is represented as a hierarchy of frames:

| Frame Kind | Content |
|------------|---------|
| `root` | Photo metadata (asset ID, capture date, camera, GPS) |
| `ocrBlock` | Individual OCR text blocks |
| `ocrSummary` | Concatenated OCR text for the full image |
| `captionShort` | Short image caption |
| `tags` | Metadata keywords, or caption-derived search terms when no keywords are present |
| `region` | Bounding box regions of interest |
| `syncState` | Library sync checkpoint |

## Components

| Component | Role |
|-----------|------|
| `PhotoMemory` | Experimental public facade for photo sync, ingestion, indexing, recall, deletion, and flush |
| `BuiltInMultimodalEmbeddings` | Public factory for the on-device multimodal embedder |
| `MultimodalEmbeddingProvider` | Public provider requirement for image and text embeddings |
| `PhotoRAGConfig` | Configuration for pixel sizes, OCR, regions, vector search, and context budgets |
| `VisionOCRProvider` | Default on-device OCR provider |
| `OCRProvider` | Provider protocol for image text extraction |
| `CaptionProvider` | Provider protocol for generated image descriptions |
| `PhotoQuery` | Query model for text, metadata, location, and evidence constraints |
| `PhotoRAGContext` | Recall result grouped into photo items and evidence |
| `PhotoRAGOrchestrator` | Package-only engine behind `PhotoMemory`; not public API |

## Ingestion

The ingestion path currently supports:

- Photos-library sync for full-library or selected-asset scopes
- Local image ingestion when the package is compiled with ImageIO support
- Optional OCR, captions, metadata tags, and region evidence
- On-device provider enforcement when configured

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

## Recall Behavior

The recall flow:
1. Embeds the query text
2. Searches across OCR text (BM25) and image embeddings (vector similarity)
3. Fuses results with RRF
4. Returns ranked photos with surrogates and pixel payloads

## Configuration

`PhotoRAGConfig` controls ingestion and search:

| Parameter | Description |
|-----------|-------------|
| `thumbnailSize` | Pixel size for thumbnail extraction |
| `fullSize` | Pixel size for full-resolution extraction |
| `enableOCR` | Whether to run OCR on ingested photos |
| `enableRegions` | Whether to extract bounding box regions |
| `ingestConcurrency` | Parallel ingestion tasks |
| `hybridAlpha` | BM25 vs vector blend (0 = vector, 1 = text) |
| `searchTopK` | Candidates to retrieve |
| `requireOnDeviceProviders` | Reject network-dependent providers |
