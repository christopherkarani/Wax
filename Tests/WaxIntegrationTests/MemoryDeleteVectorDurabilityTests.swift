import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

// MARK: - Helpers

private func durabilityOrchestratorConfig() -> OrchestratorConfig {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.enableTextSearch = true
    config.enableAsyncEnrichment = false
    config.vectorEnginePreference = .cpuOnly
    config.chunking = .tokenCount(targetTokens: 10, overlapTokens: 0)
    return config
}

private func decodeCommittedVecFrameIds(from bytes: Data) throws -> (frameIds: [UInt64], vectorCount: UInt64) {
    let decoded = try VectorSerializer.decodeVecSegment(from: bytes)
    guard case .metal(let info, _, let frameIds) = decoded else {
        throw WaxError.io("unexpected vec payload (expected .metal/.flat decode)")
    }
    return (frameIds, info.vectorCount)
}

private func firstChunkFrameId(from wax: Wax) async throws -> UInt64 {
    let chunk = try #require(
        await wax.frameMetasIncludingPending().first(where: { $0.role == .chunk })
    )
    return chunk.id
}

// MARK: - AC1 / AC1b / AC2 / AC5 / AC6

@Test
func memoryDeleteRemovesFlushedChunkFromCommittedVecBytesBeforeClose() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicTextEmbedder(dimensions: 2)
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: durabilityOrchestratorConfig(),
            embedder: embedder
        )

        try await orchestrator.remember("Unique durability phrase AlphaVectorChunk.")
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let chunkFrameId = try await firstChunkFrameId(from: wax)

        let beforeBytes = try await wax.readCommittedVecIndexBytes()
        #expect(beforeBytes != nil, "setup: committed vec must exist after flush")
        let before = try decodeCommittedVecFrameIds(from: beforeBytes!)
        #expect(
            before.frameIds.contains(chunkFrameId),
            "setup: chunkFrameId must be present in committed vec before delete"
        )

        try await orchestrator.delete(frameId: chunkFrameId)

        // RED proof: same open store, no flush/close before assert.
        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil, "committed vec bytes must be non-nil after delete")
        let after = try decodeCommittedVecFrameIds(from: afterBytes!)
        #expect(
            !after.frameIds.contains(chunkFrameId),
            "deleted chunkFrameId still present in committed vec after delete without close"
        )

        try await orchestrator.close()
    }
}

@Test
func memoryDeleteLastVectorStagesEmptyCommittedVecBytes() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicTextEmbedder(dimensions: 2)
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: durabilityOrchestratorConfig(),
            embedder: embedder
        )

        try await orchestrator.remember("Sole embedded durability phrase OmegaLastVec.")
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let chunkFrameId = try await firstChunkFrameId(from: wax)

        let beforeBytes = try await wax.readCommittedVecIndexBytes()
        #expect(beforeBytes != nil)
        let before = try decodeCommittedVecFrameIds(from: beforeBytes!)
        #expect(before.frameIds.contains(chunkFrameId))
        #expect(before.vectorCount >= 1)

        try await orchestrator.delete(frameId: chunkFrameId)

        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil, "empty vec stage must leave non-nil header bytes")
        let after = try decodeCommittedVecFrameIds(from: afterBytes!)
        #expect(after.vectorCount == 0)
        #expect(!after.frameIds.contains(chunkFrameId))

        try await orchestrator.close()
    }
}

@Test
func memoryDeletePendingEmbeddingDoesNotRestageGhostInCommittedVec() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicTextEmbedder(dimensions: 2)
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: durabilityOrchestratorConfig(),
            embedder: embedder
        )

        // No flush: embedding stays pending (putEmbedding), not in live engine.
        try await orchestrator.remember("Pending re-inject phrase BetaPendingVec.")

        let wax = await orchestrator.wax
        let chunkFrameId = try await firstChunkFrameId(from: wax)

        // Commit inside delete must succeed (no "vector index must be staged" durability error).
        try await orchestrator.delete(frameId: chunkFrameId)

        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil, "delete of pending-only embedding must stage committed vec bytes")
        let after = try decodeCommittedVecFrameIds(from: afterBytes!)
        #expect(
            !after.frameIds.contains(chunkFrameId),
            "pending embedding re-inject left deleted chunkFrameId in committed vec"
        )

        try await orchestrator.close()
    }
}

@Test
func memoryDeleteSameIdTwiceDoesNotThrowAndKeepsVecClean() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicTextEmbedder(dimensions: 2)
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: durabilityOrchestratorConfig(),
            embedder: embedder
        )

        try await orchestrator.remember("Double delete phrase GammaTwiceVec.")
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let chunkFrameId = try await firstChunkFrameId(from: wax)
        let beforeBytes = try await wax.readCommittedVecIndexBytes()
        #expect(beforeBytes != nil)
        let before = try decodeCommittedVecFrameIds(from: beforeBytes!)
        #expect(before.frameIds.contains(chunkFrameId))

        try await orchestrator.delete(frameId: chunkFrameId)
        try await orchestrator.delete(frameId: chunkFrameId)

        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil)
        let after = try decodeCommittedVecFrameIds(from: afterBytes!)
        #expect(!after.frameIds.contains(chunkFrameId))

        try await orchestrator.close()
    }
}

@Test
func memoryDeleteThenCloseReopenOmitsIdFromRawEngine() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = DeterministicTextEmbedder(dimensions: 2)
        let config = durabilityOrchestratorConfig()
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder
        )

        try await orchestrator.remember("Reopen regression phrase DeltaReopenVec.")
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let chunkFrameId = try await firstChunkFrameId(from: wax)
        try await orchestrator.delete(frameId: chunkFrameId)
        try await orchestrator.close()

        let reopenedWax = try await Wax.open(at: url)
        let engine = try await AccelerateVectorEngine.load(
            from: reopenedWax,
            metric: .cosine,
            dimensions: embedder.dimensions
        )
        let hits = try await engine.search(vector: [1.0, 0.0], topK: 100)
        #expect(!hits.contains(where: { $0.frameId == chunkFrameId }))
        try await reopenedWax.close()
    }
}

// MARK: - AC3 (WaxSession only — not WaxVectorSearchSession)

@Test
func waxSessionRemoveVectorAfterPendingPutOmitsIdFromCommittedVec() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = false
        config.enableStructuredMemory = false
        config.enableVectorSearch = true
        config.vectorDimensions = 2
        config.vectorEnginePreference = .cpuOnly

        let session = try await wax.openSession(.readWrite(.fail), config: config)

        // put(..., embedding:) leaves putEmbedding pending only; does not add to live engine.
        let frameId = try await session.put(
            Data("pending-only embedding payload".utf8),
            embedding: [1.0, 0.0]
        )
        // No wax.delete — pure removeVector + commit durability.
        try await session.removeVector(frameId: frameId)
        try await session.commit()

        let bytes = try await wax.readCommittedVecIndexBytes()
        #expect(bytes != nil, "committed vec bytes must be non-nil after remove+commit")
        let decoded = try decodeCommittedVecFrameIds(from: bytes!)
        #expect(
            !decoded.frameIds.contains(frameId),
            "pending re-inject left frameId in committed vec after WaxSession removeVector+commit"
        )

        await session.close()
        try await wax.close()
    }
}

// MARK: - AC4a / AC4b

@Test
func memoryDeleteFrameRemovesFromTextSearchSameSession() async throws {
    try await TempFiles.withTempFile { url in
        var config = durabilityOrchestratorConfig()
        config.enableVectorSearch = true
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: DeterministicTextEmbedder(dimensions: 2)
        )

        try await orchestrator.remember("Text search forget phrase EpsilonTextGone.")
        try await orchestrator.flush()

        let hits = try await orchestrator.search(
            query: "EpsilonTextGone",
            mode: .textOnly,
            topK: 5
        )
        #expect(!hits.isEmpty)
        let frameId = hits[0].frameId

        try await orchestrator.delete(frameId: frameId)

        let after = try await orchestrator.search(
            query: "EpsilonTextGone",
            mode: .textOnly,
            topK: 5
        )
        #expect(after.isEmpty)

        try await orchestrator.close()
    }
}

@Test
func memoryDeleteWorksWhenVectorSearchDisabled() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.enableAsyncEnrichment = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)

        try await orchestrator.remember("Vector-off delete phrase ZetaTextOnly.")
        try await orchestrator.flush()

        let hits = try await orchestrator.search(
            query: "ZetaTextOnly",
            mode: .textOnly,
            topK: 5
        )
        #expect(!hits.isEmpty)
        let frameId = hits[0].frameId

        try await orchestrator.delete(frameId: frameId)

        let after = try await orchestrator.search(
            query: "ZetaTextOnly",
            mode: .textOnly,
            topK: 5
        )
        #expect(after.isEmpty)

        try await orchestrator.close()
    }
}
