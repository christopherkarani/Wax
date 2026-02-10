# ADR-005: Metadata-Only Degradation for iCloud Assets

## Status
Accepted

## Context
Both PhotoRAG and VideoRAG are designed to be fully offline. When a Photos library asset exists only in iCloud (not downloaded locally), Wax cannot access the pixel data for embedding or OCR. The question is: should these assets be skipped entirely, or indexed with whatever metadata is available?

## Decision
iCloud-only assets are indexed as **metadata-only** frames and marked as degraded.

### PhotoRAG Behavior
1. `PHImageRequestOptions.isNetworkAccessAllowed = false` -- Wax never triggers iCloud downloads.
2. If `requestImageDataAndOrientation` returns no data (or `PHImageResultIsInCloudKey` is true), the asset is marked non-local.
3. A root frame is written with metadata (asset ID, capture time, location, EXIF) but:
   - No image embedding (no vector search for this photo).
   - No OCR blocks or summary.
   - No caption.
   - No region embeddings.
4. The `isLocal` metadata key is set to `"false"`.
5. These frames participate in timeline queries and metadata-based text search but not vector similarity.

### VideoRAG Behavior
1. `PHVideoRequestOptions.isNetworkAccessAllowed = false`.
2. If the video AVAsset is unavailable, a root frame is written with metadata only.
3. No segments are created (no keyframes, no transcript indexing).
4. The `isLocal` metadata key is set to `"false"`.

### Degradation Reporting
Both `PhotoRAGContext.Diagnostics` and `VideoRAGContext.Diagnostics` report `degradedResultCount` / `degradedVideoCount`. The host app can use this to:
- Show a UI hint ("Some results may be incomplete -- download from iCloud for full search").
- Prioritize iCloud downloads for frequently queried assets.

### Degradation Detection
```swift
// PhotoRAG
private func isDegraded(assetID: String) -> Bool {
    guard let rootId = index.rootByAssetID[assetID] else { return true }
    let refs = index.derivedByRoot[rootId]
    return refs?.ocrSummary == nil && refs?.caption == nil
}

// VideoRAG
private func isDegraded(videoID: VideoID) -> Bool {
    guard let rootMeta = index.rootMetaByVideoID[videoID],
          let entries = rootMeta.metadata?.entries
    else { return true }
    return entries[MetaKey.isLocal] != "true"
}
```

## Consequences

**Pros:**
- Users see all their photos/videos in search results, even if some are iCloud-only.
- Metadata-only frames still participate in timeline and location queries.
- No network calls ever -- Wax remains fully offline.
- When the asset later becomes local (user downloads it), re-ingesting upgrades the frame via supersede.

**Cons:**
- Degraded results may confuse users who expect all results to have full context.
- The degradation heuristic (no OCR + no caption = degraded) may false-positive for legitimately blank photos.
- Re-ingest after iCloud download requires the host app to detect and trigger the update.

## Alternatives Considered

1. **Skip iCloud-only assets entirely**: Simpler but the photo disappears from search. Bad UX for users with large iCloud libraries.
2. **Queue for later download**: Violates the "no network" principle. The host app can implement this externally.
3. **Store a placeholder embedding**: Would pollute the vector index with meaningless vectors. Rejected.
