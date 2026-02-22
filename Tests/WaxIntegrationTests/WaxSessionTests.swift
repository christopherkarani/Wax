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

@Test func withSessionReleasesWriterLeaseOnSuccess() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false

        try await wax.withSession(.readWrite(.fail), config: config) { session in
            try await session.indexText(frameId: 1, text: "hello")
        }

        // Must succeed because withSession should close and release the lease.
        let writer = try await wax.openSession(.readWrite(.fail), config: config)
        await writer.close()
        try await wax.close()
    }
}

@Test func withSessionReleasesWriterLeaseOnFailure() async throws {
    struct ExpectedFailure: Error {}

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false

        do {
            _ = try await wax.withSession(.readWrite(.fail), config: config) { _ in
                throw ExpectedFailure()
            }
            #expect(Bool(false))
        } catch is ExpectedFailure {
            // Expected.
        }

        // Must still succeed because withSession should close on error paths too.
        let writer = try await wax.openSession(.readWrite(.fail), config: config)
        await writer.close()
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

// MARK: - Phase 7A: read-only mode write restrictions

@Test func readOnlySession_rejectsAllWriteOperations() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = true

        let reader = try await wax.openSession(.readOnly, config: config)

        // put(_:options:compression:) must throw "session is read-only"
        do {
            _ = try await reader.put(Data("denied".utf8))
            #expect(Bool(false), "Expected read-only error on put")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io")
                return
            }
            #expect(reason == "session is read-only")
        }

        // indexText must throw "session is read-only"
        do {
            try await reader.indexText(frameId: 1, text: "hello")
            #expect(Bool(false), "Expected read-only error on indexText")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io")
                return
            }
            #expect(reason == "session is read-only")
        }

        // indexTextBatch must throw "session is read-only"
        do {
            try await reader.indexTextBatch(frameIds: [1, 2], texts: ["a", "b"])
            #expect(Bool(false), "Expected read-only error on indexTextBatch")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io")
                return
            }
            #expect(reason == "session is read-only")
        }

        // removeText must throw "session is read-only"
        do {
            try await reader.removeText(frameId: 1)
            #expect(Bool(false), "Expected read-only error on removeText")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io")
                return
            }
            #expect(reason == "session is read-only")
        }

        // upsertEntity must throw "session is read-only"
        do {
            _ = try await reader.upsertEntity(
                key: EntityKey("person:alice"),
                kind: "person",
                aliases: ["Alice"],
                nowMs: 0
            )
            #expect(Bool(false), "Expected read-only error on upsertEntity")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io")
                return
            }
            #expect(reason == "session is read-only")
        }

        // stage() must throw "session is read-only"
        do {
            try await reader.stage()
            #expect(Bool(false), "Expected read-only error on stage")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io")
                return
            }
            #expect(reason == "session is read-only")
        }

        await reader.close()
        try await wax.close()
    }
}

// MARK: - Phase 7A: indexTextBatch success path

@Test func unifiedSession_indexTextBatchIndexesAndSearchesMultipleFrames() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let writer = try await wax.openSession(.readWrite(.fail), config: config)

        let frameA = try await writer.put(Data("corgi".utf8))
        let frameB = try await writer.put(Data("labrador".utf8))

        try await writer.indexTextBatch(
            frameIds: [frameA, frameB],
            texts: ["fluffy corgi runs fast", "friendly labrador fetches"]
        )

        try await writer.commit()
        await writer.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)

        let corgiHits = try await reader.searchText(query: "corgi", topK: 5)
        #expect(corgiHits.contains { $0.frameId == frameA })
        #expect(!corgiHits.contains { $0.frameId == frameB })

        let labradorHits = try await reader.searchText(query: "labrador", topK: 5)
        #expect(labradorHits.contains { $0.frameId == frameB })

        await reader.close()
        try await reopened.close()
    }
}

// MARK: - Phase 7A: search delegation through session

@Test func unifiedSession_searchDelegatesHybridQueryThroughSessionOverrides() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let writer = try await wax.openSession(.readWrite(.fail), config: config)
        let frameId = try await writer.put(Data("swift concurrency".utf8))
        try await writer.indexText(frameId: frameId, text: "swift concurrency actors tasks")
        try await writer.commit()
        await writer.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)

        let response = try await reader.search(
            SearchRequest(
                query: "swift",
                mode: .textOnly,
                topK: 5
            )
        )
        #expect(response.results.contains { $0.frameId == frameId })

        await reader.close()
        try await reopened.close()
    }
}

// MARK: - Phase 7A: FTS syntax search through session

@Test func unifiedSession_searchTextFTSSyntaxPassesBooleanOperatorsThrough() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let writer = try await wax.openSession(.readWrite(.fail), config: config)
        let frameAlpha = try await writer.put(Data("alpha only".utf8))
        let frameBeta  = try await writer.put(Data("beta only".utf8))

        try await writer.indexTextBatch(
            frameIds: [frameAlpha, frameBeta],
            texts: ["alpha only", "beta only"]
        )
        try await writer.commit()
        await writer.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)

        // FTS syntax "alpha OR beta" should match both frames.
        let hits = try await reader.searchTextFTSSyntax(query: "alpha OR beta", topK: 10)
        let hitIds = Set(hits.map(\.frameId))
        #expect(hitIds.contains(frameAlpha))
        #expect(hitIds.contains(frameBeta))

        await reader.close()
        try await reopened.close()
    }
}

// MARK: - Phase 7A: close() is idempotent

@Test func session_closeIsIdempotentAndDoesNotCrash() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableVectorSearch = false

        let session = try await wax.openSession(.readWrite(.fail), config: config)

        // Calling close() twice must not crash or trap.
        await session.close()
        await session.close()

        // The writer lease must have been released on the first close, allowing
        // a new writer session to be acquired immediately.
        let newWriter = try await wax.openSession(.readWrite(.fail), config: config)
        await newWriter.close()
        try await wax.close()
    }
}

// MARK: - Phase 7A: putBatch with embeddings and timestamps

@Test func unifiedSession_putBatchWithEmbeddingsAndTimestampsPersists() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = false
        config.enableStructuredMemory = false
        config.enableVectorSearch = true
        config.vectorDimensions = 2
        config.vectorEnginePreference = .cpuOnly

        let writer = try await wax.openSession(.readWrite(.fail), config: config)

        let t0: Int64 = 1_000_000
        let t1: Int64 = 2_000_000
        let frameIds = try await writer.putBatch(
            contents: [Data("north".utf8), Data("south".utf8)],
            embeddings: [[1.0, 0.0], [0.0, 1.0]],
            options: [FrameMetaSubset(), FrameMetaSubset()],
            timestampsMs: [t0, t1],
            compression: .plain
        )
        #expect(frameIds.count == 2)

        try await writer.commit()
        await writer.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)

        // Vector for [1,0] should rank frameIds[0] first.
        let response = try await reader.search(
            SearchRequest(embedding: [1.0, 0.0], mode: .vectorOnly, topK: 2)
        )
        #expect(response.results.first?.frameId == frameIds[0])

        await reader.close()
        try await reopened.close()
    }
}

// MARK: - Phase 7A: Metal engine preference on arm64

@Test func unifiedSession_autoEnginePreferenceLoadsWithoutError() async throws {
    // This test exercises the .auto engine selection path. On arm64 macOS, Metal
    // is available and will be selected; on other platforms it falls back to USearch.
    // Either way the session must open and function correctly.
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = false
        config.enableStructuredMemory = false
        config.enableVectorSearch = true
        config.vectorDimensions = 2
        config.vectorEnginePreference = .auto

        let writer = try await wax.openSession(.readWrite(.fail), config: config)

        let frameId = try await writer.put(
            Data("metal test".utf8),
            embedding: [1.0, 0.0]
        )

        try await writer.commit()
        await writer.close()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let reader = try await reopened.openSession(.readOnly, config: config)

        let response = try await reader.search(
            SearchRequest(embedding: [1.0, 0.0], mode: .vectorOnly, topK: 1)
        )
        #expect(response.results.first?.frameId == frameId)

        await reader.close()
        try await reopened.close()
    }
}

// MARK: - Phase 7A: removeText write restriction after close

@Test func unifiedSession_removeTextThrowsAfterSessionClose() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        var config = WaxSession.Config()
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = false

        let writer = try await wax.openSession(.readWrite(.fail), config: config)
        let frameId = try await writer.put(Data("removable".utf8))
        try await writer.indexText(frameId: frameId, text: "removable content")
        try await writer.commit()
        await writer.close()

        // Attempting to write to a closed session must throw "session is closed".
        do {
            try await writer.removeText(frameId: frameId)
            #expect(Bool(false), "Expected closed-session error on removeText")
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false), "Expected WaxError.io")
                return
            }
            #expect(reason == "session is closed")
        }

        try await wax.close()
    }
}

// MARK: - Phase 7A: session mode and config are accessible

@Test func session_modeAndConfigPropertiesMatchConstruction() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let cfg = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: false,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: nil
        )

        let reader = try await wax.openSession(.readOnly, config: cfg)
        #expect(await reader.mode == .readOnly)
        #expect(await reader.config == cfg)

        await reader.close()
        try await wax.close()
    }
}
