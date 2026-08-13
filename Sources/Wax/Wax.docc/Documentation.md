# ``Wax``

High-level orchestration and RAG for persistent, on-device memory with semantic search.

## Overview

The Wax module is the primary public API surface for building memory-augmented applications. It provides:

- **``Memory``** — The main text memory facade: save content, search/recall context, flush, and close
- **Foundation Models adapters** — Use Wax as durable memory for Apple's on-device Foundation Models
- **``RAGContext``** — Token-budget-aware retrieval results for prompts and agents
- **Built-in embeddings** — Optional MiniLM / Arctic providers for vector search
- **``PhotoMemory`` / ``VideoMemory``** — Public owning facades for on-device photo and video recall
- **Structured memory** — Public entity, fact, and edge APIs on ``Memory``
- **Package-only internals** — `MemoryOrchestrator`, `PhotoRAGOrchestrator`, `VideoRAGOrchestrator`, and `WaxSession`

```swift compile
import Foundation
import Wax

func catalogQuickStart() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL)
    try await memory.save("Met with Alice about the Q4 roadmap")
    let context = try await memory.search("What did Alice say?")
    print(context.items.map(\.text))
    try await memory.close()
}
```

### Foundation Models (macOS 26 / iOS 26+)

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func catalogFoundationModels() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let session = try await memory.makeFoundationModelsSession(
            instructions: "You are a helpful assistant with durable memory."
        )
        _ = try await session.respond(to: "What did Alice say about Q4?")
        try await session.close()
    }
    #endif
    try await memory.close()
}
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:MigratingToMemoryConfigEmbedding>
- <doc:Architecture>
- ``Memory``
- ``RAGContext``

### Structured, photo, and video memory

- <doc:StructuredMemory>
- <doc:PhotoRAG>
- <doc:VideoRAG>
- ``PhotoMemory``
- ``VideoMemory``

### Foundation Models

- <doc:FoundationModels>
- ``WaxFoundationModelSession``
- ``WaxMemoryTool``
- ``FoundationModelsMemorySessionConfig``

### Sessions

- <doc:SessionManagement>

### RAG Pipeline

- <doc:RAGPipeline>
- ``RAGContext``

### Search

- <doc:UnifiedSearch>

### Photo RAG

- <doc:PhotoRAG>

### Video RAG

- <doc:VideoRAG>
