import Foundation
import Testing
import Wax
import WaxCore
import WaxVectorSearch

/// One-hot keyword vectors. `rotation` moves every keyword to another axis, so two
/// rotations model two vector spaces that are unrelated to each other.
private struct KeywordEmbedder: EmbeddingProvider, Sendable {
    static let keywords = ["apple", "banana", "cherry", "durian"]

    let dimensions: Int
    let normalize = true
    let identity: EmbeddingIdentity?
    let rotation: Int
    let failAfterCalls: Int?
    let calls: CallCounter

    init(model: String, rotation: Int, dimensions: Int = 4, failAfterCalls: Int? = nil) {
        self.dimensions = dimensions
        self.identity = EmbeddingIdentity(provider: "Wax", model: model, dimensions: dimensions, normalized: true)
        self.rotation = rotation
        self.failAfterCalls = failAfterCalls
        self.calls = CallCounter()
    }

    func embed(_ text: String) async throws -> [Float] {
        let call = await calls.next()
        if let failAfterCalls, call > failAfterCalls {
            throw WaxError.io("simulated embedder crash")
        }
        let lowered = text.lowercased()
        let axis = Self.keywords.firstIndex { lowered.contains($0) } ?? 3
        var vector = [Float](repeating: 0, count: dimensions)
        vector[(axis + rotation) % dimensions] = 1
        return vector
    }
}

private actor CallCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private enum Fixture {
    static let documents = [
        "apple pie recipe from grandma",
        "banana bread baking notes",
        "cherry tart planning list",
    ]
    static let reason = "vectors from superseded MiniLM revision"
    static let progressKind = "wax.internal.reembed_progress"

    static func config(
        autoReembed: Bool = false,
        checkpointFrames: Int? = nil,
        targetTokens: Int = 32
    ) -> OrchestratorConfig {
        var config = TestHelpers.defaultMemoryConfig(vector: true)
        config.chunking = .tokenCount(targetTokens: targetTokens, overlapTokens: 0)
        config.ingestBatchSize = 1
        config.automaticallyReembedSupersededVectors = autoReembed
        config.supersededReembedCheckpointFrames = checkpointFrames
        return config
    }

    static func legacy() -> KeywordEmbedder {
        KeywordEmbedder(model: "MiniLMAll", rotation: 0)
    }

    static func current(failAfterCalls: Int? = nil) -> KeywordEmbedder {
        KeywordEmbedder(model: "MiniLMAll-mean", rotation: 2, failAfterCalls: failAfterCalls)
    }

    /// A store written by the pre-#257 MiniLM identity, in vector space `rotation: 0`.
    static func writeLegacyStore(
        at url: URL,
        documents: [String] = documents,
        config: OrchestratorConfig = config(),
        legacy: KeywordEmbedder = legacy()
    ) async throws {
        let writer = try await MemoryOrchestrator(at: url, config: config, embedder: legacy)
        for document in documents {
            try await writer.remember(document)
        }
        try await writer.flush()
        try await writer.close()
    }

    static func boundModel(at url: URL) async throws -> String? {
        let wax = try await Wax.open(at: url)
        let model = await wax.memoryBinding()?.embeddingModel
        try await wax.close()
        return model
    }

    static func activeProgressMarkers(at url: URL) async throws -> Int {
        let wax = try await Wax.open(at: url)
        let markers = await wax.frameMetas().filter {
            $0.kind == progressKind && $0.status == .active && $0.supersededBy == nil
        }
        try await wax.close()
        return markers.count
    }

    static func expectVectorHits(_ memory: MemoryOrchestrator, keywords: [String] = ["apple", "banana", "cherry"]) async throws {
        for keyword in keywords {
            let vector = try await memory.searchExecution(query: keyword, mode: .vectorOnly, topK: 1)
            #expect(vector.queryEmbeddingState == .available)
            #expect(vector.hits.first?.previewText?.contains(keyword) == true, "vector hit for \(keyword)")
        }
    }

    static func waitUntilReembedded(_ memory: MemoryOrchestrator) async throws {
        var polls = 0
        while await memory.runtimeStats().vectorsNeedReembed, polls < 1_000 {
            polls += 1
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Test func supersededMiniLMStoreServesTextOnlyUntilReembedSwapsBinding() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        let before = await memory.runtimeStats()
        #expect(before.vectorsNeedReembed)
        #expect(before.embeddingStatus == .degraded(Fixture.current().identity, reason: Fixture.reason))

        // Stale vectors are excluded: hybrid degrades to text, vector-only throws a typed error.
        let hybrid = try await memory.searchExecution(query: "apple", mode: .hybrid(), topK: 3)
        #expect(hybrid.queryEmbeddingState == .vectorsRebuilding)
        #expect(hybrid.effectiveMode == .textOnly)
        #expect(hybrid.hits.first?.previewText?.contains("apple") == true)
        do {
            _ = try await memory.searchExecution(query: "apple", mode: .vectorOnly, topK: 1)
            Issue.record("vector-only search must refuse superseded vectors")
        } catch let WaxError.vectorsRebuilding(reason, progress) {
            #expect(reason == Fixture.reason)
            #expect(progress == 0)
        }

        let reembedded = try await memory.backfillUnembedded()
        #expect(reembedded == UInt64(Fixture.documents.count))
        let after = await memory.runtimeStats()
        #expect(!after.vectorsNeedReembed)
        #expect(after.embeddingStatus == .active(Fixture.current().identity))
        // Every stale vector was overwritten: each keyword finds its own document.
        try await Fixture.expectVectorHits(memory)
        try await memory.close()

        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
        #expect(try await Fixture.activeProgressMarkers(at: url) == 0)
        let reopened = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        #expect(!(await reopened.runtimeStats().vectorsNeedReembed))
        try await reopened.close()
    }
}

@Test func readOnlyHostOnStaleStoreNeverStartsReembed() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(autoReembed: false), embedder: Fixture.current())
        _ = try await memory.searchExecution(query: "apple", mode: .hybrid(), topK: 3)
        _ = try? await memory.searchExecution(query: "banana", mode: .vectorOnly, topK: 1)
        _ = await memory.runtimeStats()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await memory.runtimeStats().vectorsNeedReembed)
        try await memory.close()

        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll")
        #expect(try await Fixture.activeProgressMarkers(at: url) == 0)
    }
}

@Test func supersededMiniLMStoreReembedsAutomaticallyFromInit() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        // An app that only remembers never searches; opening alone must start the re-embed.
        let memory = try await MemoryOrchestrator(
            at: url,
            config: Fixture.config(autoReembed: true),
            embedder: Fixture.current()
        )
        try await memory.remember("durian smoothie idea")
        try await Fixture.waitUntilReembedded(memory)
        #expect(!(await memory.runtimeStats().vectorsNeedReembed))
        try await Fixture.expectVectorHits(memory, keywords: ["apple", "banana", "cherry", "durian"])
        try await memory.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func interruptedReembedResumesFromCommittedMarker() async throws {
    try await TempFiles.withTempFile { url in
        let documents = Fixture.documents + ["apple cider", "banana split", "cherry jam"]
        try await Fixture.writeLegacyStore(at: url, documents: documents)

        // Checkpoint after every frame; the embedder dies on its third call.
        let crashing = try await MemoryOrchestrator(
            at: url,
            config: Fixture.config(checkpointFrames: 1),
            embedder: Fixture.current(failAfterCalls: 2)
        )
        await #expect(throws: WaxError.self) {
            _ = try await crashing.backfillUnembedded()
        }
        try await crashing.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll")
        #expect(try await Fixture.activeProgressMarkers(at: url) == 1)

        let resumedEmbedder = Fixture.current()
        let resumed = try await MemoryOrchestrator(
            at: url,
            config: Fixture.config(checkpointFrames: 1),
            embedder: resumedEmbedder
        )
        #expect(await resumed.runtimeStats().vectorsNeedReembed)
        // Two frames were committed before the crash; only the remaining four are redone.
        let reembedded = try await resumed.backfillUnembedded()
        #expect(reembedded == UInt64(documents.count - 2))
        #expect(await resumedEmbedder.calls.count == documents.count - 2)
        try await Fixture.expectVectorHits(resumed)
        try await resumed.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
        #expect(try await Fixture.activeProgressMarkers(at: url) == 0)
    }
}

@Test func reembedRewritesSupersededFramesThatHoldVectors() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)
        let wax = try await Wax.open(at: url)
        // Frame 0 ("apple pie") keeps its vector after being superseded by frame 1.
        try await wax.supersede(supersededId: 0, supersedingId: 1)
        try await wax.commit()
        try await wax.close()

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        let reembedded = try await memory.backfillUnembedded()
        #expect(reembedded == UInt64(Fixture.documents.count))
        try await memory.close()
    }
}

@Test func rememberDedupsChunksWrittenBySupersededModelBeforeAndAfterReembed() async throws {
    try await TempFiles.withTempFile { url in
        let words = (0..<80).map { "apple\($0)" }.joined(separator: " ")
        let config = Fixture.config(targetTokens: 8)
        let writer = try await MemoryOrchestrator(at: url, config: config, embedder: Fixture.legacy())
        let original = try await writer.remember(words)
        #expect(original.framesAdded > 2)
        try await writer.close()

        let memory = try await MemoryOrchestrator(at: url, config: config, embedder: Fixture.current())
        let beforeReembed = try await memory.remember(words)
        #expect(beforeReembed.deduplicated)
        #expect(beforeReembed.framesAdded == 0)

        _ = try await memory.backfillUnembedded()
        #expect(!(await memory.runtimeStats().vectorsNeedReembed))
        let afterReembed = try await memory.remember(words)
        #expect(afterReembed.deduplicated)
        #expect(afterReembed.framesAdded == 0)
        try await memory.close()

        let reopened = try await MemoryOrchestrator(at: url, config: config, embedder: Fixture.current())
        let afterReopen = try await reopened.remember(words)
        #expect(afterReopen.deduplicated)
        #expect(afterReopen.framesAdded == 0)
        try await reopened.close()
    }
}

@Test func rememberDuringReembedKeepsEveryVectorInTheNewSpace() async throws {
    try await TempFiles.withTempFile { url in
        let documents = (0..<24).map { "\(KeywordEmbedder.keywords[$0 % 3]) note \($0)" }
        try await Fixture.writeLegacyStore(at: url, documents: documents)

        let memory = try await MemoryOrchestrator(
            at: url,
            config: Fixture.config(checkpointFrames: 4),
            embedder: Fixture.current()
        )
        async let reembed = memory.backfillUnembedded()
        for index in 0..<5 {
            try await memory.remember("durian tasting \(index)")
        }
        let reembedded = try await reembed
        #expect(reembedded >= UInt64(documents.count))
        _ = try await memory.backfillUnembedded()
        #expect(!(await memory.runtimeStats().vectorsNeedReembed))
        #expect(await memory.runtimeStats().framesWithoutVectors == 0)

        let durian = try await memory.searchExecution(query: "durian", mode: .vectorOnly, topK: 5)
        #expect(durian.hits.count == 5)
        #expect(durian.hits.allSatisfy { $0.previewText?.contains("durian") == true })
        try await Fixture.expectVectorHits(memory)
        try await memory.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func appFlushesDuringBackgroundReembedNeverFail() async throws {
    try await TempFiles.withTempFile { url in
        let documents = (0..<24).map { "\(KeywordEmbedder.keywords[$0 % 3]) entry \($0)" }
        try await Fixture.writeLegacyStore(at: url, documents: documents)

        let memory = try await MemoryOrchestrator(
            at: url,
            config: Fixture.config(autoReembed: true, checkpointFrames: 2),
            embedder: Fixture.current()
        )
        // The re-embed started at open writes vectors in the background; the app's own
        // flushes must never see a vector index staged before one of those writes.
        for _ in 0..<30 {
            try await memory.flush()
        }
        try await Fixture.waitUntilReembedded(memory)
        #expect(!(await memory.runtimeStats().vectorsNeedReembed))
        try await Fixture.expectVectorHits(memory)
        try await memory.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func unboundStoreWithVectorsIsTreatedAsSupersededMiniLM() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)
        let wax = try await Wax.open(at: url)
        try await wax.overwriteMemoryBindingForTesting(nil)
        try await wax.commit()
        try await wax.close()

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        #expect(await memory.runtimeStats().vectorsNeedReembed)
        _ = try await memory.backfillUnembedded()
        try await memory.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func unboundStoreWithoutVectorsStaysCompatible() async throws {
    try await TempFiles.withTempFile { url in
        var textOnly = Fixture.config()
        textOnly.enableVectorSearch = false
        let writer = try await MemoryOrchestrator(at: url, config: textOnly)
        try await writer.remember("apple pie recipe from grandma")
        try await writer.close()
        #expect(try await Fixture.boundModel(at: url) == nil)

        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: Fixture.current())
        #expect(!(await memory.runtimeStats().vectorsNeedReembed))
        _ = try await memory.backfillUnembedded()
        try await Fixture.expectVectorHits(memory, keywords: ["apple"])
        try await memory.close()
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
    }
}

@Test func differentModelOrShapeStillFailsInsteadOfReembedding() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)

        await #expect(throws: WaxError.self) {
            _ = try await MemoryOrchestrator(
                at: url,
                config: Fixture.config(),
                embedder: KeywordEmbedder(model: "OtherModel", rotation: 0)
            )
        }
        await #expect(throws: WaxError.self) {
            _ = try await MemoryOrchestrator(
                at: url,
                config: Fixture.config(),
                embedder: KeywordEmbedder(model: "MiniLMAll-mean", rotation: 0, dimensions: 8)
            )
        }
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll")
    }
}

@Test func briefEndedSessionOpenOnStaleStoreStartsNoReembed() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)
        let embedder = Fixture.current()
        let store = DiskEndedSessionStore(
            sessionRootURL: url.deletingLastPathComponent(),
            noEmbedder: false,
            enableAccessStatsScoring: false,
            readiness: EmbeddingReadiness(),
            factoryOverride: { embedder }
        )

        let stillStale = try await store.withMemory(at: url) { memory in
            _ = try await memory.searchExecution(query: "apple", mode: .hybrid(), topK: 3)
            try await Task.sleep(for: .milliseconds(200))
            return await memory.runtimeStats().vectorsNeedReembed
        }

        #expect(stillStale)
        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll")
        #expect(try await Fixture.activeProgressMarkers(at: url) == 0)
    }
}

@Test func briefCorpusOpenOnStaleStoreStartsNoReembed() async throws {
    try await TempFiles.withTempFile { url in
        try await Fixture.writeLegacyStore(at: url)
        let config = BrokerCorpusStoreBuilder.memoryConfig(structuredMemoryEnabled: false)
        #expect(!config.automaticallyReembedSupersededVectors)

        let memory = try await MemoryOrchestrator(at: url, config: config, embedder: Fixture.current())
        _ = try await memory.searchExecution(query: "apple", mode: .hybrid(), topK: 3)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await memory.runtimeStats().vectorsNeedReembed)
        try await memory.close()

        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll")
        #expect(try await Fixture.activeProgressMarkers(at: url) == 0)
    }
}

@Test func reembedPastWalCapacityBetweenCheckpointsCompletes() async throws {
    try await TempFiles.withTempFile { url in
        // 512 frames between checkpoints at 64 dimensions is far more than a 64 KiB WAL holds.
        let wax = try await Wax.create(at: url, walSize: 64 * 1024)
        try await wax.close()
        let dimensions = 64
        let documents = (0..<600).map { "\(KeywordEmbedder.keywords[$0 % 3]) note number \($0)" }
        try await Fixture.writeLegacyStore(at: url, documents: documents, legacy: KeywordEmbedder(
            model: "MiniLMAll",
            rotation: 0,
            dimensions: dimensions
        ))

        let current = KeywordEmbedder(model: "MiniLMAll-mean", rotation: 2, dimensions: dimensions)
        let memory = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: current)
        #expect(await memory.runtimeStats().vectorsNeedReembed)
        #expect(try await memory.backfillUnembedded() == UInt64(documents.count))
        try await memory.close()

        #expect(try await Fixture.boundModel(at: url) == "MiniLMAll-mean")
        let reopened = try await MemoryOrchestrator(at: url, config: Fixture.config(), embedder: current)
        #expect(!(await reopened.runtimeStats().vectorsNeedReembed))
        try await Fixture.expectVectorHits(reopened)
        try await reopened.close()
    }
}
