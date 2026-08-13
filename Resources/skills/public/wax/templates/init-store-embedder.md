Template: Initialize Store + Embedder
Goal: Open or create a Wax store and wire an embedder for ingest + search.

Documented fixture tokens (snippet verifier only):
- `__WAX_STORE_URL__`

Steps:
1. Build the store URL.
2. Create an input-dependent embedder (never all-zero vectors).
3. Open `Memory` with `config.embedding = .custom(...)`.
4. Store two items and confirm the intended match ranks first.

Swift Skeleton:
```swift compile
import Foundation
import Wax

actor DocsEmbedder: EmbeddingProvider {
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

func templateInitStoreEmbedder() async throws {
    let storeURL = __WAX_STORE_URL__
    var config = Memory.Config.default
    config.embedding = .custom(DocsEmbedder())
    let memory = try await Memory(at: storeURL, config: config)
    try await memory.save("Password reset instructions are in account settings.")
    try await memory.save("The office snack drawer has trail mix.")
    let results = try await memory.search("recover password") { options in
        options.mode = .vectorOnly
        options.topK = 1
    }
    precondition(results.items.first?.text.contains("Password reset") == true)
    try await memory.close()
}
```

Alternative (built-in MiniLM, throws when unavailable):
```swift compile
import Foundation
import Wax

func templateInitBuiltIn() async throws {
    let storeURL = __WAX_STORE_URL__
    let memory = try await Memory(at: storeURL) { $0.embedding = .builtIn(.miniLM) }
    try await memory.close()
}
```

Alternative (automatic: built-in MiniLM when the platform supports it, text-only otherwise):
```swift compile
import Foundation
import Wax

func templateInitAutomatic() async throws {
    let storeURL = __WAX_STORE_URL__
    let memory = try await Memory(at: storeURL)
    _ = await memory.stats().queryEmbedderConfigured
    try await memory.close()
}
```
