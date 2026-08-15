---
sidebar_position: 2
title: "Foundation Models"
sidebar_label: "Foundation Models"
---

Apple's Foundation Models give you on-device generation (`LanguageModelSession`, tools, `@Generable`). They do not keep a durable store across launches. Wax is that store: one `.wax` file plus adapters that inject recalled text, register memory tools, and optionally write turns back.

Requires **iOS 26 / iPadOS 26** (and Apple Intelligence where the model is available). Use a package checkout of **`main`** (see [Get started](./getting-started)); tag `0.1.24` keeps these adapters `package`-internal.

Guard production code with `#if canImport(FoundationModels)` and availability checks. On a device without Apple Intelligence, `respond` will fail even if the code compiles — check availability first.

## Quick path: memory-backed session

Paste into an iOS 26 app target:

```swift
import Foundation
import FoundationModels
import Wax

@available(iOS 26.0, *)
func chatWithMemory() async throws {
    let url = URL.documentsDirectory.appending(path: "assistant.wax")
    let memory = try await Memory(at: url)

    let session = memory.foundationModelsSession(
        instructions: "You are a helpful assistant with durable on-device memory."
    )

    switch WaxFoundationModelsAvailability.current() {
    case .available:
        let answer = try await session.respond(
            to: "I prefer dark mode and Vim keybindings."
        )
        print(answer)
    case .unavailable(let reason):
        print("Foundation Models unavailable: \(reason)")
    }

    try await session.close() // does not close `memory`
    try await memory.close()
}
```

`foundationModelsSession` is synchronous. It captures the `Memory` handle and builds a `WaxFoundationModelSession`. Closing the session leaves `memory` open so you can share the store with other screens or tools.

## What the adapter does

Default config is **hybrid**:

| Piece | Behavior |
| --- | --- |
| Prompt augmentation | Recalls related memory and injects a `<wax_memory>` block before generation |
| Tools | Registers `waxRemember`, `waxRecall`, `waxSearch` (`.focused` kit) |
| Turn persistence | Writes user and assistant turns when `persistencePolicy` allows it |

### Config presets

```swift
import Foundation
import FoundationModels
import Wax

@available(iOS 26.0, *)
func makeConfiguredSession(memory: Memory) -> WaxFoundationModelSession {
    var configuration = FoundationModelsMemorySessionConfig.default
    // or: .hybridBalanced / .toolsOnlyCompact / .promptOnlyLight

    configuration.contextStrategy = .hybrid          // .promptAugmentation | .tools | .hybrid
    configuration.persistencePolicy = .userAndAssistant
    configuration.embeddingPolicy = .automatic
    configuration.toolKit = .focused                 // .compact | .combined | .focusedWithForget

    return memory.foundationModelsSession(
        instructions: "Be concise.",
        configuration: configuration
    )
}
```

Use `.durableFactsOnly` when chat turns should not auto-persist — only explicit `remember` / tool writes land in the store.

### Tool kits

| Kit | Tools |
| --- | --- |
| `.focused` (default) | waxRemember, waxRecall, waxSearch |
| `.compact` | waxRemember, waxRecall |
| `.combined` | waxMemory (multi-action) |
| `.focusedWithForget` | focused + waxForget |

```swift
import FoundationModels
import Wax

@available(iOS 26.0, *)
func makeForgetCapableTools(memory: Memory) -> [any Tool] {
    memory.foundationModelsTools(kit: .focusedWithForget)
}
```

## Availability

```swift
import FoundationModels
import Wax

@available(iOS 26.0, *)
func printFoundationModelsAvailability() {
    switch WaxFoundationModelsAvailability.current() {
    case .available:
        print("ready")
    case .unavailable(let reason):
        print("Foundation Models unavailable: \(reason)")
    }
}
```

Reasons map from `SystemLanguageModel.Availability` (`deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`, …).

## Detailed responses and streaming

```swift
import Foundation
import FoundationModels
import Wax

@available(iOS 26.0, *)
func detailedAndStreamingExamples(session: WaxFoundationModelSession) async throws {
    let detailed = try await session.respondDetailed(to: "What theme do I prefer?")
    print(detailed.content)
    print(detailed.recalledItemCount, detailed.includedItemCount, detailed.truncatedByBudget)
    print(detailed.didPersistUser, detailed.didPersistAssistant)

    let collected = try await session.streamResponseAndCollect(to: "Summarize my prefs.")
    print(collected.content)
}
```

Raw `streamResponse(to:)` still persists the user turn only when configured — partial tokens are not written as assistant memory. Prefer `streamResponseAndCollect` when you want a complete turn on disk.

## Attach tools to your own session

```swift
import Foundation
import FoundationModels
import Wax

@available(iOS 26.0, *)
func attachWaxTools(storeURL: URL) async throws {
    let memory = try await Memory(at: storeURL)
    let tools = memory.foundationModelsTools(kit: .focused)

    let session = LanguageModelSession(tools: tools) {
        "You have long-term memory via waxRemember / waxRecall / waxSearch."
    }

    guard case .available = WaxFoundationModelsAvailability.current() else {
        try await memory.close()
        return
    }

    let response = try await session.respond(to: "Remember that I use Swift 6.2.")
    print(response.content)
    try await memory.close()
}
```

## Structured generation

```swift
import Foundation
import FoundationModels
import Wax

@available(iOS 26.0, *)
func structuredPreferenceSummary(session: WaxFoundationModelSession) async throws {
    @Generable
    struct PreferenceSummary {
        var theme: String
        var editor: String
    }

    let summary = try await session.respond(
        to: "Summarize my UI and editor preferences.",
        generating: PreferenceSummary.self
    )
    print(summary.theme, summary.editor)
}
```

Persistence of structured values follows `configuration.structuredPersistence`.

## One-liner that owns the store

```swift
import Foundation
import FoundationModels
import Wax

@available(iOS 26.0, *)
func openOwnedFoundationModelsSession(storeURL: URL) async throws -> WaxFoundationModelSession {
    try await Memory.openFoundationModelsSession(
        at: storeURL,
        builtInEmbedding: .miniLM,
        instructions: "You have durable memory."
    )
    // session.close() also closes the underlying Memory
}
```

Built-in MiniLM needs iOS 18+ and the default `MiniLMEmbeddings` trait. If the model cannot load, this initializer throws.

## Reset chat, keep the file

```swift
import FoundationModels
import Wax

@available(iOS 26.0, *)
func resetChatKeepingStore(session: WaxFoundationModelSession) async -> WaxFoundationModelSession {
    await session.resetConversationPreservingMemory()
    // Replace your handle with the returned session; both share the same Memory store.
}
```

## Practical notes

- Always enter through `Memory`. Do not construct package-only orchestrators from app code.
- Keep secrets out of the store. Wax holds durable text, not credentials.
- Prefixed recalled memory is treated as untrusted context for the model, not as elevated system instructions.
- Generation samples need a real iOS 26 device (or supported simulator) with Apple Intelligence enabled. Compilation only proves the API surface.
