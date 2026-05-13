# Photo RAG

Understand the package-only Photo RAG pipeline for contributor work.

## Status

Photo RAG is an experimental, package-only implementation. The current `PhotoRAGOrchestrator` actor and related photo types use Swift `package` access, so they are not public API for application or downstream package consumers.

Use this article as internal implementation documentation for Wax contributors. Public integration docs should wait for a stable public facade or an explicit access-level change.

## Overview

The package-scoped pipeline builds retrieval-augmented context over photo libraries. It ingests Photos assets or local images, extracts metadata and OCR text, attaches optional captions and tags, computes multimodal embeddings, and prepares ranked photo context for natural-language queries.

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

## Internal Components

| Component | Role |
|-----------|------|
| `PhotoRAGOrchestrator` | Package-scoped actor that owns photo sync, ingestion, indexing, recall, deletion, and flush flows |
| `PhotoRAGConfig` | Package-scoped configuration for pixel sizes, OCR, regions, vector search, and context budgets |
| `MultimodalEmbeddingProvider` | Package-scoped provider requirement for image and text embeddings |
| `OCRProvider` | Package-scoped provider for image text extraction |
| `CaptionProvider` | Package-scoped provider for generated image descriptions |
| `PhotoQuery` | Package-scoped query model for text, metadata, location, and evidence constraints |
| `PhotoRAGContext` | Package-scoped recall result grouped into photo items and evidence |

## Ingestion

The package-only ingestion path currently supports:

- Photos-library sync for full-library or selected-asset scopes
- Local image ingestion when the package is compiled with ImageIO support
- Optional OCR, captions, tags, and region evidence
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

The package-only recall flow:
1. Embeds the query text
2. Searches across OCR text (BM25) and image embeddings (vector similarity)
3. Fuses results with RRF
4. Returns ranked photos with surrogates and pixel payloads

## Configuration

``PhotoRAGConfig`` controls internal ingestion and search:

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
