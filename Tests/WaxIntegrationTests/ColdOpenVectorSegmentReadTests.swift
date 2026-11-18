import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTestSupport

/// Opening a store reads its committed vector segment from disk and checks its SHA-256.
/// At 100k MiniLM vectors that segment is 153 MB, and open used to read and hash it three
/// times (engine-kind detection, the engine load, and the vector-coverage scan), which was
/// about a third of cold-open time. Open must read it once and still verify it.
@Suite
struct ColdOpenVectorSegmentReadTests {
    private static let documents = (0..<6).map { "cold open note \($0) about vector segments" }

    @Test func openingAnEmbeddedStoreReadsTheVectorSegmentOnce() async throws {
        try await TempFiles.withTempFile { url in
            let embedder = DeterministicTextEmbedder()
            try await Self.writeStore(at: url, embedder: embedder, vectorDocuments: Self.documents)

            let reopened = try await MemoryOrchestrator(at: url, config: Self.config(), embedder: embedder)
            #expect(await reopened.wax.committedVecIndexReadsForTesting() == 1)
            // Coverage computed from the loaded engine still sees every frame embedded.
            #expect(await reopened.embeddingStatus == .active(embedder.identity))
            let hits = try await reopened.recall(query: Self.documents[2])
            #expect(!hits.items.isEmpty)
            try await reopened.close()
        }
    }

    @Test func openStillReportsFramesSavedWithoutVectors() async throws {
        try await TempFiles.withTempFile { url in
            let embedder = DeterministicTextEmbedder()
            try await Self.writeStore(at: url, embedder: embedder, vectorDocuments: Self.documents)
            let textOnly = try await MemoryOrchestrator(at: url, config: Self.config(vector: false))
            try await textOnly.remember("a later note saved while vector search was off")
            try await textOnly.close()

            let reopened = try await MemoryOrchestrator(at: url, config: Self.config(), embedder: embedder)
            #expect(await reopened.wax.committedVecIndexReadsForTesting() == 1)
            guard case .degraded(_, let reason) = await reopened.embeddingStatus else {
                Issue.record("expected degraded coverage, got \(await reopened.embeddingStatus)")
                try await reopened.close()
                return
            }
            #expect(reason == MemoryOrchestrator.missingVectorsReason)
            try await reopened.close()
        }
    }

    private static func config(vector: Bool = true) -> OrchestratorConfig {
        var config = TestHelpers.defaultMemoryConfig(vector: vector)
        config.chunking = .tokenCount(targetTokens: 64, overlapTokens: 0)
        return config
    }

    private static func writeStore(
        at url: URL,
        embedder: DeterministicTextEmbedder,
        vectorDocuments: [String]
    ) async throws {
        let writer = try await MemoryOrchestrator(at: url, config: config(), embedder: embedder)
        for document in vectorDocuments {
            try await writer.remember(document)
        }
        try await writer.close()
        let wax = try await Wax.open(at: url)
        let vectors = await wax.committedVecIndexManifest()?.vectorCount
        try await wax.close()
        #expect(vectors == UInt64(vectorDocuments.count), "setup: every document has a committed vector")
    }
}
