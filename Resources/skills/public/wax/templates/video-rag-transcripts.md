Template: Video memory with host-supplied transcripts
Goal: Open `VideoMemory`, ingest a local file, and search. Wax does not transcribe.

Documented fixture tokens (snippet verifier only):
- `__WAX_STORE_URL__`
- `__WAX_VIDEO_URL__`

`VideoRAGOrchestrator` is package-only. Application code uses `VideoMemory`.

Swift Skeleton:
```swift compile
import Foundation
import Wax

struct TemplateVideoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 8
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "docs",
        model: "video",
        dimensions: 8,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0, 0, 0, 0, 0]
    }

    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float] {
        _ = imageData
        _ = format
        return [0, 1, 0, 0, 0, 0, 0, 0]
    }
}

struct TemplateTranscripts: VideoTranscriptProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func transcript(for request: VideoMemory.TranscriptRequest) async throws -> [VideoMemory.TranscriptChunk] {
        _ = request
        return [
            VideoMemory.TranscriptChunk(startMs: 0, endMs: 1_000, text: "opening scene")
        ]
    }
}

func templateVideoMemory() async throws {
    let videos = try await VideoMemory.open(
        at: __WAX_STORE_URL__,
        embedding: TemplateVideoEmbedder(),
        transcriptProvider: TemplateTranscripts()
    )
    try await videos.ingest(files: [
        VideoMemory.File(id: "clip-1", url: __WAX_VIDEO_URL__)
    ])
    let hits = try await videos.search(.init(text: "opening scene", resultLimit: 5))
    _ = hits.items.first?.id
    try await videos.close()
}
```
