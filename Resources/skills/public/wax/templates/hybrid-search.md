Template: Hybrid Search (Public Memory Facade)
Goal: Run hybrid search with the public Memory API and a host-supplied embedder.

Placeholders:
- <STORE_URL>
- <QUERY>
- <EMBEDDER_TYPE>
- <TOP_K>
- <TIME_RANGE>

Steps:
1. Open `Memory` with a public `EmbeddingProvider`.
2. Configure `Memory.SearchOptions` with `.hybrid`.
3. Execute `memory.search` and handle `RAGContext` items.

Swift Skeleton:
```swift
import Foundation
import Wax

var config = Memory.Config()
config.enableVectorSearch = true
let memory = try await Memory(at: <STORE_URL>, config: config, embedding: <EMBEDDER_TYPE>())

var options = Memory.SearchOptions()
options.mode = .hybrid
options.topK = <TOP_K>
options.timeRange = <TIME_RANGE>
let context = try await memory.search(<QUERY>, options: options)

_ = context.items
try await memory.close()
```

Package-internal note: raw `SearchRequest` and `WaxSession.search(_:)` are not
external API in the current Wax target.
