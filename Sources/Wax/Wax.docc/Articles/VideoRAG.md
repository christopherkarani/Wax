# Video RAG

Understand the package-only Video RAG pipeline for contributor work.

## Status

Video RAG is an experimental, package-only implementation. The current `VideoRAGOrchestrator` actor and related video types use Swift `package` access, so they are not public API for application or downstream package consumers.

Use this article as internal implementation documentation for Wax contributors. Public integration docs should wait for a stable public facade or an explicit access-level change.

## Overview

The package-scoped pipeline indexes video content by transcript and visual segments. It segments videos into time windows, extracts keyframes, attaches optional host-supplied transcripts, and builds retrieval context for natural-language queries over specific video ranges.

## Architecture

Each video is represented as a hierarchy of frames:

| Frame Kind | Content |
|------------|---------|
| `root` | Video metadata (source, duration, capture date) |
| `segment` | Time-windowed segment with transcript and keyframe embedding |

Segments are created with configurable duration and overlap, allowing searches to identify specific moments in long videos.

## Internal Components

| Component | Role |
|-----------|------|
| `VideoRAGOrchestrator` | Package-scoped actor that owns ingestion, indexing, recall, deletion, and flush flows |
| `VideoRAGConfig` | Package-scoped configuration for segmentation, embedding, vector search, and context budgets |
| `VideoTranscriptProvider` | Package-scoped protocol for host-supplied transcript chunks |
| `VideoFile` | Package-scoped local-file descriptor used by ingestion |
| `VideoQuery` | Package-scoped query model for text, time, video ID, and context constraints |
| `VideoRAGContext` | Package-scoped recall result grouped into video items and segment hits |

## Ingestion Behavior

The package-only ingestion path currently supports:

- Local files, deduplicated by normalized file URL and optional caller-provided ID
- Photos-library videos when Photos is available, with iCloud-only assets treated as degraded metadata-only entries
- Optional transcript chunks supplied by a package-scoped transcript provider
- Segment keyframe embeddings from an on-device multimodal embedding provider

## Metadata

Each video and segment stores metadata:

| Key | Description |
|-----|-------------|
| `source` | `local` or `photos` |
| `sourceID` | Asset or file identifier |
| `fileURL` | Local file path, when applicable |
| `captureMs` | Capture timestamp |
| `durationMs` | Total video duration |
| `isLocal` | Whether the video is available locally |
| `pipelineVersion` | Ingestion pipeline version |
| `segmentIndex` | Segment position within the video |
| `segmentCount` | Total segments in the video |
| `segmentStartMs` | Segment start time |
| `segmentEndMs` | Segment end time |
| `segmentMidMs` | Segment midpoint |

## Recall Behavior

The package-only recall flow combines vector and text retrieval when both query text and embeddings are available. It can also fall back to timeline-constrained segment lookup for constraint-only queries.

Results are grouped by source video and sorted by relevance within each group. Segment hits can include vector evidence, text snippets, timeline evidence, transcript snippets, and optional thumbnails when configured.

## Configuration

`VideoRAGConfig` controls internal segmentation and search:

| Parameter | Description |
|-----------|-------------|
| `segmentDurationSeconds` | Duration of each segment |
| `segmentOverlapSeconds` | Overlap between adjacent segments |
| `maxSegmentsPerVideo` | Segment cap for long videos |
| `segmentWriteBatchSize` | Write batching for segment ingestion |
| `embedMaxPixelSize` | Keyframe resize bound before embedding |
| `maxTranscriptBytesPerSegment` | Transcript budget per segment |
| `searchTopK` | Candidates to retrieve |
| `hybridAlpha` | BM25/vector blend |
| `timelineFallbackLimit` | Constraint-only fallback limit |
| `requireOnDeviceProviders` | Reject network-dependent providers |
| `includeThumbnailsInContext` | Include thumbnails in recall context |
| `thumbnailMaxPixelSize` | Thumbnail resize bound |
| `queryEmbeddingCacheCapacity` | Query embedding cache size |

## Segment Chunking

Videos are divided into overlapping time windows:

```
Video: [0s -------------------------- 120s]

Segment 1: [0s ---- 30s]
Segment 2:      [25s ---- 55s]     (5s overlap)
Segment 3:           [50s ---- 80s]
Segment 4:                [75s ---- 105s]
Segment 5:                     [100s -- 120s]
```

Each segment gets:

- A keyframe embedding for visual content
- A transcript slice, when available
- Metadata with precise start/end timestamps

This overlap ensures that content near segment boundaries is captured by at least two segments.
