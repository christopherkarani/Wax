import Foundation
import Testing
@testable import Wax
import WaxTextSearch
import WaxVectorSearch

private func makeSerializedStagedTextIndex(frameId: UInt64, text: String) async throws -> Data {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: frameId, text: text)
    return try await engine.serialize()
}

private func makeSerializedStagedVectorIndex(
    frameId: UInt64,
    vector: [Float],
    dimensions: Int
) async throws -> Data {
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: dimensions)
    try await engine.add(frameId: frameId, vector: vector)
    return try await engine.serialize()
}

@Test
func unifiedSearchCacheResetAndStagedIndexPathsWork() async throws {
    let cache = UnifiedSearchEngineCache()

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let stagedTextBytes = try await makeSerializedStagedTextIndex(
            frameId: 777,
            text: "staged text cache hit"
        )
        try await wax.stageLexIndexForNextCommit(bytes: stagedTextBytes, docCount: 1)

        let stagedTextEngine = try await cache.textEngine(for: wax)
        let textHits = try await stagedTextEngine.search(query: "staged", topK: 5)
        #expect(textHits.first?.frameId == 777)

        // Second lookup should hit the staged cache key path.
        _ = try await cache.textEngine(for: wax)

        let stagedVecBytes = try await makeSerializedStagedVectorIndex(
            frameId: 888,
            vector: [1, 0],
            dimensions: 2
        )
        try await wax.stageVecIndexForNextCommit(
            bytes: stagedVecBytes,
            vectorCount: 1,
            dimension: 2,
            similarity: .cosine
        )

        let stagedVectorEngine = try await cache.vectorEngine(
            for: wax,
            queryEmbeddingDimensions: 2,
            preference: .cpuOnly
        )
        #expect(stagedVectorEngine != nil)
        let vectorHits = try await stagedVectorEngine?.search(vector: [1, 0], topK: 5)
        #expect(vectorHits?.first?.frameId == 888)

        // Second lookup should hit the staged vector cache key path.
        _ = try await cache.vectorEngine(for: wax, queryEmbeddingDimensions: 2, preference: .cpuOnly)

        let statsBeforeReset = await cache.snapshotStats()
        #expect(statsBeforeReset.textDeserializations >= 1)
        #expect(statsBeforeReset.vectorDeserializations >= 1)

        await cache.resetStats()
        let statsAfterReset = await cache.snapshotStats()
        #expect(statsAfterReset.textDeserializations == 0)
        #expect(statsAfterReset.vectorDeserializations == 0)

        let countsBeforeReset = await cache.snapshotEntryCounts()
        #expect(countsBeforeReset.text > 0)
        #expect(countsBeforeReset.vector > 0)

        await cache.resetForTests()
        let countsAfterReset = await cache.snapshotEntryCounts()
        #expect(countsAfterReset.text == 0)
        #expect(countsAfterReset.vector == 0)

        try await wax.close()
    }
}

@Test
func unifiedSearchCacheTextTierEvictsOldestEntryAfterCapacity() async throws {
    let cache = UnifiedSearchEngineCache()

    var waxes: [Wax] = []
    var urls: [URL] = []
    urls.reserveCapacity(72)
    waxes.reserveCapacity(72)

    for idx in 0..<72 {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
        urls.append(url)

        let wax = try await Wax.create(at: url)
        waxes.append(wax)

        let textSession = try await wax.enableTextSearch()
        let payload = "eviction payload \(idx)"
        let frameID = try await wax.put(Data(payload.utf8))
        try await textSession.index(frameId: frameID, text: payload)
        try await textSession.commit()
        _ = try await cache.textEngine(for: wax)
    }

    let counts = await cache.snapshotEntryCounts()
    #expect(counts.text <= 64)
    #expect((await cache.containsEntry(for: waxes[0])) == false)

    for wax in waxes {
        try await wax.close()
    }
    for url in urls {
        try? FileManager.default.removeItem(at: url)
    }

    await cache.resetForTests()
}

@Test
func unifiedSearchCacheLoadsCommittedLexIndexAndReusesEntry() async throws {
    let cache = UnifiedSearchEngineCache()

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let textSession = try await wax.enableTextSearch()

        let frameID = try await wax.put(Data("committed lexical entry".utf8))
        try await textSession.index(frameId: frameID, text: "committed lexical entry")
        try await textSession.commit()

        let firstEngine = try await cache.textEngine(for: wax)
        let firstHits = try await firstEngine.search(query: "lexical", topK: 5)
        #expect(firstHits.first?.frameId == frameID)

        let firstStats = await cache.snapshotStats()
        #expect(firstStats.textDeserializations >= 1)

        _ = try await cache.textEngine(for: wax)
        let secondStats = await cache.snapshotStats()
        #expect(secondStats.textDeserializations == firstStats.textDeserializations)

        await cache.resetStats()
        #expect((await cache.snapshotStats()).textDeserializations == 0)
        #expect(await cache.containsEntry(for: wax))

        await cache.resetForTests()
        try await wax.close()
    }
}

@Test
func unifiedSearchCacheLoadsCommittedVectorIndexAndReusesEntry() async throws {
    let cache = UnifiedSearchEngineCache()

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.enableVectorSearch(
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )

        let frameID = try await wax.put(Data("committed vector entry".utf8))
        try await session.add(frameId: frameID, vector: [1, 0])
        try await session.commit()

        let firstEngine = try await cache.vectorEngine(
            for: wax,
            queryEmbeddingDimensions: 2,
            preference: .cpuOnly
        )
        #expect(firstEngine != nil)
        let firstHits = try await firstEngine?.search(vector: [1, 0], topK: 5)
        #expect(firstHits?.contains(where: { $0.frameId == frameID }) == true)

        let firstStats = await cache.snapshotStats()
        #expect(firstStats.vectorDeserializations >= 1)

        _ = try await cache.vectorEngine(for: wax, queryEmbeddingDimensions: 2, preference: .cpuOnly)
        let secondStats = await cache.snapshotStats()
        #expect(secondStats.vectorDeserializations == firstStats.vectorDeserializations)

        await cache.resetForTests()
        try await wax.close()
    }
}

@Test
func unifiedSearchCacheBuildsPendingOnlyVectorEngineAndReusesIt() async throws {
    let cache = UnifiedSearchEngineCache()

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let frameID = try await wax.put(Data("pending-only vector entry".utf8))
        try await wax.putEmbedding(frameId: frameID, vector: [1, 0])

        let firstEngine = try await cache.vectorEngine(
            for: wax,
            queryEmbeddingDimensions: 2,
            preference: .cpuOnly
        )
        #expect(firstEngine != nil)
        let firstHits = try await firstEngine?.search(vector: [1, 0], topK: 5)
        #expect(firstHits?.contains(where: { $0.frameId == frameID }) == true)

        let firstStats = await cache.snapshotStats()
        #expect(firstStats.vectorDeserializations == 0)
        #expect((await cache.snapshotEntryCounts()).vector == 1)
        #expect(await cache.containsEntry(for: wax))

        _ = try await cache.vectorEngine(for: wax, queryEmbeddingDimensions: 2, preference: .cpuOnly)
        let secondStats = await cache.snapshotStats()
        #expect(secondStats.vectorDeserializations == firstStats.vectorDeserializations)

        await cache.resetForTests()

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

@Test
func unifiedSearchCacheVectorEngineReturnsNilForInvalidDimensionsAndNoData() async throws {
    let cache = UnifiedSearchEngineCache()

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let zeroDimensions = try await cache.vectorEngine(
            for: wax,
            queryEmbeddingDimensions: 0,
            preference: .cpuOnly
        )
        #expect(zeroDimensions == nil)

        let noData = try await cache.vectorEngine(
            for: wax,
            queryEmbeddingDimensions: 2,
            preference: .cpuOnly
        )
        #expect(noData == nil)

        await cache.resetForTests()
        try await wax.close()
    }
}
