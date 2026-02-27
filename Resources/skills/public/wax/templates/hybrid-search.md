Template: Hybrid Search (Wax + SearchRequest)
Goal: Run unified hybrid search with text + vector signals.

Placeholders:
- <STORE_URL>
- <QUERY>
- <EMBEDDING>
- <ALPHA>
- <TOP_K>
- <MIN_SCORE>
- <TIME_RANGE>

Steps:
1. Open Wax and a session with vector search enabled.
2. Build a SearchRequest with `.hybrid(alpha:)` and an embedding.
3. Execute `session.search` and handle results.

Swift Skeleton:
```swift
import Foundation
import Wax

let wax = try await Wax.open(at: <STORE_URL>)
let session = try await wax.openSession(
    .readOnly,
    config: .init(
        enableTextSearch: true,
        enableVectorSearch: true,
        enableStructuredMemory: false,
        vectorEnginePreference: .auto,
        vectorMetric: .cosine,
        vectorDimensions: <EMBEDDING>.count
    )
)

let request = SearchRequest(
    query: <QUERY>,
    embedding: <EMBEDDING>,
    vectorEnginePreference: .auto,
    mode: .hybrid(alpha: <ALPHA>),
    topK: <TOP_K>,
    minScore: <MIN_SCORE>,
    timeRange: <TIME_RANGE>
)

let response = try await session.search(request)
_ = response.results
```
