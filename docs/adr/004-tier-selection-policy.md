# ADR-004: Tier Selection Policy for Surrogates

## Status
Accepted

## Context
Wax supports hierarchical surrogates (compressed summaries of source frames) at three tiers: `full`, `gist`, and `micro`. At retrieval time, the RAG builder needs to decide which tier to use for each surrogate. Using `full` for everything gives maximum quality but blows the token budget; using `micro` everywhere saves tokens but loses detail.

## Decision
Tier selection is governed by a configurable `TierSelectionPolicy` with three modes:

### 1. `disabled`
Always use `full` tier. Simple, predictable, but no compression benefit.

### 2. `ageOnly(AgeThresholds)`
Select tier based on memory age:
- **Recent** (< `recentDays`, default 7): `full`
- **Mid-age** (between recent and old): `gist`
- **Old** (> `oldDays`, default 30): `micro`

Rationale: Recent memories are more likely to be relevant in detail; older memories need only gist-level context.

### 3. `importance(ImportanceThresholds)`
Combines age and access frequency via `ImportanceScorer`:
- Score >= `fullThreshold` (default 0.6): `full`
- Score >= `gistThreshold` (default 0.3): `gist`
- Below both: `micro`

The importance score is a weighted combination of recency (time decay) and access frequency.

### Query-Aware Boosting
When `enableQueryAwareTierSelection` is true, `QueryAnalyzer` examines the query for signals:
- Temporal queries ("what happened last week") may boost tier for time-relevant frames.
- Named entity queries may boost tier for frames containing those entities.

### Determinism
An optional `deterministicNowMs` timestamp can fix "now" for reproducible tier selection in tests.

## Implementation

```swift
// At retrieval time, for each surrogate:
let context = TierSelectionContext(
    frameTimestamp: frameTimestamp,
    accessStats: nil,  // Future: track access counts
    querySignals: querySignals,
    nowMs: nowMs
)
let tier = tierSelector.selectTier(context: context)
let text = SurrogateTierSelector.extractTier(from: surrogateData, tier: tier)
```

The `SurrogateTierSelector.extractTier(from:tier:)` method parses the surrogate frame content to extract the requested tier level.

## Consequences

**Pros:**
- Configurable: host apps can choose the right tradeoff for their use case.
- Deterministic: same inputs produce same tier selection.
- Extensible: new policies can be added as enum cases without breaking existing ones.

**Cons:**
- Access stats are not yet tracked (always `nil`); importance-based selection currently degrades to age-based.
- Query-aware boosting is heuristic; it may over-promote tiers for ambiguous queries.
- Surrogate content format must support all three tiers; if a surrogate only has `full`, extracting `gist` returns the full text.
