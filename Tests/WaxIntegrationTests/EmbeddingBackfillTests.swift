import Foundation
import Testing
import Wax

@Test
func backfillUnembeddedLiveChunksClearsDegradedAndRanksKnownHit() async throws {
    try await TempFiles.withTempFile { url in
        let needle = "unique backfill needle about swift actors"
        let decoy = "unrelated gardening notes about tomatoes"

        do {
            let seeded = try await Memory(at: url) {
                $0.enableVectorSearch = false
                $0.requireOnDeviceProviders = false
            }
            try await seeded.save(needle)
            try await seeded.save(decoy)
            try await seeded.flush()
            try await seeded.close()
        }

        let provider = DeterministicTextEmbedder()
        let memory = try await Memory(at: url) {
            $0.requireOnDeviceProviders = false
            $0.embedding = .custom(provider)
        }

        let before = await memory.stats()
        guard case .degraded = before.embeddingStatus else {
            Issue.record("expected degraded before backfill, got \(before.embeddingStatus)")
            try await memory.close()
            return
        }
        #expect(before.framesWithoutVectors > 0)
        #expect(before.queryEmbedderConfigured)

        let first = try await memory.backfillUnembedded()
        #expect(first > 0)
        try await memory.flush()

        let after = await memory.stats()
        #expect(after.embeddingStatus == .active(provider.identity))
        #expect(after.framesWithoutVectors == 0)

        let vectorHits = try await memory.search(
            needle,
            options: .init(topK: 1, mode: .vectorOnly)
        )
        #expect(vectorHits.items.first?.text.contains("swift actors") == true)

        let hybridHits = try await memory.search(
            needle,
            options: .init(topK: 1, mode: .hybrid())
        )
        #expect(hybridHits.items.first?.text.contains("swift actors") == true)

        let second = try await memory.backfillUnembedded()
        #expect(second == 0)
        try await memory.flush()
        let again = await memory.stats()
        #expect(again.embeddingStatus == .active(provider.identity))
        #expect(again.framesWithoutVectors == 0)

        try await memory.close()
    }
}

@Test
func backfillUnembeddedFailsClosedWithoutEmbedder() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) {
            $0.enableVectorSearch = false
            $0.requireOnDeviceProviders = false
        }
        try await memory.save("text-only frame must not invent vectors")
        try await memory.flush()

        do {
            _ = try await memory.backfillUnembedded()
            Issue.record("backfill without an embedder must fail closed")
        } catch let error as WaxError {
            guard case .missingEmbedder = error else {
                Issue.record("expected WaxError.missingEmbedder, got \(error)")
                try await memory.close()
                return
            }
        }

        let stats = await memory.stats()
        #expect(stats.embeddingStatus == .disabled)
        try await memory.close()
    }
}
