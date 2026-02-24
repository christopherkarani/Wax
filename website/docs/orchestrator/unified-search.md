---
sidebar_position: 3
title: "Unified Search"
sidebar_label: "Unified Search"
---

Fuse BM25, vector, structured memory, and timeline results with reciprocal rank fusion.

## Overview

Wax's unified search runs multiple search strategies in parallel and fuses their results using reciprocal rank fusion (RRF). This hybrid approach combines the precision of keyword search with the recall of semantic search.

## Search Lanes

Each search request can activate up to four lanes:

| Lane | Engine | Best For |
|------|--------|----------|
| **Text (BM25)** | `FTS5SearchEngine` | Exact keyword matches, names, codes |
| **Vector** | `VectorSearchEngine` | Semantic similarity, paraphrased queries |
| **Structured Memory** | Entity/fact queries | Known entities and relationships |
| **Timeline** | Reverse chronological | "Recent" and "latest" queries |

### Text Lane

Runs an FTS5 MATCH query with BM25 scoring. If the primary query returns insufficient results, a fallback OR-expanded query broadens the search.

### Vector Lane

Computes the cosine similarity between the query embedding and all indexed frame embeddings. Requires an `EmbeddingProvider` to be configured.

### Structured Memory Lane

Resolves entity mentions in the query, finds related facts, and retrieves evidence frames. This lane surfaces frames that are semantically connected through the knowledge graph.

### Timeline Lane

A reverse-chronological fallback activated for queries that imply recency (e.g., "what happened recently?"). This ensures temporal queries return results even when keyword/vector matches are sparse.

## Reciprocal Rank Fusion (RRF)

Results from all active lanes are merged using RRF:

```
score(d) = Σ (weight_lane / (rrfK + rank_lane(d)))
```

Where:
- `rrfK` is a smoothing constant (default 60)
- `weight_lane` is the per-lane weight from the adaptive fusion config
- `rank_lane(d)` is the document's rank in that lane (1-based)

RRF is robust to score scale differences between lanes and naturally handles documents that appear in multiple lanes.

## Query Classification

The `RuleBasedQueryClassifier` categorizes queries to adjust fusion weights:

| Type | Triggers | Weight Adjustment |
|------|----------|-------------------|
| Factual | "what is", "who is", "define" | Higher BM25 weight |
| Semantic | "how", "why", "explain" | Higher vector weight |
| Temporal | "when", "recent", "yesterday" | Include timeline lane |
| Exploratory | Default | Balanced weights |

Classification is fully offline -- no ML models or network calls required.

## Search Request

Configure searches with `SearchRequest`:

```swift
let request = SearchRequest(
    query: "quarterly roadmap",
    embedding: queryEmbedding,     // Optional
    mode: .hybrid(alpha: 0.5),     // 0 = vector only, 1 = text only
    topK: 20,
    rrfK: 60
)

let response = try await session.search(request)
```

### Search Modes

`SearchMode` controls which lanes are active:

| Mode | Active Lanes |
|------|-------------|
| `.textOnly` | BM25 only |
| `.vectorOnly` | Vector only |
| `.hybrid(alpha: Float)` | Both BM25 and vector, blended by alpha |

### Frame Filtering

Restrict results with metadata predicates:

```swift
var filter = FrameFilter()
filter.requiredTags = ["meetings"]
filter.requiredLabels = ["important"]
filter.timeRange = TimeRange(after: lastWeekMs, before: nowMs)
filter.includeDeleted = false
filter.includeSuperseded = false

let request = SearchRequest(
    query: "standup notes",
    frameFilter: filter
)
```

### Structured Memory Options

Fine-tune the structured memory lane:

```swift
var smOptions = StructuredMemorySearchOptions()
smOptions.weight = 1.0
smOptions.maxEntityCandidates = 5
smOptions.maxFacts = 20
smOptions.maxEvidenceFrames = 10
smOptions.requireEvidenceSpan = false
```

## Search Response

`SearchResponse` contains ranked results with source attribution:

```swift
for result in response.results {
    print("Frame \(result.frameId): \(result.score)")
    print("Sources: \(result.sources)")  // [.text, .vector, ...]
    print("Preview: \(result.previewText ?? "")")
}
```

Each result reports which lanes contributed via the `sources` array:
- `.text` -- Matched in BM25 lane
- `.vector` -- Matched in vector lane
- `.timeline` -- From timeline fallback
- `.structuredMemory` -- Surfaced via knowledge graph

### Ranking Diagnostics

Enable diagnostics for debugging:

```swift
var request = SearchRequest(query: "test")
request.enableRankingDiagnostics = true
request.rankingDiagnosticsTopK = 5

let response = try await session.search(request)
for result in response.results {
    if let diag = result.rankingDiagnostics {
        print("Best lane rank: \(diag.bestLaneRank)")
        print("Contributions: \(diag.laneContributions)")
    }
}
```
