# ADR-002: Frame Kind Hierarchy

## Status
Accepted

## Context
Wax stores all data as "frames" in a flat array. Different RAG domains (photos, videos, general text) need to store heterogeneous data (embeddings, OCR text, captions, video segments, surrogates) while maintaining queryability and parent-child relationships.

## Decision
Frame kinds follow a **dot-separated hierarchy** that encodes the domain, data type, and specificity:

### Photo RAG
```
photo.root           -- One per PHAsset. Carries global image embedding + all metadata.
photo.ocr.block      -- Individual OCR text block with bounding box. NOT text-indexed.
photo.ocr.summary    -- Concatenated OCR summary (top blocks by confidence). Text-indexed.
photo.caption.short  -- Short caption (host-supplied or weak metadata fallback). Text-indexed.
photo.tags           -- Tag list for the photo. Text-indexed.
photo.region         -- Crop region with its own embedding for spatial matching.
system.photos.sync_state -- Internal sync state marker.
```

### Video RAG
```
video.root           -- One per video. Carries metadata (source, duration, capture time). No embedding.
video.segment        -- One per time window. Carries keyframe embedding + transcript text. Child of root.
```

### General Memory
```
(untyped or custom)  -- General text frames from MemoryOrchestrator.
surrogate            -- Compressed summary of a source frame (full/gist/micro tiers).
```

### Relationships
- Child frames reference their parent via `FrameMetaSubset.parentId`.
- Derived frames (OCR, caption, tags, regions, segments) use `FrameRole.blob`.
- The orchestrator's `rebuildIndex()` scans all frames by kind to build the in-memory index.

## Consequences

**Pros:**
- Dot-separated naming is self-documenting and extensible (e.g., `photo.ocr.handwriting` in the future).
- Search can filter by kind prefix (all `photo.*` kinds) or exact kind.
- Parent-child relationships enable batch operations: deleting a root can cascade to children.

**Cons:**
- Kind strings are not validated at the engine level; typos in kind strings will silently create new categories.
- The hierarchy is a naming convention, not a schema; there is no enforcement of which kinds can be children of which parents.

## Design Rules
1. Domain prefix is required: `photo.`, `video.`, `system.`.
2. Periods separate hierarchy levels: `photo.ocr.block` not `photo_ocr_block`.
3. Root frames have no parent; derived frames always have a `parentId`.
4. Only `photo.ocr.summary`, `photo.caption.short`, and `photo.tags` are text-indexed for search. Raw OCR blocks are stored for audit but not indexed.
