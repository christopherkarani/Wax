# Video RAG

Index local video files (and Photos-library videos) with ``VideoMemory``.

## Overview

``VideoMemory`` is the public, owning facade for on-device video memory. Open a store with a ``MultimodalEmbeddingProvider``. Wax does not transcribe audio; supply a ``VideoTranscriptProvider`` when you have transcripts.

`VideoRAGOrchestrator` remains a package-only internal. Application code should not construct it.

## Open, ingest, search

```swift compile
import Foundation
import Wax

struct DocsVideoEmbedder: MultimodalEmbeddingProvider {
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

struct DocsTranscripts: VideoTranscriptProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func transcript(for request: VideoMemory.TranscriptRequest) async throws -> [VideoMemory.TranscriptChunk] {
        _ = request
        return [
            VideoMemory.TranscriptChunk(startMs: 0, endMs: 1_000, text: "opening scene")
        ]
    }
}

func videoMemoryDemo() async throws {
    let storeURL = URL.documentsDirectory.appending(path: "videos.wax")
    let videos = try await VideoMemory.open(
        at: storeURL,
        embedding: DocsVideoEmbedder(),
        transcriptProvider: DocsTranscripts()
    )
    try await videos.ingest(files: [
        VideoMemory.File(id: "clip-1", url: URL.documentsDirectory.appending(path: "clip.mp4"))
    ])
    let hits = try await videos.search(.init(text: "opening scene", resultLimit: 5))
    _ = hits.items.first?.id
    _ = hits.items.first?.segments.first?.thumbnail
    try await videos.close()
}
```

Segment keyframe thumbnails are PNG `Data?` on ``VideoMemory/Segment/thumbnail`` when ``VideoMemory/Config-swift.struct/includeThumbnailsInContext`` is true.

## Segmentation

Videos are divided into overlapping time windows. Each segment stores a keyframe embedding, an optional transcript slice, and start/end timestamps. Overlap keeps content near boundaries in at least two segments.
