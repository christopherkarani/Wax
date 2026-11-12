import Foundation
import Testing
import Wax
import WaxCore
import WaxTestSupport

/// `importDocuments(_:)` must store what `save(contentsOf:)` stores and return the same IDs,
/// as one atomic commit.
private enum Import {
    static let dimensions = 16
    typealias Document = (text: String, metadata: [String: String])

    static func config() -> Memory.Config {
        Memory.Config(embedding: .custom(SeededHashEmbedder(dimensions: dimensions)))
    }

    static func passage(_ index: Int) -> String {
        "Import passage \(index) about topic \(index % 7) and detail \(index * 31 % 101)."
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

    static func queries() -> [String] {
        [passage(0), passage(2), passage(4), stored.text, "term17y17 term18y18", "topic 3 detail"]
    }

    struct Hit: Equatable {
        let frameId: UInt64
        let text: String
    }

    static func hits(_ memory: Memory, _ query: String, mode: Memory.RetrievalMode) async throws -> [Hit] {
        let results = try await memory.search(query, options: .init(topK: 5, mode: mode))
        return results.items.map { Hit(frameId: $0.frameId, text: $0.text) }
    }

    static func allHits(_ memory: Memory, modes: [Memory.RetrievalMode]) async throws -> [[Hit]] {
        var all: [[Hit]] = []
        for query in queries() {
            for mode in modes {
                all.append(try await hits(memory, query, mode: mode))
            }
        }
        return all
    }

    static let allModes: [Memory.RetrievalMode] = [.textOnly, .vectorOnly, .hybrid()]

    /// The store's frames without what differs between two writes of the same content:
    /// write time and where the payload landed.
    static func comparableFrames(at url: URL) async throws -> [FrameMeta] {
        let wax = try await Wax.open(at: url)
        let frames = await wax.frameMetas()
        try await wax.close()
        return frames.map { frame in
            var frame = frame
            frame.timestamp = 0
            frame.payloadOffset = 0
            return frame
        }
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Fails every embedding call after the first `allowedCalls`.
private actor FailingAfterEmbedder: EmbeddingProvider {
    nonisolated let dimensions: Int
    nonisolated let normalize = true
    nonisolated let identity: EmbeddingIdentity?
    private let base: SeededHashEmbedder
    private var allowedCalls: Int

    init(dimensions: Int, allowedCalls: Int) {
        base = SeededHashEmbedder(dimensions: dimensions)
        self.dimensions = dimensions
        identity = base.identity
        self.allowedCalls = allowedCalls
    }

    func allow(_ calls: Int) { allowedCalls = calls }

    func embed(_ text: String) async throws -> [Float] {
        try await embed(batch: [text])[0]
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        guard allowedCalls > 0 else { throw WaxError.io("embedder failed on purpose") }
        allowedCalls -= 1
        var vectors: [[Float]] = []
        for text in texts {
            vectors.append(try await base.embed(text))
        }
        return vectors
    }
}

/// Holds embedding calls for texts containing `marker` until `release()`.
private actor GatedEmbedder: EmbeddingProvider {
    nonisolated let dimensions: Int
    nonisolated let normalize = true
    nonisolated let identity: EmbeddingIdentity?
    private let base: SeededHashEmbedder
    private let marker: String
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkedObservers: [CheckedContinuation<Void, Never>] = []

    init(dimensions: Int, marker: String) {
        base = SeededHashEmbedder(dimensions: dimensions)
        self.dimensions = dimensions
        identity = base.identity
        self.marker = marker
    }

    func waitUntilParked() async {
        guard parked.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parkedObservers.append(continuation)
        }
    }

    func release() {
        released = true
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }

    func embed(_ text: String) async throws -> [Float] {
        try await embed(batch: [text])[0]
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        if !released, texts.contains(where: { $0.contains(marker) }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parked.append(continuation)
                let observers = parkedObservers
                parkedObservers = []
                for observer in observers { observer.resume() }
            }
        }
        var vectors: [[Float]] = []
        for text in texts {
            vectors.append(try await base.embed(text))
        }
        return vectors
    }
}

/// Counts provider calls so a test can tell batched embedding from one call per text.
private actor CallCountingEmbedder: EmbeddingProvider {
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

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

@Test func importDocumentsStoresWhatSaveContentsOfStores() async throws {
    try await TempFiles.withTempFile { savedURL in
        try await TempFiles.withTempFile { importedURL in
            let batch = Import.mixedBatch()

            let saved = try await Memory(at: savedURL, config: Import.config())
            let storedSaved = try await saved.save(Import.stored.text, metadata: Import.stored.metadata)
            let expected = try await saved.save(contentsOf: batch)

            let imported = try await Memory(at: importedURL, config: Import.config())
            let storedImported = try await imported.save(Import.stored.text, metadata: Import.stored.metadata)
            let ids = try await imported.importDocuments(batch)

            #expect(storedImported == storedSaved)
            #expect(ids == expected)
            #expect(ids[5] == ids[0])
            #expect(ids[7] == storedImported)
            #expect(ids[9] == ids[2])
            #expect(ids[6] != ids[0])

            // Committed by the import itself: no flush needed for stats to count the frames.
            let importedStats = await imported.stats()
            #expect(importedStats.pendingFrames == 0)
            try await saved.flush()
            let savedStats = await saved.stats()
            #expect(importedStats.frameCount == savedStats.frameCount)
            #expect(importedStats.framesWithoutVectors == savedStats.framesWithoutVectors)
            #expect(importedStats.framesWithoutVectors == 0)

            let want = try await Import.allHits(saved, modes: Import.allModes)
            let got = try await Import.allHits(imported, modes: Import.allModes)
            #expect(got == want)
            #expect(got.allSatisfy { !$0.isEmpty })
            try await saved.close()
            try await imported.close()

            #expect(try await Import.comparableFrames(at: importedURL) == Import.comparableFrames(at: savedURL))

            let savedReopened = try await Memory(at: savedURL, config: Import.config())
            let importedReopened = try await Memory(at: importedURL, config: Import.config())
            #expect(try await Import.allHits(importedReopened, modes: Import.allModes)
                == Import.allHits(savedReopened, modes: Import.allModes))
            #expect(await importedReopened.stats().framesWithoutVectors == 0)
            try await savedReopened.close()
            try await importedReopened.close()
        }
    }
}

@Test func importDocumentsTextOnlyStoresWhatSaveContentsOfStores() async throws {
    try await TempFiles.withTempFile { savedURL in
        try await TempFiles.withTempFile { importedURL in
            let batch = Import.mixedBatch()
            let config = Memory.Config(enableVectorSearch: false)

            let saved = try await Memory(at: savedURL, config: config)
            _ = try await saved.save(Import.stored.text, metadata: Import.stored.metadata)
            let expected = try await saved.save(contentsOf: batch)
            let imported = try await Memory(at: importedURL, config: config)
            _ = try await imported.save(Import.stored.text, metadata: Import.stored.metadata)
            let ids = try await imported.importDocuments(batch)

            #expect(ids == expected)
            let want = try await Import.allHits(saved, modes: [.textOnly])
            let got = try await Import.allHits(imported, modes: [.textOnly])
            #expect(got == want)
            #expect(got.allSatisfy { !$0.isEmpty })
            try await saved.close()
            try await imported.close()
            #expect(try await Import.comparableFrames(at: importedURL) == Import.comparableFrames(at: savedURL))
        }
    }
}

@Test func importDocumentsThatThrowsLeavesTheStoreAsItWas() async throws {
    try await TempFiles.withTempFile { url in
        // One call for the stored note, then 40 of 32 texts: the first 1,024-document window
        // is embedded and written into the import before a call in the second one fails.
        let embedder = FailingAfterEmbedder(dimensions: Import.dimensions, allowedCalls: 41)
        let config = Memory.Config(embedding: .custom(embedder))
        let memory = try await Memory(at: url, config: config)
        let storedId = try await memory.save(Import.stored.text, metadata: Import.stored.metadata)
        try await memory.flush()
        let sizeBefore = try Import.fileSize(url)

        let documents: [Import.Document] = (0..<2_000).map { (Import.passage($0), ["row": String($0)]) }
        await #expect(throws: (any Error).self) {
            _ = try await memory.importDocuments(documents)
        }

        await embedder.allow(.max)
        let stats = await memory.stats()
        #expect(stats.frameCount == 1)
        #expect(stats.pendingFrames == 0)
        for mode: Memory.RetrievalMode in [.textOnly, .vectorOnly, .hybrid()] {
            let results = try await memory.search(Import.passage(3), options: .init(topK: 5, mode: mode))
            #expect(results.items.allSatisfy { $0.frameId == storedId }, "mode \(mode)")
        }
        try await memory.close()

        let reopened = try await Memory(at: url, config: config)
        #expect(await reopened.stats().frameCount == 1)
        let ids = try await reopened.importDocuments(documents)
        #expect(ids == (1...UInt64(documents.count)).map { $0 })
        let hit = try await reopened.search(Import.passage(1_234), options: .init(topK: 1, mode: .vectorOnly))
        #expect(hit.items.first?.frameId == ids[1_234])
        try await reopened.close()

        // The failed import's space was reused, not left behind.
        try await TempFiles.withTempFile { freshURL in
            let fresh = try await Memory(at: freshURL, config: config)
            _ = try await fresh.save(Import.stored.text, metadata: Import.stored.metadata)
            try await fresh.flush()
            _ = try await fresh.importDocuments(documents)
            try await fresh.close()
            #expect(try Import.fileSize(url) <= Import.fileSize(freshURL) + 256 * 1024)
        }
        #expect(sizeBefore > 0)
    }
}

@Test func savesWaitForAnImportAndSearchesSeeTheStoreBeforeIt() async throws {
    try await TempFiles.withTempFile { url in
        let marker = "zebracrossing"
        let embedder = GatedEmbedder(dimensions: Import.dimensions, marker: marker)
        let memory = try await Memory(at: url, config: Memory.Config(embedding: .custom(embedder)))
        let seedId = try await memory.save("Seed note about lighthouses.")

        let documents: [Import.Document] = (0..<50).map { ("\(marker) \(Import.passage($0))", ["row": String($0)]) }
        let importTask = Task { () async throws -> [UInt64] in
            try await memory.importDocuments(documents)
        }
        await embedder.waitUntilParked()

        let saveDone = Flag()
        let saveTask = Task { () async throws -> UInt64 in
            let id = try await memory.save("Concurrent note about harbours.")
            await saveDone.set()
            return id
        }
        let flushTask = Task { () async throws -> Void in
            try await memory.flush()
        }

        // Searches run while the import is open, against the store as it was.
        let during = try await memory.search(marker, options: .init(topK: 5, mode: .textOnly))
        #expect(during.items.isEmpty)
        let seed = try await memory.search("lighthouses", options: .init(topK: 5, mode: .textOnly))
        #expect(seed.items.first?.frameId == seedId)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await saveDone.isSet == false, "the save waits for the import")
        #expect(await memory.stats().frameCount == 1)

        await embedder.release()
        let ids = try await importTask.value
        let saveId = try await saveTask.value
        try await flushTask.value
        #expect(ids == (1...UInt64(documents.count)).map { $0 })
        #expect(saveId == UInt64(documents.count) + 1, "the save ran after the import")

        try await memory.flush()
        let after = try await memory.search(marker, options: .init(topK: 5, mode: .textOnly))
        #expect(after.items.count == 5)
        let harbour = try await memory.search("harbours", options: .init(topK: 1, mode: .textOnly))
        #expect(harbour.items.first?.frameId == saveId)
        try await memory.close()
    }
}

@Test func importDocumentsEmbedsInBatchedProviderCalls() async throws {
    try await TempFiles.withTempFile { url in
        let embedder = CallCountingEmbedder(dimensions: Import.dimensions)
        let memory = try await Memory(at: url, config: Memory.Config(embedding: .custom(embedder)))
        let callsBefore = await embedder.batchCalls
        let ids = try await memory.importDocuments((0..<100).map { (Import.passage($0), [String: String]()) })
        #expect(Set(ids).count == 100)
        #expect(await embedder.textsEmbedded == 100)
        // Default ingestBatchSize is 32: four provider calls, not one per text.
        #expect(await embedder.batchCalls - callsBefore == 4)
        #expect(await memory.stats().framesWithoutVectors == 0)
        try await memory.close()
    }
}

@Test func importDocumentsPastWalCapacityCommitsOnceAndSurvivesReopen() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url, walSize: 64 * 1024)
        try await wax.close()
        let count = 1_500
        let documents: [Import.Document] = (0..<count).map { (Import.passage($0), ["row": String($0)]) }

        let memory = try await Memory(at: url, config: Import.config())
        let ids = try await memory.importDocuments(documents)
        #expect(ids == (0..<UInt64(count)).map { $0 })
        // Saving the same documents again finds every imported one.
        let again = try await memory.save(contentsOf: documents)
        #expect(again == ids)
        #expect(await memory.stats().pendingFrames == 0)
        try await memory.close()

        let reopened = try await Memory(at: url, config: Import.config())
        let stats = await reopened.stats()
        #expect(stats.frameCount == UInt64(count))
        #expect(stats.framesWithoutVectors == 0)
        for index in [0, 1, count / 2, count - 1] {
            for mode: Memory.RetrievalMode in [.vectorOnly, .textOnly] {
                let results = try await reopened.search(Import.passage(index), options: .init(topK: 1, mode: mode))
                #expect(results.items.first?.frameId == ids[index])
                #expect(results.items.first?.metadata["row"] == String(index))
            }
        }
        #expect(try await reopened.importDocuments(documents) == ids)
        try await reopened.close()
    }
}

@Test func importDocumentsOfNothingWritesNothing() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: Import.config())
        #expect(try await memory.importDocuments([Import.Document]()).isEmpty)
        #expect(await memory.stats().frameCount == 0)
        try await memory.close()
    }
}

/// Cancelling an import, even after its first window's text was indexed, never commits
/// frames whose text is missing from the text index: it either throws and leaves the store
/// as it was, or commits with every frame's text searchable.
@Test(.timeLimit(.minutes(1)))
func aCancelledImportNeverCommitsFramesWithoutTheirText() async throws {
    try await TempFiles.withTempFile { url in
        let marker = "quokkaferry"
        let embedder = GatedEmbedder(dimensions: Import.dimensions, marker: marker)
        let memory = try await Memory(at: url, config: Memory.Config(embedding: .custom(embedder)))
        let seedId = try await memory.save("Seed note about lighthouses.")
        try await memory.flush()

        // The first 1,024-document window is written and its text indexed; the second
        // window's embedding parks until the import task is cancelled.
        let tailCount = 76
        var documents: [Import.Document] = []
        for index in 0..<1_024 {
            documents.append((Import.passage(index), ["row": String(index)]))
        }
        for index in 0..<tailCount {
            documents.append(("\(marker) \(Import.passage(1_024 + index))", ["row": String(1_024 + index)]))
        }
        let batch = documents
        let importTask = Task { () async throws -> [UInt64] in
            try await memory.importDocuments(batch)
        }
        await embedder.waitUntilParked()
        importTask.cancel()
        await embedder.release()
        let outcome: Result<[UInt64], any Error> = await importTask.result

        let frameCount = await memory.stats().frameCount
        let tail = try await memory.search(marker, options: .init(topK: 200, mode: .textOnly))
        switch outcome {
        case .success(let ids):
            #expect(ids.count == documents.count)
            #expect(tail.items.count == tailCount, "every committed tail frame is text-searchable")
        case .failure:
            #expect(frameCount == 1, "a failed import leaves the store as it was")
            #expect(tail.items.isEmpty)
            let seed = try await memory.search("lighthouses", options: .init(topK: 5, mode: .textOnly))
            #expect(seed.items.first?.frameId == seedId)
        }
        try await memory.close()
    }
}

/// A text-only import made from a cancelled task embeds nothing that would notice the
/// cancellation; it still never commits frames whose text is not indexed.
@Test(.timeLimit(.minutes(1)))
func aTextOnlyImportFromACancelledTaskNeverCommitsFramesWithoutTheirText() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: Memory.Config(enableVectorSearch: false))
        _ = try await memory.save("Seed note about lighthouses.")
        try await memory.flush()

        let marker = "quokkaferry"
        let count = 1_100
        var documents: [Import.Document] = []
        for index in 0..<count {
            documents.append(("\(marker) \(Import.passage(index))", ["row": String(index)]))
        }
        let batch = documents
        let importTask = Task { () async throws -> [UInt64] in
            withUnsafeCurrentTask { (task: UnsafeCurrentTask?) in task?.cancel() }
            return try await memory.importDocuments(batch)
        }
        let outcome: Result<[UInt64], any Error> = await importTask.result

        let frameCount = await memory.stats().frameCount
        let hits = try await memory.search(marker, options: .init(topK: 2_000, mode: .textOnly))
        switch outcome {
        case .success:
            #expect(hits.items.count == count, "every committed frame is text-searchable")
        case .failure:
            #expect(frameCount == 1, "a failed import leaves the store as it was")
            #expect(hits.items.isEmpty)
        }
        try await memory.close()
    }
}
