Template: Video RAG (Package-Internal)
Goal: Orient Wax contributors working on the internal Video RAG implementation.

Status:
`VideoRAGOrchestrator`, `VideoRAGConfig`, `VideoTranscriptProvider`,
`VideoFile`, and `VideoQuery` are package-internal in the current Wax target.
Do not use this template for external package snippets.

Public alternative:
```swift
import Foundation
import Wax

var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: <STORE_URL>, config: config)

try await memory.save(
    "Video transcript note: <TEXT>",
    metadata: ["source": "video-transcript"]
)

var options = Memory.SearchOptions()
options.mode = .textOnly
let context = try await memory.search(<QUERY>, options: options)
_ = context.items
try await memory.close()
```

Internal implementation checklist:
1. Provide normalized multimodal embeddings.
2. Provide host-supplied transcripts; Wax does not transcribe in v1.
3. Ingest local files with stable IDs.
4. Recall by text and verify segment evidence.
