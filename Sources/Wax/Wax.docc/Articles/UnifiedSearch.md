# Unified Search

Fuse text, vector, structured-memory, and timeline signals into ranked context.

## Public Search API

External packages use ``Memory/search(_:options:)`` or
``Memory/search(_:configure:)``:

```swift
var options = Memory.SearchOptions()
options.mode = .textOnly
options.topK = 5
let context = try await memory.search("quarterly roadmap", options: options)

for item in context.items {
    print("\(item.score): \(item.text)")
}
```

For hybrid search, open ``Memory`` with an ``EmbeddingProvider`` and use
``Memory/RetrievalMode/hybrid``:

```swift
var options = Memory.SearchOptions()
options.mode = .hybrid
options.topK = 10
let context = try await semanticMemory.search("standup blockers", options: options)
```

`SearchRequest`, `SearchResponse`, and `WaxSession.search(_:)` are
package-internal implementation details in the main Wax target. They should not
appear in external consumer snippets.

## Search Lanes

The internal search engine can activate up to four lanes:

| Lane | Engine | Best For |
|------|--------|----------|
| Text (BM25) | FTS5 search | Exact keyword matches, names, codes |
| Vector | Vector search | Semantic similarity and paraphrases |
| Structured Memory | Entity/fact queries | Known entities and relationships |
| Timeline | Reverse chronological | Recent and latest queries |

## Reciprocal Rank Fusion

Internal lane results are merged using reciprocal rank fusion:

```text
score(d) = sum(weight_lane / (rrfK + rank_lane(d)))
```

RRF is robust to score scale differences between lanes and naturally handles
documents that appear in multiple lanes.

## Query Classification

The internal classifier adjusts lane weights for factual, semantic, temporal,
and exploratory queries. Classification is offline and does not call a network
service.

## Frame Filtering

The public facade exposes the stable filtering controls that are available to
external packages:

```swift
var options = Memory.SearchOptions()
options.mode = .textOnly
options.topK = 8
options.includeSurrogates = false
options.timeRange = Memory.TimeRange(afterMs: lastWeekMs, beforeMs: nowMs)
let recent = try await memory.search("meeting notes", options: options)
```

Lower-level frame filters, lane diagnostics, and raw rank contributions are
reserved for Wax internals until they are promoted to public API.
