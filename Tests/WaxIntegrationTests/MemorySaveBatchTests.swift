import Foundation
import Testing
import Wax
import WaxCore
import WaxTestSupport

/// `save(contentsOf:)` must return what a loop of `save(_:metadata:)` would, and leave the
/// store searchable the same way.
private enum SaveBatch {
    static let dimensions = 16
    typealias Document = (text: String, metadata: [String: String])

    static func config() -> Memory.Config {
        Memory.Config(embedding: .custom(SeededHashEmbedder(dimensions: dimensions)))
    }

    static func textOnlyConfig() -> Memory.Config {
        Memory.Config(enableVectorSearch: false)
    }

    static func passage(_ index: Int) -> String {
        "Batch passage \(index) about topic \(index % 7) and detail \(index * 31 % 101)."
    }

    /// Long enough to be cut into several chunks under the default chunking.
    static func longDocument() -> String {
        (0..<1_500).map { "term\($0 % 211)y\($0)" }.joined(separator: " ")
    }

    static let stored: Document = ("Already stored note about bananas and ladders.", ["source": "seed"])

    /// Single-chunk, multi-chunk, empty, duplicates in the batch, a duplicate of a stored
    /// document and metadata variants, interleaved.
    static func mixedBatch() -> [Document] {
        [
            (passage(0), [:]),
            (passage(1), ["row": "1"]),
            (longDocument(), ["kind": "long"]),
            (passage(2), [:]),
            ("", [:]),
            (passage(0), [:]),
            (passage(0), ["row": "0"]),
            (stored.text, stored.metadata),
            (passage(3), ["row": "3"]),
            (longDocument(), ["kind": "long"]),
            (passage(1), ["row": "1"]),
            ("", ["row": "empty"]),
            (passage(4), [:]),
        ]
    }

    static func saveSequentially(_ documents: [Document], into memory: Memory) async throws -> [UInt64] {
        var ids: [UInt64] = []
        for document in documents {
            ids.append(try await memory.save(document.text, metadata: document.metadata))
        }
        return ids
    }

    struct Hit: Equatable {
        let frameId: UInt64
        let text: String
    }

    static func hits(
        _ memory: Memory,
        _ query: String,
        mode: Memory.RetrievalMode
    ) async throws -> [Hit] {
        let results = try await memory.search(query, options: .init(topK: 5, mode: mode))
        return results.items.map { Hit(frameId: $0.frameId, text: $0.text) }
    }

    /// Stats count committed frames only, so flush first.
    static func flushedStats(_ memory: Memory) async throws -> Memory.Stats {
        try await memory.flush()
        return await memory.stats()
    }

    static func queries() -> [String] {
        [passage(0), passage(2), passage(4), stored.text, "term17y17 term18y18"]
    }
}

/// Counts provider calls so a test can tell batched embedding from one call per text.
private actor BatchCallCountingEmbedder: EmbeddingProvider {
    nonisolated let dimensions: Int
    nonisolated let normalize = true
    nonisolated let identity: EmbeddingIdentity?
    private let base: SeededHashEmbedder
    private(set) var batchCalls = 0
    private(set) var textsEmbedded = 0

    init(dimensions: Int) {
        base = SeededHashEmbedder(dimensions: dimensions)
        self.dimensions = dimensions
        identity = base.identity
    }

    func embed(_ text: String) async throws -> [Float] {
        try await embed(batch: [text])[0]
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        batchCalls += 1
        textsEmbedded += texts.count
        var vectors: [[Float]] = []
        for text in texts {
            vectors.append(try await base.embed(text))
        }
        return vectors
    }
}

@Test func memorySaveContentsOfMatchesSequentialSaves() async throws {
    try await TempFiles.withTempFile { sequentialURL in
        try await TempFiles.withTempFile { batchURL in
            let batch = SaveBatch.mixedBatch()

            let sequential = try await Memory(at: sequentialURL, config: SaveBatch.config())
            let storedSequential = try await sequential.save(SaveBatch.stored.text, metadata: SaveBatch.stored.metadata)
            let expected = try await SaveBatch.saveSequentially(batch, into: sequential)

            let batched = try await Memory(at: batchURL, config: SaveBatch.config())
            let storedBatched = try await batched.save(SaveBatch.stored.text, metadata: SaveBatch.stored.metadata)
            let ids = try await batched.save(contentsOf: batch)

            #expect(storedBatched == storedSequential)
            #expect(ids == expected)
            #expect(ids[5] == ids[0])
            #expect(ids[7] == storedBatched)
            #expect(ids[9] == ids[2])
            #expect(ids[10] == ids[1])
            #expect(ids[6] != ids[0])

            let sequentialStats = try await SaveBatch.flushedStats(sequential)
            let batchedStats = try await SaveBatch.flushedStats(batched)
            #expect(batchedStats.frameCount > 0)
            #expect(batchedStats.frameCount == sequentialStats.frameCount)
            #expect(batchedStats.framesWithoutVectors == sequentialStats.framesWithoutVectors)

            for query in SaveBatch.queries() {
                for mode: Memory.RetrievalMode in [.textOnly, .vectorOnly, .hybrid()] {
                    let want = try await SaveBatch.hits(sequential, query, mode: mode)
                    let got = try await SaveBatch.hits(batched, query, mode: mode)
                    #expect(got == want, "query \(query) mode \(mode)")
                }
            }
            try await sequential.close()
            try await batched.close()
        }
    }
}

@Test func memorySaveContentsOfTextsSharesMetadata() async throws {
    try await TempFiles.withTempFile { sequentialURL in
        try await TempFiles.withTempFile { batchURL in
            let texts = [SaveBatch.passage(10), SaveBatch.passage(11), SaveBatch.passage(10), ""]
            let metadata = ["source": "import"]

            let sequential = try await Memory(at: sequentialURL, config: SaveBatch.config())
            let expected = try await SaveBatch.saveSequentially(
                texts.map { ($0, metadata) },
                into: sequential
            )
            let batched = try await Memory(at: batchURL, config: SaveBatch.config())
            let ids = try await batched.save(contentsOf: texts, metadata: metadata)

            #expect(ids == expected)
            let hit = try await batched.search(SaveBatch.passage(11), options: .init(topK: 1, mode: .vectorOnly))
            #expect(hit.items.first?.frameId == ids[1])
            #expect(hit.items.first?.metadata["source"] == "import")
            try await sequential.close()
            try await batched.close()
        }
    }
}

@Test func memorySaveContentsOfEmptySequenceSavesNothing() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: SaveBatch.config())
        let ids = try await memory.save(contentsOf: [String]())
        #expect(ids.isEmpty)
        #expect(await memory.stats().frameCount == 0)
        try await memory.close()
    }
}

@Test func memorySaveContentsOfTextOnlyMatchesSequentialSaves() async throws {
    try await TempFiles.withTempFile { sequentialURL in
        try await TempFiles.withTempFile { batchURL in
            let batch = SaveBatch.mixedBatch()

            let sequential = try await Memory(at: sequentialURL, config: SaveBatch.textOnlyConfig())
            _ = try await sequential.save(SaveBatch.stored.text, metadata: SaveBatch.stored.metadata)
            let expected = try await SaveBatch.saveSequentially(batch, into: sequential)

            let batched = try await Memory(at: batchURL, config: SaveBatch.textOnlyConfig())
            _ = try await batched.save(SaveBatch.stored.text, metadata: SaveBatch.stored.metadata)
            let ids = try await batched.save(contentsOf: batch)

            #expect(ids == expected)
            let sequentialFrames = try await SaveBatch.flushedStats(sequential).frameCount
            #expect(sequentialFrames > 0)
            #expect(try await SaveBatch.flushedStats(batched).frameCount == sequentialFrames)
            for query in SaveBatch.queries() {
                let want = try await SaveBatch.hits(sequential, query, mode: .textOnly)
                let got = try await SaveBatch.hits(batched, query, mode: .textOnly)
                #expect(!got.isEmpty)
                #expect(got == want, "query \(query)")
            }
            try await sequential.close()
            try await batched.close()
        }
    }
}

@Test func memorySaveContentsOfEmbedsInBatchedProviderCalls() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = BatchCallCountingEmbedder(dimensions: SaveBatch.dimensions)
        let memory = try await Memory(at: url, config: Memory.Config(embedding: .custom(embedder)))
        let callsBefore = await embedder.batchCalls
        let textsBefore = await embedder.textsEmbedded

        let count = 100
        let ids = try await memory.save(contentsOf: (0..<count).map(SaveBatch.passage))

        #expect(Set(ids).count == count)
        #expect(await embedder.textsEmbedded - textsBefore == count)
        // Default ingestBatchSize is 32: four provider calls, not one per text.
        #expect(await embedder.batchCalls - callsBefore == 4)
        #expect(try await SaveBatch.flushedStats(memory).framesWithoutVectors == 0)
        try await memory.close()
    }
}

@Test func memorySaveContentsOfPastWalCapacitySurvivesReopen() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url, walSize: 64 * 1024)
        try await wax.close()
        let count = 1_200

        let memory = try await Memory(at: url, config: SaveBatch.config())
        let ids = try await memory.save(contentsOf: (0..<count).map { (SaveBatch.passage($0), ["row": String($0)]) })
        #expect(Set(ids).count == count)
        try await memory.close()

        let reopened = try await Memory(at: url, config: SaveBatch.config())
        let stats = await reopened.stats()
        #expect(stats.frameCount == UInt64(count))
        #expect(stats.pendingFrames == 0)
        #expect(stats.framesWithoutVectors == 0)
        for index in [0, 1, count / 2, count - 1] {
            for mode: Memory.RetrievalMode in [.vectorOnly, .textOnly] {
                let results = try await reopened.search(
                    SaveBatch.passage(index),
                    options: .init(topK: 1, mode: mode)
                )
                #expect(results.items.first?.frameId == ids[index])
                #expect(results.items.first?.metadata["row"] == String(index))
            }
        }
        try await reopened.close()
    }
}

@Test func memorySaveAfterSaveContentsOfIsDeduplicated() async throws {
    try await TempFiles.withTempFile { url in
        let batch = SaveBatch.mixedBatch()
        let memory = try await Memory(at: url, config: SaveBatch.config())
        let ids = try await memory.save(contentsOf: batch)
        let framesAfterBatch = try await SaveBatch.flushedStats(memory).frameCount
        #expect(framesAfterBatch > 0)

        let again = try await SaveBatch.saveSequentially(batch, into: memory)
        #expect(again == ids)
        #expect(try await SaveBatch.flushedStats(memory).frameCount == framesAfterBatch)
        try await memory.close()

        let reopened = try await Memory(at: url, config: SaveBatch.config())
        let afterReopen = try await SaveBatch.saveSequentially(batch, into: reopened)
        #expect(afterReopen == ids)
        let stats = await reopened.stats()
        #expect(stats.frameCount == framesAfterBatch)
        #expect(stats.framesWithoutVectors == 0)
        try await reopened.close()
    }
}
