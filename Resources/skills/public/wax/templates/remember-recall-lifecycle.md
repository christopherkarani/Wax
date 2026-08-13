Template: Save / Search Lifecycle
Goal: Ingest content, retrieve context, then persist and close.

Documented fixture tokens (snippet verifier only):
- `__WAX_STORE_URL__`

Steps:
1. Open Memory with `config.embedding` (never a removed `embedding:` initializer argument).
2. Save content with metadata.
3. Search with a query.
4. Flush and close when done.

Swift Skeleton:
```swift compile
import Foundation
import Wax

func templateRememberRecallLifecycle() async throws {
    let storeURL = __WAX_STORE_URL__
    var config = Memory.Config.default
    config.enableVectorSearch = false
    let memory = try await Memory(at: storeURL, config: config)

    try await memory.save(
        "The user prefers dark mode.",
        metadata: ["source": "docs"]
    )

    let results = try await memory.search("theme")
    _ = results.items
    _ = results.diagnostics

    try await memory.flush()
    try await memory.close()
}
```
