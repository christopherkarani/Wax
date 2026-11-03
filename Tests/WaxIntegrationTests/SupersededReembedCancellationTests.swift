import Foundation
import Testing
import Wax
import WaxCore
import WaxVectorSearch

/// Parks the embedder after `passCalls` calls until its task is cancelled.
private actor EmbedGate {
    let passCalls: Int
    private var calls = 0
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    init(passCalls: Int) {
        self.passCalls = passCalls
    }

    /// Returns `true` when the caller must park.
    func enter() -> Bool {
        calls += 1
        guard calls > passCalls else { return false }
        blocked = true
        for waiter in blockedWaiters { waiter.resume() }
        blockedWaiters.removeAll()
        return true
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }
}

private actor EmbedCounter {
    private(set) var count = 0
    func next() { count += 1 }
}

/// Document `item<N> ...` embeds onto axis `(N + rotation) % dimensions`, so every document
/// has its own direction and a vector left in the old space points at the wrong document.
private struct ItemEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int
    let normalize = true
    let identity: EmbeddingIdentity?
    let rotation: Int
    let gate: EmbedGate?
    let counter = EmbedCounter()

    init(model: String, rotation: Int, dimensions: Int, gate: EmbedGate? = nil) {
        self.dimensions = dimensions
        self.identity = EmbeddingIdentity(provider: "Wax", model: model, dimensions: dimensions, normalized: true)
        self.rotation = rotation
        self.gate = gate
    }

    func embed(_ text: String) async throws -> [Float] {
        await counter.next()
        if let gate, await gate.enter() {
            try await Task.sleep(for: .seconds(3_600))
        }
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        let item = Int(digits) ?? 0
        var vector = [Float](repeating: 0, count: dimensions)
        vector[(item + rotation) % dimensions] = 1
        return vector
    }
}

private enum CancelFixture {
    static let documentCount = 8
    static let documents = (0..<documentCount).map { "item\($0) archived note" }
    static let progressKind = "wax.internal.reembed_progress"

    static func config(autoReembed: Bool = false) -> OrchestratorConfig {
        var config = TestHelpers.defaultMemoryConfig(vector: true)
        config.chunking = .tokenCount(targetTokens: 32, overlapTokens: 0)
        config.ingestBatchSize = 1
        config.automaticallyReembedSupersededVectors = autoReembed
        // No periodic checkpoint before cancellation: only the final one can save progress.
        config.supersededReembedCheckpointFrames = 1_000
        return config
    }

    static func legacy() -> ItemEmbedder {
        ItemEmbedder(model: "MiniLMAll", rotation: 0, dimensions: documentCount)
    }

    static func current(gate: EmbedGate? = nil) -> ItemEmbedder {
        ItemEmbedder(model: "MiniLMAll-mean", rotation: 3, dimensions: documentCount, gate: gate)
    }

    static func writeLegacyStore(at url: URL) async throws {
        let writer = try await MemoryOrchestrator(at: url, config: config(), embedder: legacy())
        for document in documents {
            try await writer.remember(document)
        }
        try await writer.close()
    }

    static func storeState(at url: URL) async throws -> (model: String?, markers: Int, vectors: UInt64?) {
        let wax = try await Wax.open(at: url)
        let model = await wax.memoryBinding()?.embeddingModel
        let markers = await wax.frameMetas().filter {
            $0.kind == progressKind && $0.status == .active && $0.supersededBy == nil
        }.count
        let vectors = await wax.committedVecIndexManifest()?.vectorCount
        try await wax.close()
        return (model, markers, vectors)
    }

    /// Resumes the re-embed and checks that it redid nothing before `resumeFrom`, then that
    /// every document has exactly one vector, in the new space.
    static func resumeAndVerify(at url: URL, resumeFrom completed: Int) async throws {
        let embedder = current()
        let resumed = try await MemoryOrchestrator(at: url, config: config(), embedder: embedder)
        #expect(await resumed.runtimeStats().vectorsNeedReembed)
        let reembedded = try await resumed.backfillUnembedded()
        #expect(reembedded == UInt64(documentCount - completed))
        #expect(await embedder.counter.count == documentCount - completed)
        #expect(!(await resumed.runtimeStats().vectorsNeedReembed))
        #expect(await resumed.runtimeStats().framesWithoutVectors == 0)
        for (index, document) in documents.enumerated() {
            let hits = try await resumed.searchExecution(query: "item\(index)", mode: .vectorOnly, topK: 1)
            #expect(hits.hits.first?.previewText == document, "vector for item\(index)")
        }
        try await resumed.close()

        let state = try await storeState(at: url)
        #expect(state.model == "MiniLMAll-mean")
        #expect(state.markers == 0)
        #expect(state.vectors == UInt64(documentCount))
    }
}

@Test func cancelledReembedCheckpointsAndResumesWithoutRedoingWork() async throws {
    try await TempFiles.withTempFile { url in
        try await CancelFixture.writeLegacyStore(at: url)

        let gate = EmbedGate(passCalls: 3)
        let memory = try await MemoryOrchestrator(
            at: url,
            config: CancelFixture.config(),
            embedder: CancelFixture.current(gate: gate)
        )
        let reembed = Task { try await memory.backfillUnembedded() }
        await gate.waitUntilBlocked()
        reembed.cancel()
        await #expect(throws: (any Error).self) { _ = try await reembed.value }
        try await memory.close()

        let interrupted = try await CancelFixture.storeState(at: url)
        #expect(interrupted.model == "MiniLMAll")
        #expect(interrupted.markers == 1)
        try await CancelFixture.resumeAndVerify(at: url, resumeFrom: 3)
    }
}

@Test func closeDuringAutomaticReembedCheckpointsProgress() async throws {
    try await TempFiles.withTempFile { url in
        try await CancelFixture.writeLegacyStore(at: url)

        let gate = EmbedGate(passCalls: 5)
        let memory = try await MemoryOrchestrator(
            at: url,
            config: CancelFixture.config(autoReembed: true),
            embedder: CancelFixture.current(gate: gate)
        )
        await gate.waitUntilBlocked()
        try await memory.close()

        let interrupted = try await CancelFixture.storeState(at: url)
        #expect(interrupted.model == "MiniLMAll")
        #expect(interrupted.markers == 1)
        try await CancelFixture.resumeAndVerify(at: url, resumeFrom: 5)
    }
}
