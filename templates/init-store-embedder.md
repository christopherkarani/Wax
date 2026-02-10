Template: Initialize Store + Embedder
Goal: Open or create a Wax store and wire an embedder for ingest + recall.

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
2. Configure the orchestrator.
3. Create the embedder (custom or MiniLM).
4. Open the MemoryOrchestrator.

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
var config = OrchestratorConfig.default
<CONFIG_OVERRIDES>

let embedder = <EMBEDDER_TYPE>()
let orchestrator = try await MemoryOrchestrator(
    at: storeURL,
    config: config,
    embedder: embedder
)
```

Alternative (MiniLM):
```swift
import Wax

let storeURL = <STORE_URL>
let orchestrator = try await MemoryOrchestrator.openMiniLM(at: storeURL)
```
