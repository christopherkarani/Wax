import Foundation
import Testing
@testable import Wax
import WaxCore

@Test func rememberIdenticalContentTwiceIsIdempotent() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("Duplicate content test")
        try await orchestrator.flush()

        let afterFirst = await orchestrator.runtimeStats().frameCount

        try await orchestrator.remember("Duplicate content test")
        try await orchestrator.flush()
        let afterSecond = await orchestrator.runtimeStats().frameCount

        #expect(afterSecond == afterFirst)
        try await orchestrator.close()
    }
}

@Test func rememberIdenticalContentTwiceBeforeFlushIsIdempotent() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = false

        let content = "Pending duplicate content test"
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        let stats = await orchestrator.runtimeStats()
        #expect(stats.frameCount == UInt64(expectedChunks.count + 1))

        try await orchestrator.close()
    }
}

@Test func rememberDifferentContentIncreasesFrameCount() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember("First content")
        try await orchestrator.flush()
        let afterFirst = await orchestrator.runtimeStats().frameCount

        try await orchestrator.remember("Second content")
        try await orchestrator.flush()
        let afterSecond = await orchestrator.runtimeStats().frameCount

        #expect(afterSecond > afterFirst)
        try await orchestrator.close()
    }
}

@Test func rememberRetryAfterPartialFailureRepairsMissingChunks() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = true
        config.enableTextSearch = true
        config.ingestBatchSize = 1
        config.chunking = .tokenCount(targetTokens: 3, overlapTokens: 0)

        let content = "retry repair path for partial ingest failure should recover on subsequent remember"

        let failing = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: WrongDimensionTextEmbedder()
        )
        do {
            try await failing.remember(content)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
        try await failing.close()

        let retry = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: DeterministicTextEmbedder()
        )
        try await retry.remember(content)
        try await retry.flush()

        let stats = await retry.runtimeStats()
        #expect(stats.frameCount > 1)

        let recall = try await retry.recall(query: "partial ingest failure recover")
        #expect(!recall.items.isEmpty)
        try await retry.close()
    }
}

@Test func rememberIdenticalContentAcrossSessionsPersistsEachScope() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let content = "Scoped duplicate content must persist independently per session."

        let sessionA = await orchestrator.startSession()
        try await orchestrator.remember(content)
        try await orchestrator.flush()
        let sessionAStats = try await orchestrator.sessionRuntimeStats()
        #expect(sessionAStats.active)
        #expect(sessionAStats.sessionId == sessionA)
        #expect(sessionAStats.sessionFrameCount > 0)

        let sessionB = await orchestrator.startSession()
        try await orchestrator.remember(content)
        try await orchestrator.flush()
        let sessionBStats = try await orchestrator.sessionRuntimeStats()
        #expect(sessionBStats.active)
        #expect(sessionBStats.sessionId == sessionB)
        #expect(sessionBStats.sessionFrameCount > 0)
        #expect(sessionBStats.sessionFrameCount == sessionAStats.sessionFrameCount)

        let runtime = await orchestrator.runtimeStats()
        #expect(runtime.frameCount >= UInt64(sessionAStats.sessionFrameCount + sessionBStats.sessionFrameCount))
        try await orchestrator.close()
    }
}

@Test func rememberDedupProbeFindsCompleteScopedDocument() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        config.chunking = .tokenCount(targetTokens: 6, overlapTokens: 0)

        let content = "Scoped duplicate content must remain complete to short-circuit remember."
        let hash = ContentHasher.hash(Data(content.utf8)).hexString
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content, metadata: ["scope": "alpha"])
        try await orchestrator.flush()
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let probe = await wax.rememberDedupProbe(
            contentHash: hash,
            metadata: [
                "scope": "alpha",
                "wax.content.hash": hash,
            ],
            expectedChunkCount: chunks.count,
            embeddingIdentity: nil
        )

        #expect(probe != nil)
        #expect(probe?.isComplete == true)
        try await wax.close()
    }
}

@Test func rememberDedupProbeKeepsPartialScopedDocumentRetryable() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let docHash = ContentHasher.hash(Data("partial".utf8)).hexString

        let docId = try await wax.put(
            Data("partial".utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata([
                    "scope": "beta",
                    "wax.content.hash": docHash,
                ])
            )
        )
        _ = try await wax.put(
            Data("chunk 0".utf8),
            options: FrameMetaSubset(
                role: .chunk,
                parentId: docId,
                chunkIndex: 0,
                chunkCount: 2,
                metadata: Metadata(["scope": "beta"])
            )
        )
        try await wax.commit()

        let probe = await wax.rememberDedupProbe(
            contentHash: docHash,
            metadata: [
                "scope": "beta",
                "wax.content.hash": docHash,
            ],
            expectedChunkCount: 2,
            embeddingIdentity: nil
        )

        #expect(probe != nil)
        #expect(probe?.isComplete == false)
        try await wax.close()
    }
}

@Test func embeddingIdentityMetadataRoundTripsThroughWaxAndVectorSessions() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let identity = EmbeddingIdentity(
            provider: "Wax",
            model: "MiniLM",
            dimensions: 2,
            normalized: true
        )

        var sessionConfig = WaxSession.Config()
        sessionConfig.enableTextSearch = false
        sessionConfig.enableStructuredMemory = false
        sessionConfig.enableVectorSearch = true
        sessionConfig.vectorDimensions = 2
        sessionConfig.vectorEnginePreference = .cpuOnly

        let session = try await wax.openSession(.readWrite(.fail), config: sessionConfig)
        let waxFrameId = try await session.put(
            Data("wax-session-identity".utf8),
            embedding: [1.0, 0.0],
            identity: identity
        )
        try await session.commit()
        await session.close()

        let vector = try await wax.enableVectorSearch(dimensions: 2, preference: .cpuOnly)
        let vectorFrameId = try await vector.putWithEmbedding(
            Data("vector-session-identity".utf8),
            embedding: [0.0, 1.0],
            identity: identity
        )
        try await vector.commit()

        let metas = await wax.frameMetasIncludingPending(frameIds: [waxFrameId, vectorFrameId])
        let waxEntries = try #require(metas[waxFrameId]?.metadata?.entries)
        let vectorEntries = try #require(metas[vectorFrameId]?.metadata?.entries)

        for entries in [waxEntries, vectorEntries] {
            #expect(entries[EmbeddingIdentityMetadata.providerKey] == "Wax")
            #expect(entries[EmbeddingIdentityMetadata.modelKey] == "MiniLM")
            #expect(entries[EmbeddingIdentityMetadata.dimensionKey] == "2")
            #expect(entries[EmbeddingIdentityMetadata.normalizedKey] == "true")
            #expect(entries[EmbeddingIdentityMetadata.legacyProviderKey] == nil)
            #expect(entries[EmbeddingIdentityMetadata.legacyModelKey] == nil)
            #expect(entries[EmbeddingIdentityMetadata.legacyDimensionKey] == nil)
            #expect(entries[EmbeddingIdentityMetadata.legacyNormalizedKey] == nil)
        }

        try await wax.close()
    }
}

@Test func rememberDedupProbeHonorsEmbeddingIdentityAcrossCanonicalAndLegacyKeys() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let content = "embedding identity dedup"
        let docHash = ContentHasher.hash(Data(content.utf8)).hexString
        let identity = RememberDedupEmbeddingIdentity(
            provider: "Wax",
            model: "MiniLM",
            dimensions: 2,
            normalized: true
        )

        let canonicalDocId = try await wax.put(
            Data(content.utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata([
                    "scope": "canonical",
                    "wax.content.hash": docHash,
                ])
            )
        )
        _ = try await wax.put(
            Data("chunk-canonical".utf8),
            options: FrameMetaSubset(
                role: .chunk,
                parentId: canonicalDocId,
                chunkIndex: 0,
                chunkCount: 1,
                metadata: Metadata([
                    EmbeddingIdentityMetadata.providerKey: "Wax",
                    EmbeddingIdentityMetadata.modelKey: "MiniLM",
                    EmbeddingIdentityMetadata.dimensionKey: "2",
                    EmbeddingIdentityMetadata.normalizedKey: "true",
                ])
            )
        )

        let legacyDocId = try await wax.put(
            Data(content.utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata([
                    "scope": "legacy",
                    "wax.content.hash": docHash,
                ])
            )
        )
        _ = try await wax.put(
            Data("chunk-legacy".utf8),
            options: FrameMetaSubset(
                role: .chunk,
                parentId: legacyDocId,
                chunkIndex: 0,
                chunkCount: 1,
                metadata: Metadata([
                    EmbeddingIdentityMetadata.legacyProviderKey: "Wax",
                    EmbeddingIdentityMetadata.legacyModelKey: "MiniLM",
                    EmbeddingIdentityMetadata.legacyDimensionKey: "2",
                    EmbeddingIdentityMetadata.legacyNormalizedKey: "true",
                ])
            )
        )

        let mismatchedDocId = try await wax.put(
            Data(content.utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: Metadata([
                    "scope": "mismatch",
                    "wax.content.hash": docHash,
                ])
            )
        )
        _ = try await wax.put(
            Data("chunk-mismatch".utf8),
            options: FrameMetaSubset(
                role: .chunk,
                parentId: mismatchedDocId,
                chunkIndex: 0,
                chunkCount: 1,
                metadata: Metadata([
                    EmbeddingIdentityMetadata.providerKey: "Other",
                    EmbeddingIdentityMetadata.modelKey: "OtherModel",
                    EmbeddingIdentityMetadata.dimensionKey: "2",
                    EmbeddingIdentityMetadata.normalizedKey: "true",
                ])
            )
        )
        try await wax.commit()

        let canonicalProbe = await wax.rememberDedupProbe(
            contentHash: docHash,
            metadata: [
                "scope": "canonical",
                "wax.content.hash": docHash,
            ],
            expectedChunkCount: 1,
            embeddingIdentity: identity
        )
        #expect(canonicalProbe?.documentId == canonicalDocId)
        #expect(canonicalProbe?.isComplete == true)

        let legacyProbe = await wax.rememberDedupProbe(
            contentHash: docHash,
            metadata: [
                "scope": "legacy",
                "wax.content.hash": docHash,
            ],
            expectedChunkCount: 1,
            embeddingIdentity: identity
        )
        #expect(legacyProbe?.documentId == legacyDocId)
        #expect(legacyProbe?.isComplete == true)

        let mismatchedProbe = await wax.rememberDedupProbe(
            contentHash: docHash,
            metadata: [
                "scope": "mismatch",
                "wax.content.hash": docHash,
            ],
            expectedChunkCount: 1,
            embeddingIdentity: identity
        )
        #expect(mismatchedProbe?.documentId == mismatchedDocId)
        #expect(mismatchedProbe?.isComplete == false)

        try await wax.close()
    }
}
