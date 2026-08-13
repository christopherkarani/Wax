# RAG Pipeline

Understand the token-budget-aware context assembly with surrogate tiers and intent-aware reranking.

## Status

`FastRAGContextBuilder` and `FastRAGConfig` are package-only implementation details, not public API. Application code assembles context through ``Memory/search(_:options:)``, which runs this pipeline internally and returns a public ``RAGContext``. Use the rest of this article as internal implementation documentation for Wax contributors.

## Public configuration

Tune the live pipeline through ``Memory/RAGConfig`` on ``Memory/Config-swift.struct/rag``. Out-of-range values are clamped once while mapping into the package builder; they do not throw ``WaxError/invalidConfiguration(reason:)``.

Keyword/entity enrichment is ``Memory/EnrichmentPolicy`` (`.disabled` by default, or `.builtIn`). ``Memory/Stats-swift.struct/enrichment`` reports `processedCount`, `pendingCount`, and `isRunning` when enrichment is enabled.

```swift compile
import Foundation
import Wax

func ragPublicConfig() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    var config = Memory.Config.default
    config.enableVectorSearch = false
    config.rag.maxContextTokens = 1_500
    config.rag.searchTopK = 24
    config.rag.answerRerankWindow = 12
    config.rag.answerDistractorPenalty = 0.30
    config.enrichment = .builtIn
    let memory = try await Memory(at: storeURL, config: config)
    try await memory.save("Swift actors isolate mutable state.")
    let results = try await memory.search("actors", options: .init(mode: .textOnly))
    _ = results.totalTokens
    let stats = await memory.stats()
    _ = stats.enrichment?.processedCount
    _ = stats.enrichment?.pendingCount
    _ = stats.enrichment?.isRunning
    try await memory.close()
}
```

``Memory/SearchOptions/topK`` truncates the returned item list. Candidate depth for assembly is ``Memory/RAGConfig/searchTopK`` (default 24).

## Overview

The `FastRAGContextBuilder` assembles a ``RAGContext`` from search results within a configurable token budget. It uses a multi-stage pipeline: unified search, intent-aware reranking, expansion, surrogates, and snippets.

## Pipeline Stages

### 1. Unified Search

The builder issues a ``SearchRequest`` that runs across multiple search lanes simultaneously (see <doc:UnifiedSearch>). Results are fused using reciprocal rank fusion (RRF).

### 2. Answer-Focused Reranking

When `enableAnswerFocusedRanking` is true (default), the top candidates are reranked within a configurable window (`answerRerankWindow`, default 12).

Reranking factors:

| Factor | Weight | Description |
|--------|--------|-------------|
| Term recall | 0.80 | Fraction of query terms found in the result |
| Term precision | 0.40 | Fraction of result terms that match the query |
| Entity coverage | 0.90-1.25 | Named entity overlap (boosted when vector-influenced) |
| Year match | 1.35 | Results containing years mentioned in the query |
| Date literal match | 1.15 | Results containing specific dates from the query |

### Intent Detection

The ``QueryAnalyzer`` detects query intent patterns that influence scoring:

| Intent | Pattern Examples | Effect |
|--------|-----------------|--------|
| Location | "where", "location", "address" | Boosts results with location data |
| Date | "when", "what date", "what time" | Boosts results with temporal content |
| Ownership | "whose", "who owns", "belong to" | Boosts results with ownership assertions |
| Multi-hop | Multiple entity references | Enables broader search |

### Distractor Penalties

Results matching distractor patterns receive a configurable penalty (`answerDistractorPenalty`, default 0.30):

- Tentative language ("tentative", "no authoritative")
- Checklists and reports ("weekly report", "checklist", "signoff")
- Draft content ("draft memo", "placeholder")

### 3. Token Budget Assembly

The builder allocates the total token budget across three tiers:

```
┌─────────────────────────────────┐
│  maxContextTokens (default 1500)│
│                                 │
│  ┌───────────────────────────┐  │
│  │ Expansion (up to 600 tok) │  │  First result, expanded
│  ├───────────────────────────┤  │
│  │ Surrogates (60 tok each)  │  │  Tier-selected summaries
│  ├───────────────────────────┤  │
│  │ Snippets (200 tok each)   │  │  Remaining results
│  └───────────────────────────┘  │
└─────────────────────────────────┘
```

#### Expansion

The top-ranked result is expanded to its full frame content, capped at `expansionMaxTokens` (default 600) and `expansionMaxBytes`.

#### Surrogates (denseCached mode only)

In `denseCached` mode, additional context is added as tier-selected surrogates. Each surrogate is a compressed representation of a frame, selected by age or importance:

| Tier | Content | Max Tokens |
|------|---------|------------|
| `full` | Complete frame text | `surrogateMaxTokens` (60) |
| `gist` | Summary/gist | `surrogateMaxTokens` (60) |
| `micro` | Key phrases only | `surrogateMaxTokens` (60) |

#### Snippets

Remaining budget is filled with preview-based snippets from additional search results, each capped at `snippetMaxTokens` (200).

For certain query intents (location, date, ownership), snippets may be expanded to their full frame content if the preview appears to contain the answer.

## Configuration

`FastRAGConfig` (package-only) controls all pipeline parameters:

```swift compile-package
import Wax

func packageFastRAGConfig() {
    var config = FastRAGConfig()

    // Mode
    config.mode = .fast  // .fast or .denseCached

    // Token budgets
    config.maxContextTokens = 2000
    config.expansionMaxTokens = 800
    config.snippetMaxTokens = 300
    config.surrogateMaxTokens = 80
    config.maxSnippets = 5
    config.maxSurrogates = 10

    // Search
    config.searchTopK = 32
    config.searchMode = .hybrid(alpha: 0.5)
    config.rrfK = 60

    // Reranking
    config.enableAnswerFocusedRanking = true
    config.answerRerankWindow = 12
    config.answerDistractorPenalty = 0.30
}
```

## Surrogate Tier Selection

The ``SurrogateTierSelector`` chooses which tier to use for each surrogate based on configurable policies:

| Policy | Strategy |
|--------|----------|
| `.disabled` | Always use `full` tier |
| `.ageOnly(thresholds)` | Recent (< 7 days) = full, old (< 30 days) = gist, older = micro |
| `.importance(thresholds)` | Based on access frequency: > 0.6 = full, > 0.3 = gist, else micro |

When `enableQueryAwareTierSelection` is true, the tier can be boosted based on query specificity (quoted phrases, named entities).

## Output

The pipeline returns a ``RAGContext``:

```swift
public struct RAGContext {
    public var query: String
    public var items: [Item]
    public var totalTokens: Int
    public var diagnostics: Diagnostics?  // requested vs. effective retrieval mode
}
```

Each item has a `kind` (`.snippet`, `.expanded`, or `.surrogate`), the source `frameId`, a relevance `score`, and the assembled `text`. ``RAGContext/diagnostics`` reports the requested mode, the effective mode (which degrades to `text` when the vector lane is unavailable), and the query-embedding state.
