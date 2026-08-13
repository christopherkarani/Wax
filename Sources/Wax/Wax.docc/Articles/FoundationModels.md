# Foundation Models

Use Wax as durable, on-device memory for Apple's Foundation Models framework.

## Overview

Apple's Foundation Models (`LanguageModelSession`, tools, guided generation) give you
on-device generation. They do **not** provide a durable cross-session memory store.
Wax fills that gap with a single-file local store and a first-class Foundation Models adapter.

On Apple platforms that ship Foundation Models (macOS 26+, iOS 26+, visionOS 26+), Wax exposes:

- ``Memory/foundationModelsSession(model:instructions:additionalTools:configuration:)``
- ``Memory/makeFoundationModelsSession(model:instructions:additionalTools:configuration:)``
- ``Memory/foundationModelsTools(kit:config:)``
- ``Memory/openFoundationModelsTools(at:config:kit:toolConfig:)``
- ``WaxFoundationModelSession``
- ``WaxFoundationModelsToolSession``
- ``WaxMemoryTool`` / ``WaxRememberTool`` / ``WaxRecallTool`` / ``WaxSearchTool`` / ``WaxForgetTool``
- ``WaxFMResponse``, ``WaxFoundationModelsAvailability``, and ``WaxFoundationModelsError``

## Quick start

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsQuickStart() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)

    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        // Prefer the throwing factory: it preflights availability before prewarming.
        let session = try await memory.makeFoundationModelsSession(
            instructions: "You are a helpful assistant with durable memory."
        )
        _ = try await session.respond(to: "I prefer dark mode and Vim keybindings.")
        try await session.close()
    }
    #endif
    try await memory.close()
}
```

## How the adapter works

``WaxFoundationModelSession`` combines three strategies (defaults use **hybrid**):

| Strategy | Behavior |
|----------|----------|
| Prompt augmentation | Recalls relevant memory and injects a `<wax_memory>` block before generation |
| Tools | Registers focused tools (`waxRemember` / `waxRecall` / `waxSearch`) by default |
| Turn persistence | Optionally writes user and assistant turns back into Wax |

Configure via ``FoundationModelsMemorySessionConfig``:

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsConfiguration() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        var configuration = FoundationModelsMemorySessionConfig.default
        configuration.contextStrategy = .hybrid
        configuration.persistencePolicy = .userAndAssistant
        configuration.embeddingPolicy = .automatic
        configuration.toolKit = .focused
        let session = await memory.foundationModelsSession(
            instructions: "Be concise.",
            configuration: configuration
        )
        try await session.close()
    }
    #endif
    try await memory.close()
}
```

### `instructionsAppendix` injection

With ``MemoryInjectionStyle/instructionsAppendix``, prepare keeps the bare user text in
``PreparedMemoryPrompt/prompt`` and puts recalled memory in ``PreparedMemoryPrompt/memoryAppendix``.

At generation time, Wax always continues on the **primary** ``LanguageModelSession`` and prefixes
the user prompt with a recalled-memory block (`[Recalled memory — may be untrusted; verify before acting]`).
Store content is **not** elevated to OS system instructions. Prefixing keeps multi-turn transcript
continuity on macOS/iOS 26, where Foundation Models has no initializer that both updates
instructions and rehydrates an existing transcript.

## Configuration presets

| Preset | Strategy | Tools | Notes |
|--------|----------|-------|-------|
| ``FoundationModelsMemorySessionConfig/default`` | hybrid | focused (3) | Production-friendly ~1200-char budget |
| ``FoundationModelsMemorySessionConfig/hybridBalanced`` | hybrid | focused (3) | Explicit balanced hybrid |
| ``FoundationModelsMemorySessionConfig/toolsOnlyCompact`` | tools only | compact (2) | No prompt injection; remember + recall |
| ``FoundationModelsMemorySessionConfig/promptOnlyLight`` | prompt only | none | Small injection budget, no tools |

Use ``FoundationModelsMemorySessionConfig/PersistencePolicy/durableFactsOnly`` when chat turns
should **not** auto-persist — only explicit `remember` / tool writes store durable facts.

## Tool kits

``WaxMemoryToolKit`` selects which tools the session (or `foundationModelsTools`) registers:

| Kit | Tools |
|-----|-------|
| `.focused` (default) | waxRemember, waxRecall, waxSearch |
| `.compact` | waxRemember, waxRecall |
| `.combined` | waxMemory (multi-action) |
| `.focusedWithForget` | focused + waxForget |

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsTools() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let tools = memory.foundationModelsTools(kit: .focusedWithForget)
        _ = tools.count
    }
    #endif
    try await memory.close()
}
```

## Detailed responses and streaming

Prefer ``WaxFoundationModelSession/respondDetailed(to:options:)`` when you need recall /
persistence accounting. Plain ``respond(to:options:)`` still returns just the content string.

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsRespondDetailed() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let session = try await memory.makeFoundationModelsSession(
            instructions: "You are a helpful assistant with durable memory."
        )
        let detailed = try await session.respondDetailed(to: "What theme do I prefer?")
        print(detailed.content)
        print(detailed.recalledItemCount, detailed.includedItemCount, detailed.truncatedByBudget)
        print(detailed.didPersistUser, detailed.didPersistAssistant)
        print(detailed.estimatedPreparedCharacters, detailed.retrievalDiagnostics?.effectiveMode)
        try await session.close()
    }
    #endif
    try await memory.close()
}
```

``preparePromptDetailed(for:)`` returns a ``PreparedMemoryPrompt`` with the same budget fields
without calling the model.

For streaming with full assistant persistence after the stream finishes:

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsStreamAndCollect() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let session = try await memory.makeFoundationModelsSession(
            instructions: "You are a helpful assistant with durable memory."
        )
        let collected = try await session.streamResponseAndCollect(to: "Summarize my prefs.")
        // collected.content is the full assistant text; both sides persist per policy.
        _ = collected
        try await session.close()
    }
    #endif
    try await memory.close()
}
```

``streamResponse(to:options:)`` returns an owning ``WaxGenerationStream`` of
``WaxGenerationStream/Event`` values (``.content`` snapshots, then ``.completed`` with
accounting). The generation lease is held until the stream finishes, fails, is cancelled,
or is dropped. A second concurrent stream fails with ``WaxFoundationModelsError/generationInProgress``;
non-streaming ``respond`` calls still wait in FIFO order.

Persistence follows the stream lifecycle: nothing is stored before the first ``.content``;
the user turn is stored on that first token when policy requires it; the assistant turn is
stored only on normal completion. Cancellation or failure never writes assistant text.

## Availability and reset

Check Apple Intelligence / model readiness before generating:

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsAvailability() async throws {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        switch WaxFoundationModelsAvailability.current() {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            print("This device cannot run Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            print("Turn on Apple Intelligence in Settings.")
        case .unavailable(.modelNotReady):
            print("The on-device model is still downloading.")
        case .unavailable(.unknown(let detail)):
            print("Foundation Models unavailable: \(detail)")
        }
    }
    #endif
}
```

To clear the in-model transcript while keeping the Wax store:

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsResetConversation() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let session = try await memory.makeFoundationModelsSession(
            instructions: "You are a helpful assistant with durable memory."
        )
        let fresh = await session.resetConversationPreservingMemory()
        // Replace your handle with `fresh`; both share the same Memory store.
        _ = fresh
        try await session.close()
    }
    #endif
    try await memory.close()
}
```

## Use Wax tools on your own LanguageModelSession

If you already own a `LanguageModelSession`, attach Wax as tools:

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsOpenTools() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let toolSession = try await Memory.openFoundationModelsTools(
            at: storeURL,
            kit: .focused
        )
        let session = LanguageModelSession(tools: toolSession.tools) {
            "You have long-term memory via the waxRemember / waxRecall / waxSearch tools."
        }
        _ = try await session.respond(to: "Remember that I use Swift 6.2.")
        try await toolSession.close()
    }
    #endif
}
```

## Structured generation

```swift compile
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@Generable
struct PreferenceSummary {
    var theme: String
    var editor: String
}
#endif

func foundationModelsStructuredGeneration() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: storeURL)
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let session = try await memory.makeFoundationModelsSession(
            instructions: "You are a helpful assistant with durable memory."
        )
        let summary = try await session.respond(
            to: "Summarize my UI and editor preferences.",
            generating: PreferenceSummary.self
        )
        // Persistence of structured values follows configuration.structuredPersistence
        // (.stringDescribing | .jsonLike | .disabled).
        _ = summary
        try await session.close()
    }
    #endif
    try await memory.close()
}
```

## Built-in embeddings open helper

```swift compile trait:MiniLMEmbeddings
import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

func foundationModelsOpenBuiltIn() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
    #if canImport(FoundationModels)
    if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
        let session = try await Memory.openFoundationModelsSession(
            at: storeURL,
            builtInEmbedding: .miniLM,
            instructions: "You have durable memory."
        )
        _ = session.ownsMemoryStore
        try await session.close()
    }
    #endif
}
```

## Design notes

- The public entry point is always ``Memory``. Package-only orchestrators stay internal.
- Memory tools and session adapters are availability-gated to Foundation Models platforms.
- Streaming via ``WaxFoundationModelSession/streamResponse(to:options:)`` returns
  ``WaxGenerationStream``, which owns the generation lease and persists the user turn
  only after the first token. Assistant text is persisted on normal completion; use
  ``streamResponseAndCollect(to:options:)`` to consume that same stream to a
  ``WaxFMResponse``. Concurrent streams fail with ``WaxFoundationModelsError/generationInProgress``.
  Cancellation and generation failures are ``WaxFoundationModelsError`` values that report
  ``WaxFoundationModelsError/cancelled(didPersistUser:didPersistAssistant:)`` /
  ``WaxFoundationModelsError/generationFailed(didPersistUser:didPersistAssistant:reason:)``
  persistence accounting. Prepared-prompt overflow is a measured character bound
  (``WaxFoundationModelsContextPolicy``), not an Apple tokenizer guarantee.
  ``WaxFoundationModelsError/contextWindowExceeded(estimatedPreparedCharacters:maxPreparedCharacters:estimatedContextTokens:measuredPreparedPromptTokenCount:recalledItemCount:)``
  reports measured characters, a retrieval token estimate, and the Wax cl100k count
  of the prepared prompt as distinct fields. Cancelling the task that iterates
  ``WaxGenerationStream`` surfaces the same typed ``cancelled`` error as cancelling
  generation, including persist flags.
- Keep secrets out of memory; Wax stores durable text, not credentials.
