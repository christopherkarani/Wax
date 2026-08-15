# ``Wax``

High-level orchestration and RAG for persistent, on-device memory with semantic search.

## Overview

The Wax module is the primary public API surface for building memory-augmented applications. It provides:

- **``Memory``** — The main text memory facade: save content, search/recall context, flush, and close
- **Foundation Models adapters** — Use Wax as durable memory for Apple's on-device Foundation Models
- **``RAGContext``** — Token-budget-aware retrieval results for prompts and agents
- **Built-in embeddings** — Optional MiniLM / Arctic providers for vector search
- **Package-only advanced surfaces** — Photo RAG, Video RAG, and low-level orchestrators for Wax internals

```swift
import Wax

let memory = try await Memory(at: storeURL)
try await memory.save("Met with Alice about the Q4 roadmap")
let context = try await memory.search("What did Alice say?")
print(context.items.map(\.text))
```

### Foundation Models (macOS 26 / iOS 26+)

```swift
import FoundationModels
import Wax

let memory = try await Memory(at: storeURL)
let session = memory.foundationModelsSession(
    instructions: "You are a helpful assistant with durable memory."
)
let answer = try await session.respond(to: "What did Alice say about Q4?")
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Architecture>
- ``Memory``
- ``RAGContext``

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
