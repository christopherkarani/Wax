# Memory Orchestrator

Understand the package-internal text RAG orchestrator used by the public
``Memory`` facade.

## Public Entry Point

External packages should use ``Memory`` for text memory:

```swift
import Foundation
import Wax

let storeURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("memory")
    .appendingPathExtension("wax")

var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: storeURL, config: config)

try await memory.save("Project timeline moved to Friday.")

var options = Memory.SearchOptions()
options.mode = .textOnly
options.topK = 5
let context = try await memory.search("When is the project timeline?", options: options)

_ = context.items
try await memory.close()
```

`MemoryOrchestrator` itself is package-internal. Do not use it in public docs,
skills, or downstream package snippets unless the snippet is explicitly for
editing Wax internals.

## Internal Role

Inside Wax, `MemoryOrchestrator` coordinates chunking, embedding, indexing,
search, and RAG context assembly into a single actor. The public ``Memory``
facade delegates to it.

## Ingestion Pipeline

When ``Memory/save(_:metadata:)`` is called, the internal orchestrator:

1. Chunks the text using the configured strategy.
2. Embeds chunks when an ``EmbeddingProvider`` is available.
3. Writes each chunk as a frame to the `.wax` file.
4. Indexes chunk text in the full-text search engine.
5. Adds embeddings to the vector search engine when vector search is enabled.
6. Commits changes atomically.

## Recall

``Memory/search(_:options:)`` returns a ``RAGContext`` assembled within the
configured token budget:

```swift
var options = Memory.SearchOptions()
options.mode = .textOnly
options.topK = 3
let context = try await memory.search("project timeline", options: options)
```

Use a custom ``EmbeddingProvider`` and `.hybrid` search mode when you need the
vector lane:

```swift
var options = Memory.SearchOptions()
options.mode = .hybrid
options.topK = 8
let context = try await semanticMemory.search("roadmap dependencies", options: options)
```

## Package-Internal Features

These implementation details exist inside Wax but are not external Swift API:

| Internal Type | Purpose |
|---------------|---------|
| `MemoryOrchestrator` | Text ingestion, recall, session tagging, handoff storage |
| `OrchestratorConfig` | Internal orchestration configuration |
| `QueryEmbeddingPolicy` | Internal query embedding policy |
| `MemorySearchHit` | Internal raw hit shape before public ``RAGContext`` assembly |

For public code, use ``Memory/Config`` and ``Memory/SearchOptions`` instead.
