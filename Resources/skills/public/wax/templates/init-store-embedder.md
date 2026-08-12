Template: Initialize Store + Embedder
Goal: Open or create a Wax store and wire an embedder for ingest + search.

Placeholders:
- <STORE_URL>
- <EMBEDDER_TYPE>
- <DIMENSIONS>
- <NORMALIZE>
- <IDENTITY_PROVIDER>
- <IDENTITY_MODEL>
- <CONFIG_OVERRIDES>

Steps:
1. Build the store URL.
2. Create the embedder (custom or built-in MiniLM).
3. Open the Memory facade with the embedder.

Swift Skeleton:
```swift
import Foundation
import Wax

struct <EMBEDDER_TYPE>: EmbeddingProvider {
    let dimensions: Int = <DIMENSIONS>
    let normalize: Bool = <NORMALIZE>
    let identity: EmbeddingIdentity? = .init(
        provider: "<IDENTITY_PROVIDER>",
        model: "<IDENTITY_MODEL>",
        dimensions: <DIMENSIONS>,
        normalized: <NORMALIZE>
    )

    func embed(_ text: String) async throws -> [Float] {
        <#embed text#>
    }
}

let storeURL = <STORE_URL>
let memory = try await Memory(at: storeURL, embedding: <EMBEDDER_TYPE>()) { config in
    <CONFIG_OVERRIDES>
}
```

Alternative (built-in MiniLM, throws when unavailable):
```swift
import Wax

let storeURL = <STORE_URL>
let memory = try await Memory(at: storeURL, builtInEmbedding: .miniLM)
```

Alternative (automatic: built-in MiniLM when the platform supports it, text-only otherwise):
```swift
import Wax

let storeURL = <STORE_URL>
let memory = try await Memory(at: storeURL)
// Verify: await memory.stats().queryEmbedderConfigured
```
