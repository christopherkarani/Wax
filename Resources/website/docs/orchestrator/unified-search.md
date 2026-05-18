---
sidebar_position: 3
title: "Unified Search"
sidebar_label: "Unified Search"
---

Understand how Wax fuses BM25, vector, structured-memory, and timeline results.

## Overview

Wax's unified search pipeline is a package-only implementation detail, not public API. Public callers should use orchestrator recall methods such as `MemoryOrchestrator.recall(query:)` and configure behavior through supported orchestrator entry points.

Internally, the pipeline runs multiple retrieval lanes and combines their candidates with reciprocal rank fusion (RRF). This hybrid approach combines exact keyword matches with semantic and temporal recall while keeping the user-facing API focused on memory ingestion and recall.

## Search Lanes

The internal request model can activate up to four lanes:

| Lane | Role | Best For |
|------|------|----------|
| Text (BM25) | FTS-backed keyword retrieval | Exact names, codes, and phrases |
| Vector | Embedding similarity | Paraphrased and semantic queries |
| Structured Memory | Entity and fact evidence | Known relationships and attributed facts |
| Timeline | Reverse chronological fallback | Recent or latest information |

### Text Lane

The text lane runs an FTS5 MATCH query with BM25 scoring. If the primary query returns too few results, a fallback OR-expanded query broadens retrieval.

### Vector Lane

The vector lane compares the query embedding with indexed frame embeddings. It is only active when the orchestrator has vector search enabled and an embedding provider is available.

### Structured Memory Lane

The structured-memory lane resolves entity mentions, finds related facts, and retrieves evidence frames. It is designed to surface frames connected through the knowledge graph.

### Timeline Lane

The timeline lane is a reverse-chronological fallback for queries that imply recency, such as "what happened recently?".

## Reciprocal Rank Fusion

Results from active lanes are merged using RRF:

```
score(d) = sum(weight_lane / (rrfK + rank_lane(d)))
```

Where:

- `rrfK` is a smoothing constant.
- `weight_lane` is the lane weight chosen by the internal classifier.
- `rank_lane(d)` is the document's one-based rank in that lane.

RRF avoids comparing raw scores across heterogeneous engines and naturally rewards documents that appear in more than one lane.

## Query Classification

The package-only classifier adjusts lane weights using simple offline rules:

| Type | Trigger Examples | Weight Bias |
|------|------------------|-------------|
| Factual | "what is", "who is", "define" | Text lane |
| Semantic | "how", "why", "explain" | Vector lane |
| Temporal | "when", "recent", "yesterday" | Timeline lane |
| Exploratory | Default | Balanced lanes |

Classification is fully offline. It does not call network services or external models.

## Public Usage

Use the memory orchestrator for supported recall:

```swift
let context = try await memory.recall(query: "quarterly roadmap")
for item in context.items {
    print(item.text)
}
```

The package-only request, response, filtering, and diagnostics types are intentionally omitted from the public documentation because downstream apps cannot construct or name them directly.
