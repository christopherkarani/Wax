# Video RAG

Search video content by transcript and visual segments with semantic queries.

## Overview

``VideoRAGOrchestrator`` provides retrieval-augmented generation for video content. It segments videos into time windows, extracts keyframes, integrates transcripts, and enables natural-language queries that return specific video segments.

## Architecture

Each video is represented as a hierarchy of frames:

| Frame Kind | Content |
|------------|---------|
| `root` | Video metadata (source, duration, capture date) |
| `segment` | Time-windowed segment with transcript and keyframe embedding |

Segments are created with configurable duration and overlap, allowing queries to pinpoint specific moments in long videos.

## Setup

```swift
let orchestrator = try await VideoRAGOrchestrator(
    storeURL: storeURL,
    config: VideoRAGConfig(),
    embedder: embedder,                      // Text/multimodal embedding provider
    transcriptProvider: myTranscriptProvider  // Optional
)
```

### Transcript Provider

The ``VideoTranscriptProvider`` protocol supplies per-video transcripts. Transcripts are segmented and indexed alongside visual embeddings for hybrid text+semantic search.

## Ingestion

### From Local Files

```swift
let files = [
    VideoFile(url: videoURL1),
    VideoFile(url: videoURL2)
]
try await orchestrator.ingest(files: files)
```

### From Photos Library

```swift
try await orchestrator.syncLibrary(scope: .all)
try await orchestrator.ingest(photoAssetIDs: ["video-asset-1"])
```

### Metadata

Each video and segment stores metadata:

| Key | Description |
|-----|-------------|
| `source` | `local` or `photos` |
| `sourceID` | Asset or file identifier |
| `fileURL` | Local file path (if applicable) |
| `captureMs` | Capture timestamp |
| `durationMs` | Total video duration |
| `isLocal` | Whether the video is available locally |
| `pipelineVersion` | Ingestion pipeline version |
| `segmentIndex` | Segment position within the video |
| `segmentCount` | Total segments in the video |
| `segmentStartMs` | Segment start time |
| `segmentEndMs` | Segment end time |
| `segmentMidMs` | Segment midpoint |

## Querying

```swift
let context = try await orchestrator.recall(VideoQuery(
    text: "discussion about architecture decisions",
    topK: 5
))

for segment in context.segments {
    print("Video: \(segment.sourceID)")
    print("Time: \(segment.startMs)ms - \(segment.endMs)ms")
    print("Transcript: \(segment.transcript ?? "")")
}
```

Results are grouped by source video and sorted by relevance within each group.

## Configuration

``VideoRAGConfig`` controls segmentation and search:

| Parameter | Description |
|-----------|-------------|
| `segmentDurationMs` | Duration of each segment in milliseconds |
| `segmentOverlapMs` | Overlap between adjacent segments |
| `transcriptBudget` | Max transcript tokens per segment |
| `keyframeCount` | Keyframes to extract per segment |
| `vectorEnginePreference` | CPU vs GPU vector engine |
| `hybridAlpha` | BM25 vs vector blend |
| `searchTopK` | Candidates to retrieve |
| `requireOnDeviceProviders` | Reject network-dependent providers |

## Segment Chunking

Videos are divided into overlapping time windows:

```
Video: [0s ────────────────────────── 120s]

Segment 1: [0s ──── 30s]
Segment 2:      [25s ──── 55s]     (5s overlap)
Segment 3:           [50s ──── 80s]
Segment 4:                [75s ──── 105s]
Segment 5:                     [100s ── 120s]
```

Each segment gets:
- A keyframe embedding (visual content)
- A transcript slice (if available)
- Metadata with precise start/end timestamps

This overlap ensures that content near segment boundaries is captured by at least two segments.
