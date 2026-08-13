# Migrating to Memory.Config.embedding

Wax 0.2.0 removes the extra ``Memory`` initializers that took an embedder beside `config`. Embedder selection now lives only on ``Memory/Config-swift.struct/embedding``.

## Overview

``Memory/init(at:config:)`` and the configure-closure form ``Memory/init(at:configure:)`` are the shipping initializers. There is no `Memory(at:embedding:)` and no `Memory(at:config:embedding:)`.

## Before / after

### No explicit embedder → `.automatic`

Before:

```swift
let memory = try await Memory(at: storeURL)
```

After (`.automatic` is the default; setup is no longer unbounded):

```swift compile
import Foundation
import Wax

func migrateAutomatic() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    var config = Memory.Config.default
    config.embedding = .automatic
    let memory = try await Memory(at: storeURL, config: config)
    try await memory.close()
}
```

On iOS 18/macOS 15+ with the default `MiniLMEmbeddings` trait, `.automatic` wires MiniLM using ``BuiltInEmbeddingProviderOptions/automatic`` (15 second setup bound). If setup times out or the model fails to load, the store falls back to text-only search and ``Memory/stats()`` reports ``EmbeddingStatus/unavailable(reason:)`` with a precise reason. On older OS versions, or when the trait is compiled out, the store also runs text-only; check ``Memory/stats()`` or ``RAGContext/diagnostics``.

``.builtIn(.miniLM)`` still uses ``BuiltInEmbeddingProviderOptions/default`` (120 second timeout) and throws ``BuiltInEmbeddingProviderError/unavailable(_:)`` instead of falling back.

### `embedding:` argument → `config.embedding = .custom(...)`

Before:

```swift
let memory = try await Memory(at: storeURL, embedding: MyEmbedder())
```

After (value form):

```swift compile
import Foundation
import Wax

actor MyEmbedder: EmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "docs",
        model: "v1",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(_ text: String) async throws -> [Float] {
        text.localizedCaseInsensitiveContains("password")
            ? [1, 0, 0, 0]
            : [0, 1, 0, 0]
    }
}

func migrateCustomValueForm() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    var config = Memory.Config.default
    config.embedding = .custom(MyEmbedder())
    let memory = try await Memory(at: storeURL, config: config)
    try await memory.close()
}
```

### `builtInEmbedding:` → `config.embedding = .builtIn(...)`

Before:

```swift
let memory = try await Memory(at: storeURL, builtInEmbedding: .miniLM)
```

After:

```swift compile
import Foundation
import Wax

func migrateBuiltIn() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    var config = Memory.Config.default
    config.embedding = .builtIn(.miniLM)
    let memory = try await Memory(at: storeURL, config: config)
    try await memory.close()
}
```

`.builtIn` throws when the provider cannot be constructed (trait compiled out, model missing, or unsupported OS). Arctic requires the `ArcticEmbeddings` trait: `config.embedding = .builtIn(.arctic)`.

### Closure configuration → closure form or value form

Both of these are supported and equivalent:

```swift compile
import Foundation
import Wax

func migrateClosureForm() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    let memory = try await Memory(at: storeURL) { config in
        config.embedding = .builtIn(.miniLM)
        config.enableStructuredMemory = true
    }
    try await memory.close()
}
```

```swift compile
import Foundation
import Wax

func migrateValueForm() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "memory.wax")
    var config = Memory.Config.default
    config.embedding = .builtIn(.miniLM)
    config.enableStructuredMemory = true
    let memory = try await Memory(at: storeURL, config: config)
    try await memory.close()
}
```

The configure closures on ``Memory/init(at:configure:)`` and ``Memory/search(_:configure:)`` are `@Sendable`. Do not capture non-Sendable values into them.

### `SearchOptions.topK` is a result cap, not candidate depth

Before, `search(_:options:)` passed `options.topK` into FastRAG assembly, so ``Memory/SearchOptions/topK`` (default 10) overrode candidate depth.

After, candidate depth is ``Memory/RAGConfig/searchTopK`` (default 24). ``Memory/SearchOptions/topK`` only truncates the returned item list. ``RAGContext/totalTokens`` is recomputed from the truncated items, so it describes the returned list rather than the pre-truncation assembly.

Set `config.rag.searchTopK` when you need a deeper candidate pool:

```swift
var config = Memory.Config.default
config.rag.searchTopK = 24
let memory = try await Memory(at: storeURL, config: config)
let results = try await memory.search("query", options: .init(topK: 10))
```

### Foundation Models owning factory

| Factory | Ownership | Notes |
|---------|-----------|--------|
| ``Memory/foundationModelsSession(model:instructions:additionalTools:configuration:)`` | Does **not** own ``Memory`` | Nonthrowing; does not preflight or prewarm |
| ``Memory/makeFoundationModelsSession(model:instructions:additionalTools:configuration:)`` | Does **not** own ``Memory`` | Throws ``WaxFoundationModelsError/unavailable(_:)`` after ``WaxFoundationModelsAvailability`` preflight, then prewarms |
| ``Memory/openFoundationModelsSession(at:config:model:instructions:additionalTools:sessionConfiguration:)`` | **Owns** the store | `close()` closes ``Memory``. Set the embedder on `config.embedding` only |
| ``Memory/openFoundationModelsSession(at:config:builtInEmbedding:embeddingOptions:model:instructions:additionalTools:sessionConfiguration:)`` | **Owns** the store | Sets `config.embedding = .builtIn(...)` |
| ``Memory/openFoundationModelsTools(at:config:kit:toolConfig:)`` | **Owns** the store via ``WaxFoundationModelsToolSession`` | Prefer this over a tool array with no close handle |

Replace “open a session and assume the model is ready” with `makeFoundationModelsSession` or `openFoundationModelsSession`, and check ``WaxFoundationModelsAvailability/current(model:)``.

The `embedding:` argument on `openFoundationModelsSession` is removed. It was a side-channel onto `config.embedding = .custom(...)`. Pass the embedder on ``Memory/Config-swift.struct/embedding``:

```swift
var config = Memory.Config.default
config.embedding = .custom(MyEmbedder())
let session = try await Memory.openFoundationModelsSession(at: storeURL, config: config)
```

``WaxFoundationModelSession/init(memory:model:instructions:additionalTools:configuration:)`` never owns the store. There is no public `ownsMemory:` parameter; a caller who still holds ``Memory`` cannot construct a session that will `close()` that store. Owning sessions come only from ``Memory/openFoundationModelsSession``.

`languageModelSession` was a public `LanguageModelSession` handle in 0.1.x and is `package` in 0.2.0. A public accessor would bypass the generation lease and let callers overlap Apple requests. Use ``WaxFoundationModelSession/respond(to:options:)`` / ``WaxFoundationModelSession/streamResponse(to:options:)``; inspect ``WaxFoundationModelSession/transcript`` / ``WaxFoundationModelSession/isResponding`` for status.

### `EmbeddingProvider.executionMode` defaults to `.mayUseNetwork`

``EmbeddingProvider/executionMode`` used to default to `.onDeviceOnly`, so ``Memory/Config-swift.struct/requireOnDeviceProviders`` (default `true`) could not reject a network embedder that omitted the property. The protocol default is now `.mayUseNetwork`. On-device providers must set `.onDeviceOnly` explicitly. Omitting the property is treated as network-capable and is rejected when `requireOnDeviceProviders` is true.

``QueryAwareEmbeddingProvider`` is re-exported from `import Wax` (same as ``EmbeddingProvider``). Arctic-style query prefixes no longer require `import WaxVectorSearch`.

### Removed duplicate Foundation Models config fields

`includeMemoryTools` is derived from ``FoundationModelsMemorySessionConfig/contextStrategy`` (tools register for `.tools` and `.hybrid`). `injectionStyle` and `memoryCharacterBudget` write through to ``FoundationModelsMemoryPromptBuilder`` so there is one source of truth. Prepared-prompt overflow is ``WaxFoundationModelsContextPolicy`` (measured characters), not a duplicate token-window field on the session config. ``WaxFMResponse/contextWindowTokens`` and ``WaxFMResponse/remainingContextTokens`` stay `nil` because Apple does not expose a tokenizer window.

Keyword/entity enrichment on ``Memory/Config-swift.struct`` is ``Memory/EnrichmentPolicy`` (`.disabled` / `.builtIn`), not `enableAsyncEnrichment`.

### Removed `WaxMemoryToolExecutor` and `WaxMemoryToolRenderer`

These types were public in 0.1.x and are `package` in 0.2.0. Callers that invoked `WaxMemoryToolExecutor.execute(memory:config:action:...)` or formatted output with `WaxMemoryToolRenderer` will not compile.

Before:

```swift
let result = await WaxMemoryToolExecutor.execute(
    memory: memory,
    config: .default,
    action: "remember",
    content: "Prefers Swift"
)
let text = WaxMemoryToolRenderer.renderRemember(contentLength: 13)
```

After: use the public ``WaxMemoryTool`` surface (and the focused remember/recall/search/forget tools) through the owning session APIs. Do not call the executor or renderer.

- ``Memory/foundationModelsTools(kit:config:)`` / ``Memory/foundationModelsMemoryTool(config:)`` — tools bound to an existing ``Memory`` (the handle is not owned by the tools)
- ``Memory/openFoundationModelsTools(at:config:kit:toolConfig:)`` — owns the store; ``WaxFoundationModelsToolSession/close()`` closes ``Memory``
- ``Memory/foundationModelsSession(model:instructions:additionalTools:configuration:)``, ``Memory/makeFoundationModelsSession(model:instructions:additionalTools:configuration:)``, and ``Memory/openFoundationModelsSession(at:config:model:instructions:additionalTools:sessionConfiguration:)`` — Language Model sessions with memory tools registered according to ``FoundationModelsMemorySessionConfig/contextStrategy``

`WaxMemoryToolKit`, `WaxMemoryToolAction`, `WaxMemoryToolConfig`, `WaxMemoryToolResult`, and the `Tool` types (``WaxMemoryTool``, ``WaxRememberTool``, ``WaxRecallTool``, ``WaxSearchTool``, ``WaxForgetTool``) remain public.
