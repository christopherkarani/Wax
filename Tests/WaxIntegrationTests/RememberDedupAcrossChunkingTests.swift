import Foundation
import Testing
import Wax
import WaxCore
import WaxVectorSearch

/// A store written under one chunk target is re-remembered under another: MiniLM stores
/// written at the 400/40 default and now chunked at 180/18, or the reverse.
private struct AxisEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Wax",
        model: "ArcticEmbedS",
        dimensions: 4,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        [1, 0, 0, 0]
    }
}

private enum ChunkingChange {
    static let large = OrchestratorConfig.defaultChunking
    static let small = ChunkingStrategy.tokenCount(targetTokens: 180, overlapTokens: 18)

    static func config(_ chunking: ChunkingStrategy, vector: Bool) -> OrchestratorConfig {
        var config = OrchestratorConfig.default
        config.enableVectorSearch = vector
        config.requireOnDeviceProviders = false
        config.chunking = chunking
        return config
    }

    /// ~`tokens` cl100k tokens of distinct prose.
    static func content(tokens: Int) -> String {
        (0..<(tokens / 9)).map { "Entry \($0) records one archived planning decision." }.joined(separator: " ")
    }

    static func open(
        _ url: URL,
        _ chunking: ChunkingStrategy,
        vector: Bool
    ) async throws -> MemoryOrchestrator {
        try await MemoryOrchestrator(
            at: url,
            config: config(chunking, vector: vector),
            embedder: vector ? AxisEmbedder() : nil
        )
    }

    static func activeFrames(at url: URL) async throws -> (documents: Int, chunks: Int) {
        let wax = try await Wax.open(at: url)
        let live = await wax.frameMetas().filter { $0.status == .active && $0.supersededBy == nil }
        try await wax.close()
        return (live.filter { $0.role == .document }.count, live.filter { $0.role == .chunk }.count)
    }

    /// Remembers `content` under `first`, then again under `second`, and checks the second
    /// call deduplicates against the stored document without writing anything.
    static func expectDedup(
        tokens: Int,
        from first: ChunkingStrategy,
        to second: ChunkingStrategy,
        vector: Bool
    ) async throws {
        try await TempFiles.withTempFile { url in
            let text = content(tokens: tokens)
            let firstCount = await TextChunker.chunk(text: text, strategy: first).count
            let secondCount = await TextChunker.chunk(text: text, strategy: second).count
            #expect(firstCount != secondCount)

            let writer = try await open(url, first, vector: vector)
            let stored = try await writer.remember(text)
            try await writer.close()
            let before = try await activeFrames(at: url)

            let rewriter = try await open(url, second, vector: vector)
            let again = try await rewriter.remember(text)
            try await rewriter.close()

            #expect(again.deduplicated)
            #expect(again.framesAdded == 0)
            #expect(again.frameId == stored.frameId)
            let after = try await activeFrames(at: url)
            #expect(after.documents == 1)
            #expect(after.chunks == before.chunks)
        }
    }
}

@Test func rememberDedupsMultiChunkDocumentAfterChunkTargetShrinks() async throws {
    try await ChunkingChange.expectDedup(tokens: 900, from: ChunkingChange.large, to: ChunkingChange.small, vector: false)
}

@Test func rememberDedupsMultiChunkDocumentAfterChunkTargetGrows() async throws {
    try await ChunkingChange.expectDedup(tokens: 900, from: ChunkingChange.small, to: ChunkingChange.large, vector: false)
}

@Test func rememberDedupsSingleChunkDocumentAfterChunkTargetShrinks() async throws {
    try await ChunkingChange.expectDedup(tokens: 300, from: ChunkingChange.large, to: ChunkingChange.small, vector: false)
}

@Test func rememberDedupsVectorChunksAfterChunkTargetShrinks() async throws {
    try await ChunkingChange.expectDedup(tokens: 900, from: ChunkingChange.large, to: ChunkingChange.small, vector: true)
    try await ChunkingChange.expectDedup(tokens: 300, from: ChunkingChange.large, to: ChunkingChange.small, vector: true)
}
