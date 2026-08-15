# Foundation Models + Wax (iOS 26 / macOS 26+)

Read this when wiring Apple's on-device Foundation Models (`LanguageModelSession`, tools)
to a durable `.wax` store. Gate all code with `#if canImport(FoundationModels)` and
`@available(iOS 26, macOS 26, *)`.

Wax fills the gap Foundation Models do not: **cross-session durable memory** on device.

## Default path (session adapter)

Prefer `Memory.foundationModelsSession` — prompt augmentation + memory tools + optional turn persistence:

```swift
#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Wax

@available(iOS 26, macOS 26, *)
func makeAssistant(at url: URL) async throws -> WaxFoundationModelSession {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let memory = try await Memory(at: url)

    switch WaxFoundationModelsAvailability.current() {
    case .available: break
    case .unavailable(let reason):
        throw WaxError.io("Foundation Models unavailable: \(reason)")
    }

    return await memory.foundationModelsSession(
        instructions: "You are a helpful assistant with durable on-device memory."
    )
}

@available(iOS 26, macOS 26, *)
func chat(_ session: WaxFoundationModelSession, userText: String) async throws -> String {
    try await session.respond(to: userText)
    // Later launches still recall preferences from the .wax file.
}
#endif
```

Call `try await session.close()` when the session **owns** the store
(`Memory.openFoundationModelsSession`). If you opened `Memory` yourself and passed it in,
`close()` on the session does not replace your own `Memory.flush`/`close` lifecycle —
still flush the `Memory` on app background.

## Attach tools to your own LanguageModelSession

```swift
#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
func makeToolsSession(memory: Memory) -> LanguageModelSession {
    let tools = memory.foundationModelsTools(kit: .focused) // remember, recall, search
    return LanguageModelSession(tools: tools) {
        "Use waxRemember / waxRecall / waxSearch for durable memory."
    }
}
#endif
```

| Kit | Tools |
|-----|-------|
| `.focused` (default) | waxRemember, waxRecall, waxSearch |
| `.compact` | waxRemember, waxRecall |
| `.combined` | single multi-action `waxMemory` |
| `.focusedWithForget` | focused + waxForget |

## Configuration presets

```swift
var configuration = FoundationModelsMemorySessionConfig.default
configuration.contextStrategy = .hybrid   // .promptAugmentation | .tools | .hybrid
configuration.persistencePolicy = .userAndAssistant
// .durableFactsOnly → do not auto-persist chat turns; only explicit remember/tool writes

let session = await memory.foundationModelsSession(
    instructions: "Be concise.",
    configuration: configuration
)
```

| Preset | Strategy | Notes |
|--------|----------|-------|
| `.default` / `.hybridBalanced` | hybrid | Prompt inject + focused tools |
| `.toolsOnlyCompact` | tools only | No prompt injection |
| `.promptOnlyLight` | prompt only | Small budget, no tools |

## Detailed respond / streaming

```swift
let detailed = try await session.respondDetailed(to: "What theme do I prefer?")
_ = detailed.content
_ = (detailed.recalledItemCount, detailed.didPersistUser, detailed.didPersistAssistant)

let collected = try await session.streamResponseAndCollect(to: "Summarize my prefs.")
_ = collected.content
```

Raw `streamResponse` persists the user turn when configured but not partial assistant tokens —
prefer `streamResponseAndCollect` when assistant persistence matters.

## Open helpers

```swift
// Owns the store — session.close() closes Memory
let session = try await Memory.openFoundationModelsSession(
    at: url,
    builtInEmbedding: .miniLM,
    instructions: "You have durable memory."
)
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
```

## Rules

- Always enter through `Memory` — never package-only orchestrators.
- Check `WaxFoundationModelsAvailability.current()` before generating.
- Same store locking / flush rules as the rest of this skill.
- Reset in-model chat without wiping Wax: `await session.resetConversationPreservingMemory()`.

Upstream DocC: `Sources/Wax/Wax.docc/Articles/FoundationModels.md` in the Wax repo.
