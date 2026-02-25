import Foundation
import Testing
import Wax

@Test func unifiedSession_textAndStructuredPersistWithSingleCommit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false

        let session = try await wax.openSession(.readWrite(.fail), config: config)
        try await session.indexText(frameId: 1, text: "Ada writes about engines")

        let now: Int64 = 100
        _ = try await session.upsertEntity(
            key: EntityKey("person:ada"),
            kind: "person",
            aliases: ["Ada"],
            nowMs: now
        )

        _ = try await session.assertFact(
            subject: EntityKey("person:ada"),
            predicate: PredicateKey("writes"),
            object: .string("notes"),
            valid: StructuredTimeRange(fromMs: 0),
            system: StructuredTimeRange(fromMs: now),
            evidence: []
        )

        try await session.commit()
        await session.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)
        let hits = try await reader.searchText(query: "Ada", topK: 10)
        #expect(hits.contains { $0.frameId == 1 })

        let facts = try await reader.facts(
            about: EntityKey("person:ada"),
            predicate: PredicateKey("writes"),
            asOf: .latest,
            limit: 10
        )
        #expect(facts.hits.contains { $0.fact.predicate == PredicateKey("writes") })
        await reader.close()
        try await reopened.close()
    }
}

@Test func unifiedSession_disallowsSecondWriterSession() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false

        let session = try await wax.openSession(.readWrite(.fail), config: config)
        do {
            _ = try await wax.openSession(.readWrite(.fail), config: config)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .writerBusy = error else {
                #expect(Bool(false))
                return
            }
        }

        await session.close()
    }
}

@Test func unifiedSession_releasesWriterLeaseWhenInitializationFails() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        var failingConfig = WaxSession.Config()
        failingConfig.enableTextSearch = false
        failingConfig.enableStructuredMemory = false
        failingConfig.enableVectorSearch = true
        failingConfig.vectorEnginePreference = .cpuOnly
        failingConfig.vectorDimensions = 0 // Triggers USearchVectorEngine init failure.

        do {
            _ = try await wax.openSession(.readWrite(.fail), config: failingConfig)
            Issue.record("Expected writer session initialization to fail for invalid vector dimensions")
        } catch {
            // Expected: initialization throws after acquiring writer lease.
        }

        var succeedingConfig = WaxSession.Config()
        succeedingConfig.enableTextSearch = false
        succeedingConfig.enableStructuredMemory = false
        succeedingConfig.enableVectorSearch = false

        let session = try await wax.openSession(.readWrite(.fail), config: succeedingConfig)
        await session.close()
        try await wax.close()
    }
}

@Test func unifiedSession_vectorSearchWorksBeforeAndAfterCommit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = false
        config.enableStructuredMemory = false
        config.enableVectorSearch = true
        config.vectorDimensions = 2
        config.vectorEnginePreference = .cpuOnly

        let writer = try await wax.openSession(.readWrite(.fail), config: config)

        let frameA = try await writer.put(
            Data("alpha".utf8),
            embedding: [1.0, 0.0],
            options: FrameMetaSubset(searchText: "alpha")
        )
        _ = try await writer.put(
            Data("beta".utf8),
            embedding: [0.0, 1.0],
            options: FrameMetaSubset(searchText: "beta")
        )

        let beforeCommit = try await writer.search(
            SearchRequest(
                embedding: [1.0, 0.0],
                mode: .vectorOnly,
                topK: 2
            )
        )
        #expect(beforeCommit.results.first?.frameId == frameA)

        try await writer.commit()
        await writer.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)
        let afterCommit = try await reader.search(
            SearchRequest(
                embedding: [1.0, 0.0],
                mode: .vectorOnly,
                topK: 2
            )
        )
        #expect(afterCommit.results.first?.frameId == frameA)

        await reader.close()
        try await reopened.close()
    }
}

@Test func unifiedSession_commitPropagatesMissingVectorIndexError() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = false
        config.enableStructuredMemory = false
        config.enableVectorSearch = false

        let session = try await wax.openSession(.readWrite(.fail), config: config)
        let frameId = try await session.put(Data("payload".utf8), options: FrameMetaSubset(searchText: "payload"))
        try await wax.putEmbedding(frameId: frameId, vector: [1.0, 0.0])

        do {
            try await session.commit()
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("vector index must be staged before committing embeddings"))
        }

        await session.close()
        do {
            try await wax.close()
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("vector index must be staged before committing embeddings"))
        }
    }
}

@Test func unifiedSession_putEmbeddingBatchPersistsSearchOrder() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = false
        config.enableStructuredMemory = false
        config.enableVectorSearch = true
        config.vectorDimensions = 2
        config.vectorEnginePreference = .cpuOnly

        let writer = try await wax.openSession(.readWrite(.fail), config: config)

        let frameIds = try await writer.putBatch(
            contents: [Data("first".utf8), Data("second".utf8)],
            embeddings: [[1.0, 0.0], [0.0, 1.0]],
            options: [FrameMetaSubset(searchText: "first"), FrameMetaSubset(searchText: "second")]
        )
        #expect(frameIds.count == 2)

        try await writer.commit()
        await writer.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)
        let response = try await reader.search(
            SearchRequest(
                embedding: [1.0, 0.0],
                mode: .vectorOnly,
                topK: 2
            )
        )
        #expect(response.results.first?.frameId == frameIds[0])

        await reader.close()
        try await reopened.close()
    }
}
