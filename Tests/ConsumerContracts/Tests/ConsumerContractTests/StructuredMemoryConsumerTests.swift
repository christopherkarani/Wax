import Foundation
import Testing
import Wax

@Suite("StructuredMemoryConsumerTests")
struct StructuredMemoryConsumerTests {
    @Test
    func crudAliasResolutionRetractionAndReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wax-structured-consumer-\(UUID().uuidString).wax")
        defer { try? FileManager.default.removeItem(at: url) }

        let config = Memory.Config(
            enableVectorSearch: false,
            enableStructuredMemory: true
        )

        let factID: Memory.FactID
        do {
            let memory = try await Memory(at: url, config: config)
            _ = try await memory.upsertEntity(
                key: "person:alice",
                kind: "person",
                aliases: ["Alice", "A. Example"]
            )

            let resolved = try await memory.resolveEntities(alias: "Alice")
            #expect(resolved.map(\.key) == ["person:alice"])
            #expect(resolved.first?.kind == "person")

            let byExample = try await memory.resolveEntities(alias: "A. Example")
            #expect(byExample.map(\.key) == ["person:alice"])

            factID = try await memory.assertFact(
                subject: "person:alice",
                predicate: "favoriteTea",
                object: .string("oolong")
            )

            let found = try await memory.facts(
                subject: "person:alice",
                predicate: "favoriteTea"
            )
            #expect(found.hits.count == 1)
            #expect(found.hits[0].object == .string("oolong"))
            #expect(found.hits[0].id == factID)
            #expect(found.wasTruncated == false)

            try await memory.close()
        }

        do {
            let reopened = try await Memory(at: url, config: config)
            let persisted = try await reopened.facts(
                subject: "person:alice",
                predicate: "favoriteTea"
            )
            #expect(persisted.hits.map(\.object) == [.string("oolong")])

            try await reopened.retractFact(factID)
            let afterRetract = try await reopened.facts(
                subject: "person:alice",
                predicate: "favoriteTea"
            )
            #expect(afterRetract.hits.isEmpty)

            try await reopened.close()
        }

        let reopenedAfterRetract = try await Memory(at: url, config: config)
        let stillAbsent = try await reopenedAfterRetract.facts(
            subject: "person:alice",
            predicate: "favoriteTea"
        )
        #expect(stillAbsent.hits.isEmpty)

        let resolvedAfterReopen = try await reopenedAfterRetract.resolveEntities(alias: "Alice")
        #expect(resolvedAfterReopen.map(\.key) == ["person:alice"])

        try await reopenedAfterRetract.close()
    }
}
