---
sidebar_position: 1
title: "Get started on iOS"
sidebar_label: "Get started"
---

Add Wax to an iOS or iPadOS app, open a `.wax` store in Documents, then save and search text.

:::info Dependency pin
These samples match the **current `main` API** (`Memory.Config.embedding`, `stats()`, search `diagnostics`, public Foundation Models adapters). In Xcode, add the package from **branch `main`** until the next tagged release that includes that surface. Tag `0.1.24` still has Foundation Models types as `package`-only, so app targets cannot use those samples against that release.
:::

## 1. Add the package in Xcode

1. **File → Add Package Dependencies…**
2. Enter `https://github.com/christopherkarani/Wax.git`
3. Dependency rule: **Branch** → `main` (or a release newer than `0.1.25` once published with the public adapters)
4. Add the **Wax** product to your app target

Or in a Swift package:

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", branch: "main"),
],
```

```swift
.target(
    name: "MyApp",
    dependencies: ["Wax"]
)
```

Wax targets iOS 17+. On `main`, the default `MiniLMEmbeddings` trait loads a built-in embedder on iOS 18+ so semantic search works without extra setup. On iOS 17, `Memory` still runs; search falls back to full-text unless you supply a custom `EmbeddingProvider`.

## 2. Open a store and try it

Paste this into a Swift file in your app target (or into a SwiftUI `.task`). It writes under Documents so the file survives relaunches.

```swift
import Foundation
import Wax

func waxQuickStart() async throws {
    let url = URL.documentsDirectory.appending(path: "app-memory.wax")

    let memory = try await Memory(at: url)

    try await memory.save("The user is building a habit tracker in SwiftUI.")
    try await memory.save("Preferred theme: dark mode.")

    let results = try await memory.search("What is the user building?")
    if let best = results.items.first {
        print(best.text)
        // The user is building a habit tracker in SwiftUI.
    }

    try await memory.close()
}
```

Then call it once, for example from SwiftUI:

```swift
.task {
    try? await waxQuickStart()
}
```

That modifier goes on a SwiftUI `View` (for example your root `ContentView` body).

`Memory(at:)` creates the file if it is missing, or opens an existing one and recovers unfinished writes from the WAL.

## 3. SwiftUI sketch

Paste into an iOS App target that already imports SwiftUI:

```swift
import SwiftUI
import Wax

struct MemoryProbeView: View {
    @State private var line = "…"

    var body: some View {
        Text(line)
            .task {
                do {
                    let url = URL.documentsDirectory.appending(path: "app-memory.wax")
                    let memory = try await Memory(at: url)
                    try await memory.save("User prefers Vim keybindings.")
                    let context = try await memory.search("editor preferences")
                    line = context.items.first?.text ?? "Nothing found"
                    try await memory.close()
                } catch {
                    line = error.localizedDescription
                }
            }
    }
}
```

Keep one long-lived `Memory` (or a small owner type) for production apps instead of open/close on every screen. Call `flush()` when you need durable writes before suspension; `close()` flushes for you.

## 4. Check what search actually did

Hybrid search is the default. If the vector lane is offline (no embedder, older OS, timeout), Wax uses the text lane and reports that on the result:

```swift
import Foundation
import Wax

func waxPrintSearchDiagnostics(storeURL: URL) async throws {
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }

    try await memory.save("Q4 roadmap notes with Alice.")
    let results = try await memory.search("roadmap")
    if let diagnostics = results.diagnostics {
        print(diagnostics.requestedMode)
        print(diagnostics.effectiveMode)
        print(diagnostics.queryEmbeddingState)
    }

    let stats = await memory.stats()
    print(stats.vectorSearchEnabled)
    print(stats.queryEmbedderConfigured)
    print(stats.embeddingStatus)
    try await memory.close()
}
```

## Next

- Wire Apple's on-device model: [Foundation Models](./foundation-models)
- Tune search and embeddings: [Memory API](./memory-api)
