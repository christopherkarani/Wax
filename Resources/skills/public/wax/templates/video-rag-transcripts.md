Template: Video RAG
Goal: Index a video with host-supplied transcripts and recall ranked segments.

Use `VideoMemory` (`import Wax`). `VideoRAGOrchestrator` is package-only — do not
construct it in app or docs samples.

Wax does not transcribe. The host supplies transcript text. The store keeps text
and metadata only; it does not store video or audio bytes.

```swift
import Foundation
import Wax

struct HostTranscripts: VideoTranscriptProvider {
    let executionMode = ProviderExecutionMode.onDeviceOnly
    let chunks: [VideoTranscriptChunk]

    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        _ = request
        return chunks
    }
}

func indexStandup(storeURL: URL, movieURL: URL) async throws {
    let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
    let videos = try await VideoMemory(
        at: storeURL,
        embedder: embedder,
        transcriptProvider: HostTranscripts(chunks: [
            VideoTranscriptChunk(startMs: 0, endMs: 8_000, text: "Ship Friday."),
        ])
    )
    try await videos.ingest(files: [VideoFile(id: "standup", url: movieURL)])
    let context = try await videos.recall(VideoQuery(text: "sprint retro action items"))
    _ = context.items
    try await videos.close()
}
```

Agent workflows can also use the Wax MCP `video_*` tools, which run the same
pipeline inside the Wax process.
