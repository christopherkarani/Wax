import Foundation
import Testing
@testable import WaxTextSearch

/// Short passages over a small vocabulary, so OR queries match most rows (like common
/// words in a 100k-passage corpus) and many rows tie on BM25.
private func corpus(count: Int) -> [String] {
    let words = [
        "river", "stone", "harbor", "lantern", "meadow", "copper", "falcon", "orchard",
        "glacier", "thunder", "velvet", "canyon", "ember", "willow", "summit", "tide",
    ]
    return (0..<count).map { index in
        let length = 3 + index % 5
        let picked = (0..<length).map { words[(index * 7 + $0 * (index % 3 + 1)) % words.count] }
        // Every 9th passage repeats an earlier one word for word, so BM25 ties are common.
        return index % 9 == 0 && index > 0 ? "falcon over the river and the stone" : picked.joined(separator: " ")
    }
}

private let queries = [
    "\"river\" OR \"stone\" OR \"falcon\"",
    "\"lantern\" OR \"meadow\" OR \"copper\" OR \"orchard\" OR \"tide\"",
    "\"river\" \"stone\"",
    "\"falcon\"",
    "\"glacier\" OR \"nomatchword\"",
    "\"nomatchword\"",
    "\"falcon over the river\" OR \"summit\"",
]

private func engine(docs: Int, fanOut: FTS5SearchEngine.SearchFanOut) async throws -> FTS5SearchEngine {
    let source = try FTS5SearchEngine.inMemory()
    let texts = corpus(count: docs)
    // Odd, non-monotone frame ids so frame-id tie-breaks differ from rowid order.
    let frameIds = (0..<UInt64(docs)).map { ($0 * 7_919) % 100_003 + 1 }
    try await source.indexBatch(frameIds: frameIds, texts: texts)
    return try FTS5SearchEngine.deserialize(from: try await source.serialize(), searchFanOut: fanOut)
}

@Test
func largeIndexSplitsOneMatchAcrossReaderConnections() async throws {
    // Root cause of the 100k hybrid tail: an OR fallback matching most of the corpus
    // was scored on the single serial connection, so it took as long as BM25 over
    // every matching row and the structured lane queued behind it.
    let fanned = try await engine(docs: 400, fanOut: .init(minDocsPerPartition: 100, maxPartitions: 4))

    _ = try await fanned.search(matchQuery: queries[0], topK: 30)

    #expect(await fanned.lastSearchPartitionCountForTesting() == 4)
}

@Test
func smallIndexKeepsOneConnection() async throws {
    let small = try await engine(docs: 150, fanOut: .init(minDocsPerPartition: 100, maxPartitions: 4))
    _ = try await small.search(matchQuery: queries[0], topK: 30)
    #expect(await small.lastSearchPartitionCountForTesting() == 1)

    let inMemory = try FTS5SearchEngine.inMemory()
    try await inMemory.indexBatch(frameIds: [1, 2], texts: ["river stone", "stone falcon"])
    _ = try await inMemory.search(matchQuery: queries[0], topK: 30)
    #expect(await inMemory.lastSearchPartitionCountForTesting() == 1)
}

@Test
func partitionedSearchReturnsTheSingleConnectionResults() async throws {
    let single = try await engine(docs: 400, fanOut: .disabled)
    let fanned = try await engine(docs: 400, fanOut: .init(minDocsPerPartition: 50, maxPartitions: 4))

    for query in queries {
        for topK in [1, 3, 10, 30, 90, 1_000] {
            let expected = try await single.search(matchQuery: query, topK: topK)
            let actual = try await fanned.search(matchQuery: query, topK: topK)
            #expect(actual == expected, "query \(query) topK \(topK)")
        }
    }
    #expect(await fanned.lastSearchPartitionCountForTesting() == 4)
    #expect(await single.lastSearchPartitionCountForTesting() == 1)
}

@Test
func partitionedSearchSeesWritesMadeBeforeIt() async throws {
    let fanned = try await engine(docs: 400, fanOut: .init(minDocsPerPartition: 50, maxPartitions: 4))
    let before = try await fanned.search(matchQuery: "\"zeppelin\"", topK: 10)
    #expect(before.isEmpty)

    try await fanned.index(frameId: 500_000, text: "a zeppelin over the harbor")
    try await fanned.remove(frameId: 1)
    let added = try await fanned.search(matchQuery: "\"zeppelin\"", topK: 10)
    #expect(added.map(\.frameId) == [500_000])
    let all = try await fanned.search(matchQuery: queries[0], topK: 1_000)
    #expect(!all.contains { $0.frameId == 1 })
}

@Test
func partitionedSearchNeverMixesSnapshotsWithConcurrentWrites() async throws {
    let fanned = try await engine(docs: 400, fanOut: .init(minDocsPerPartition: 50, maxPartitions: 4))
    let frameIds = (0..<UInt64(400)).map { ($0 * 7_919) % 100_003 + 1 }

    try await withThrowingTaskGroup(of: [TextSearchResult].self) { group in
        group.addTask {
            // Re-index existing frames: each upsert deletes the old row and inserts a new
            // rowid, so a search straddling the write could see one frame twice.
            for (round, frameId) in frameIds.prefix(120).enumerated() {
                try await fanned.index(frameId: frameId, text: "river stone falcon round \(round)")
                try await fanned.flushPendingOpsIfNeeded()
            }
            return []
        }
        for _ in 0..<40 {
            group.addTask { try await fanned.search(matchQuery: queries[0], topK: 1_000) }
        }
        for try await results in group {
            let ids = results.map(\.frameId)
            #expect(Set(ids).count == ids.count)
        }
    }
}
