# ADR-001: Location Binning Strategy

## Status
Accepted

## Context
PhotoRAG needs to support location-based queries ("photos near Times Square") efficiently. The challenge is finding all photos within a radius of a GPS coordinate without scanning every frame's metadata.

## Decision
GPS coordinates are binned at **0.01-degree resolution** (~1.1km at the equator) using integer truncation:

```swift
LocationBin(latBin: Int(floor(lat * 100.0)), lonBin: Int(floor(lon * 100.0)))
```

At query time, the system:
1. Converts the radius to a lat/lon delta using spherical approximation (`radius / 111_000.0`).
2. Iterates all bins in the bounding box `[minLatBin...maxLatBin] x [minLonBin...maxLonBin]`.
3. Collects all frame IDs in those bins into an allowlist.
4. Passes the allowlist as a `FrameFilter` to the unified search engine.

The bin index (`locationBins: [LocationBin: Set<UInt64>]`) is rebuilt on each `rebuildIndex()` call and includes all searchable photo frame kinds (root, ocr.summary, caption, tags, region).

## Consequences

**Pros:**
- O(1) lookup per bin. Radius queries scan only the relevant bins, not all frames.
- Simple integer keys; no floating-point comparison needed at query time.
- Resolution is coarse enough to keep the bin count manageable (Earth surface = ~65M bins) while fine enough for useful locality (~1km).

**Cons:**
- Longitude bin width varies with latitude (0.01 degrees = ~1.1km at equator, ~0.6km at 60N). Queries near the poles may include more frames than expected.
- No distance filtering within bins; the allowlist includes all frames in the bin regardless of actual distance. This is acceptable because the search engine's scoring will rank closer results higher.
- The index is in-memory only; it is rebuilt from frame metadata on each open/ingest cycle.

## Alternatives Considered

1. **R-tree or spatial index**: More precise but adds complexity and a new index type to the `.mv2s` format. Deferred to v2 if needed.
2. **Higher resolution (0.001 degrees = ~100m)**: More bins, higher memory; diminishing returns for typical photo library sizes.
3. **Geohash strings**: Similar concept but adds string allocation overhead. Integer bins are simpler.
