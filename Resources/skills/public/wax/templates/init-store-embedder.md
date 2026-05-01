Template: Initialize Public Memory + Embedder
Goal: Open or create a Wax store using the public Memory facade.

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
2. Implement or provide a public `EmbeddingProvider`.
3. Open `Memory` with the embedder and config overrides.

Swift Skeleton:
```swift
import Foundation
import Wax

actor <EMBEDDER_TYPE>: EmbeddingProvider {
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

var config = Memory.Config()
<CONFIG_OVERRIDES>
let memory = try await Memory(at: <STORE_URL>, config: config, embedding: <EMBEDDER_TYPE>())
```

Text-only alternative:
```swift
import Foundation
import Wax

var config = Memory.Config()
config.enableVectorSearch = false
let memory = try await Memory(at: <STORE_URL>, config: config)
```

Package-internal note: `MiniLMEmbedder` and `MemoryOrchestrator.openMiniLM(...)`
are not external API in the current Wax target.
