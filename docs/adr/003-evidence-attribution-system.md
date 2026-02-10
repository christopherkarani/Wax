# ADR-003: Evidence Attribution System

## Status
Accepted

## Context
When a RAG system returns results, the host app and downstream models benefit from knowing *why* each result was included. Was it a text match? Vector similarity? Temporal proximity? Region crop? This attribution enables explainability, debugging, and UI features (e.g., highlighting matched text, showing the relevant region).

## Decision
Each recall item carries an **evidence array** tracing which search lane(s) contributed to its inclusion.

### PhotoRAG Evidence
```swift
public enum Evidence: Sendable, Equatable {
    case vector           // Global image embedding matched
    case text(snippet: String?)  // BM25/FTS5 text match (OCR, caption, tags)
    case region(bbox: PhotoNormalizedRect)  // Region crop embedding matched
    case timeline         // Included via temporal proximity (timeline fallback)
}
```

### VideoRAG Evidence
```swift
public enum Evidence: Sendable, Equatable {
    case vector           // Keyframe embedding matched
    case text(snippet: String?)  // Transcript text matched via BM25
    case timeline         // Included via temporal proximity
}
```

### How Evidence is Determined
1. The unified search engine tags each result with `sources: [SearchResponse.Source]` (`.text`, `.vector`, `.timeline`, `.structuredMemory`).
2. The orchestrator's `evidence()` helper maps these sources to domain-specific evidence types.
3. For PhotoRAG, region matches are detected by checking if the result's frame kind is `photo.region` and extracting the bbox from metadata.
4. Evidence is accumulated per root candidate (multiple search hits for the same photo/video are merged).

### Evidence in `recall()` Flow
```
SearchResponse.Result.sources  -->  PhotoRAGItem.Evidence / VideoSegmentHit.Evidence
        ^                                    ^
        |                                    |
  Unified search tags                 Orchestrator maps
  (text, vector, timeline)            to domain types
```

## Consequences

**Pros:**
- Full transparency: every result explains how it was found.
- Enables UI features like text highlighting, region boxing, timeline visualization.
- Useful for retrieval quality debugging and evaluation.

**Cons:**
- Evidence is approximate: a frame may match multiple lanes but only the highest-priority evidence is recorded first (vector > text > timeline in PhotoRAG).
- Region evidence requires bbox metadata parsing; if metadata is missing, the region match is silently dropped.
- Evidence array is append-only during candidate merging; deduplication checks (`!entry.evidence.contains(ev)`) add minor overhead.
