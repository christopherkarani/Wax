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
