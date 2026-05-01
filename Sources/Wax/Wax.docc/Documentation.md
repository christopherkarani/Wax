# ``Wax``

Persistent, on-device memory for Swift applications.

## Overview

The Wax module exposes a small public facade for application code:

- **``Memory``** - save text into a `.wax` store and retrieve ranked ``RAGContext`` results.
- **``Memory/Config``** and **``Memory/SearchOptions``** - configure text-only or hybrid retrieval without using package-internal session types.
- **``EmbeddingProvider``** - provide your own local embedding model when you want vector search.
- **``RAGContext``** - consume retrieval output with text, scores, sources, and token counts.

Lower-level implementation types such as `MemoryOrchestrator`, `WaxSession`,
`SearchRequest`, and `MiniLMEmbedder` are package-internal in this target. They
are useful when working inside Wax itself, but external packages should build
public examples around ``Memory``.

```swift
import Foundation
import Wax

let storeURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("agent")
    .appendingPathExtension("wax")

var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: storeURL, config: config)

try await memory.save("Met with Alice about the Q4 roadmap")

var options = Memory.SearchOptions()
options.mode = .textOnly
options.topK = 5
let context = try await memory.search("What did Alice say?", options: options)

print(context.items.map(\.text))
try await memory.close()
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Architecture>
- ``Memory``
- ``RAGContext``

### Public Extension Points

- ``EmbeddingProvider``
- ``SearchStrategy``
- ``ResultReranker``

### Package-Internal Architecture

- <doc:MemoryOrchestrator>
- <doc:SessionManagement>
- <doc:UnifiedSearch>
- <doc:RAGPipeline>
- <doc:PhotoRAG>
- <doc:VideoRAG>
