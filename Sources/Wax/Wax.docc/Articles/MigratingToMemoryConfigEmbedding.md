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

After (same behavior; `.automatic` is the default):

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

On iOS 18/macOS 15+ with the default `MiniLMEmbeddings` trait, `.automatic` wires MiniLM. Otherwise the store runs text-only; check ``Memory/stats()`` or ``RAGContext/diagnostics``.

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

The configure closure is `@Sendable`. Do not capture non-Sendable values into it.

### Foundation Models owning factory

| Factory | Ownership | Notes |
|---------|-----------|--------|
| ``Memory/foundationModelsSession(model:instructions:additionalTools:configuration:)`` | Does **not** own ``Memory`` | Nonthrowing; does not preflight or prewarm |
| ``Memory/makeFoundationModelsSession(model:instructions:additionalTools:configuration:)`` | Does **not** own ``Memory`` | Throws ``WaxFoundationModelsError/unavailable(_:)`` after ``WaxFoundationModelsAvailability`` preflight, then prewarms |
| ``Memory/openFoundationModelsSession(at:config:embedding:model:instructions:additionalTools:sessionConfiguration:)`` | **Owns** the store | `close()` closes ``Memory``. Optional `embedding:` still maps onto `config.embedding = .custom(...)` |
| ``Memory/openFoundationModelsSession(at:config:builtInEmbedding:embeddingOptions:model:instructions:additionalTools:sessionConfiguration:)`` | **Owns** the store | Sets `config.embedding = .builtIn(...)` |
| ``Memory/openFoundationModelsTools(at:config:kit:toolConfig:)`` | **Owns** the store via ``WaxFoundationModelsToolSession`` | Prefer this over a tool array with no close handle |

Replace “open a session and assume the model is ready” with `makeFoundationModelsSession` or `openFoundationModelsSession`, and check ``WaxFoundationModelsAvailability/current(model:)``.

### Removed duplicate Foundation Models config fields

`includeMemoryTools` is derived from ``FoundationModelsMemorySessionConfig/contextStrategy`` (tools register for `.tools` and `.hybrid`). `injectionStyle` and `memoryCharacterBudget` write through to ``FoundationModelsMemoryPromptBuilder`` so there is one source of truth. Prepared-prompt overflow is ``WaxFoundationModelsContextPolicy`` (measured characters), not a duplicate token-window field on the session config. ``WaxFMResponse/contextWindowTokens`` and ``WaxFMResponse/remainingContextTokens`` stay `nil` because Apple does not expose a tokenizer window.

Keyword/entity enrichment on ``Memory/Config-swift.struct`` is ``Memory/EnrichmentPolicy`` (`.disabled` / `.builtIn`), not `enableAsyncEnrichment`.
