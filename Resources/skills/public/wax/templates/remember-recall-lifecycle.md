Template: Remember / Recall Lifecycle
Goal: Ingest content, retrieve RAG context, then persist and close.

Placeholders:
- <STORE_URL>
- <EMBEDDER_TYPE>
- <CONTENT>
- <QUERY>
- <METADATA>

Steps:
1. Open MemoryOrchestrator.
2. Optionally start a session.
3. Remember content with metadata.
4. Recall with a query.
5. Flush and close when done.

Swift Skeleton:
```swift
import Foundation
import Wax

let storeURL = <STORE_URL>
let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: .default,
    embedder: <EMBEDDER_TYPE>()
)

let sessionId = await orchestrator.startSession()
_ = sessionId

try await orchestrator.remember(
    <CONTENT>,
    metadata: <METADATA>
)

let context = try await orchestrator.recall(query: <QUERY>)
_ = context.items

await orchestrator.endSession()
try await orchestrator.flush()
try await orchestrator.close()
```
