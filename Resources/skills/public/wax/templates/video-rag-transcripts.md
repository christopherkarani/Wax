Template: VideoRAG Ingest / Recall (With Transcripts)
Goal: Ingest local videos with host-supplied transcripts and recall by text.

Placeholders:
- <STORE_URL>
- <EMBEDDER_TYPE>
- <DIMENSIONS>
- <NORMALIZE>
- <IDENTITY_PROVIDER>
- <IDENTITY_MODEL>
- <TRANSCRIPT_PROVIDER>
- <VIDEO_FILES>
- <QUERY>

Steps:
1. Implement a multimodal embedder and transcript provider.
2. Initialize VideoRAGOrchestrator.
3. Ingest local files with stable IDs.
4. Recall with a text query and flush.

Swift Skeleton:
```swift
import Foundation
import Wax
import CoreGraphics

struct <EMBEDDER_TYPE>: MultimodalEmbeddingProvider {
    let dimensions: Int = <DIMENSIONS>
    let normalize: Bool = <NORMALIZE>
    let identity: EmbeddingIdentity? = .init(
        provider: "<IDENTITY_PROVIDER>",
        model: "<IDENTITY_MODEL>",
        dimensions: <DIMENSIONS>,
        normalized: <NORMALIZE>
    )

    func embed(text: String) async throws -> [Float] { <#embed text#> }
    func embed(image: CGImage) async throws -> [Float] { <#embed image#> }
}

struct <TRANSCRIPT_PROVIDER>: VideoTranscriptProvider {
    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        [
            VideoTranscriptChunk(startMs: <START_MS>, endMs: <END_MS>, text: <TEXT>)
        ]
    }
}

let storeURL = <STORE_URL>
let rag = try await VideoRAGOrchestrator(
    storeURL: storeURL,
    config: .default,
    embedder: <EMBEDDER_TYPE>(),
    transcriptProvider: <TRANSCRIPT_PROVIDER>()
)

try await rag.ingest(files: <VIDEO_FILES>)
let context = try await rag.recall(.init(text: <QUERY>))
_ = context.items
try await rag.flush()
```
