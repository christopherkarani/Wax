Template: Save / Search Lifecycle
Goal: Ingest content, retrieve context, then persist and close.

Placeholders:
- <STORE_URL>
- <CONTENT>
- <QUERY>
- <METADATA>

Steps:
1. Open Memory (default auto MiniLM on supported OS).
2. Save content with metadata.
3. Search with a query; inspect diagnostics.
4. Flush and close when done.

Swift Skeleton:
```swift
import Foundation
import Wax

let storeURL = <STORE_URL>
let memory = try await Memory(at: storeURL)

try await memory.save(
    <CONTENT>,
    metadata: <METADATA>
)

let results = try await memory.search(<QUERY>)
_ = results.items
_ = results.diagnostics  // requested vs. effective retrieval mode

try await memory.flush()
try await memory.close()
```
