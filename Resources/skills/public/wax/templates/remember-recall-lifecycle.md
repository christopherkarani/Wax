Template: Save / Search Lifecycle
Goal: Ingest content, retrieve RAG context, then close the public Memory handle.

Placeholders:
- <STORE_URL>
- <CONTENT>
- <QUERY>
- <METADATA>
- <TOP_K>

Steps:
1. Open `Memory`.
2. Save content with optional metadata.
3. Search with a query.
4. Close when done.

Swift Skeleton:
```swift
import Foundation
import Wax

var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: <STORE_URL>, config: config)

try await memory.save(<CONTENT>, metadata: <METADATA>)

var options = Memory.SearchOptions()
options.mode = .textOnly
options.topK = <TOP_K>
let context = try await memory.search(<QUERY>, options: options)
_ = context.items

try await memory.close()
```

MCP note: coding-agent sessions use `session_start`, `remember`, `recall`,
`handoff`, and `session_end`; those are broker tools, not Swift `Memory` APIs.
