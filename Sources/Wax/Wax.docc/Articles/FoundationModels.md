# Foundation Models

Use Wax as durable, on-device memory for Apple's Foundation Models framework.

## Overview

Apple's Foundation Models (`LanguageModelSession`, tools, guided generation) give you
on-device generation. They do **not** provide a durable cross-session memory store.
Wax fills that gap with a single-file local store and a first-class Foundation Models adapter.

On Apple platforms that ship Foundation Models (macOS 26+, iOS 26+, visionOS 26+), Wax exposes:

- ``Memory/foundationModelsSession(model:instructions:additionalTools:configuration:)``
- ``Memory/foundationModelsMemoryTool(config:)``
- ``Memory/foundationModelsTools(kit:config:)``
- ``WaxFoundationModelSession``
- ``WaxMemoryTool`` / ``WaxRememberTool`` / ``WaxRecallTool`` / ``WaxSearchTool`` / ``WaxForgetTool``
- ``WaxFMResponse`` and ``WaxFoundationModelsAvailability``

## Quick start

```swift
import Foundation
import FoundationModels
import Wax

let storeURL = URL.documentsDirectory.appending(path: "assistant.wax")
let memory = try await Memory(at: storeURL)

// One-liner: prompt augmentation + focused memory tools + turn persistence
let session = await memory.foundationModelsSession(
    instructions: "You are a helpful assistant with durable memory."
)

let answer = try await session.respond(to: "I prefer dark mode and Vim keybindings.")
// Later sessions can still recall those preferences from the .wax store.

try await session.close()
```

## How the adapter works

``WaxFoundationModelSession`` combines three strategies (defaults use **hybrid**):

| Strategy | Behavior |
|----------|----------|
| Prompt augmentation | Recalls relevant memory and injects a `<wax_memory>` block before generation |
| Tools | Registers focused tools (`waxRemember` / `waxRecall` / `waxSearch`) by default |
| Turn persistence | Optionally writes user and assistant turns back into Wax |

Configure via ``FoundationModelsMemorySessionConfig``:

```swift
var configuration = FoundationModelsMemorySessionConfig.default
configuration.contextStrategy = .hybrid          // .promptAugmentation | .tools | .hybrid
configuration.persistencePolicy = .userAndAssistant
configuration.embeddingPolicy = .automatic
configuration.toolKit = .focused                 // .compact | .combined | .focusedWithForget
// Top-level fields apply at prepare time even if you don't replace promptBuilder:
// configuration.injectionStyle = .instructionsAppendix
// configuration.memoryCharacterBudget = 800

let session = await memory.foundationModelsSession(
    instructions: "Be concise.",
    configuration: configuration
)
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

```swift
let tools = memory.foundationModelsTools(kit: .focusedWithForget)
```

## Detailed responses and streaming

Prefer ``WaxFoundationModelSession/respondDetailed(to:options:)`` when you need recall /
persistence accounting. Plain ``respond(to:options:)`` still returns just the content string.

```swift
let detailed = try await session.respondDetailed(to: "What theme do I prefer?")
print(detailed.content)
print(detailed.recalledItemCount, detailed.includedItemCount, detailed.truncatedByBudget)
print(detailed.didPersistUser, detailed.didPersistAssistant)
```

``preparePromptDetailed(for:)`` returns a ``PreparedMemoryPrompt`` with the same budget fields
without calling the model.

For streaming with full assistant persistence after the stream finishes:

```swift
let collected = try await session.streamResponseAndCollect(to: "Summarize my prefs.")
// collected.content is the full assistant text; both sides persist per policy.
```

Raw ``streamResponse(to:options:)`` still persists only the user turn (partial tokens are
not written as assistant memory).

## Availability and reset

Check Apple Intelligence / model readiness before generating:

```swift
switch WaxFoundationModelsAvailability.current() {
case .available:
    break
case .unavailable(let reason):
    print("Foundation Models unavailable: \(reason)")
}
```

To clear the in-model transcript while keeping the Wax store:

```swift
let fresh = await session.resetConversationPreservingMemory()
// Replace your handle with `fresh`; both share the same Memory store.
```

## Use Wax tools on your own LanguageModelSession

If you already own a `LanguageModelSession`, attach Wax as tools:

```swift
let memory = try await Memory(at: storeURL)
let tools = memory.foundationModelsTools(kit: .focused)

let session = LanguageModelSession(tools: tools) {
    "You have long-term memory via the waxRemember / waxRecall / waxSearch tools."
}

let response = try await session.respond(to: "Remember that I use Swift 6.2.")
```

## Structured generation

```swift
@Generable
struct PreferenceSummary {
    var theme: String
    var editor: String
}

let summary = try await session.respond(
    to: "Summarize my UI and editor preferences.",
    generating: PreferenceSummary.self
)
// Persistence of structured values follows configuration.structuredPersistence
// (.stringDescribing | .jsonLike | .disabled).
```

## Built-in embeddings open helper

```swift
let session = try await Memory.openFoundationModelsSession(
    at: storeURL,
    builtInEmbedding: .miniLM,
    instructions: "You have durable memory."
)
```

## Design notes

- The public entry point is always ``Memory``. Package-only orchestrators stay internal.
- Memory tools and session adapters are availability-gated to Foundation Models platforms.
- Streaming via ``WaxFoundationModelSession/streamResponse(to:options:)`` persists the user
  turn when configured, but does not auto-persist partial assistant tokens; use
  ``streamResponseAndCollect(to:options:)`` when you want full-turn persistence.
- Keep secrets out of memory; Wax stores durable text, not credentials.
