import Foundation
import Testing
import Wax

@Suite("PublicStructuredMemoryTests")
struct PublicStructuredMemoryTests {
    private static var structuredConfig: Memory.Config {
        Memory.Config(
            enableVectorSearch: false,
            enableStructuredMemory: true
        )
    }

    @Test
    func crudAliasResolutionRetractionAndReopen() async throws {
        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url, config: Self.structuredConfig)

            let entityID = try await memory.upsertEntity(
                key: "person:alice",
                kind: "person",
                aliases: ["Alice", "A. Example"]
            )
            #expect(entityID.rawValue > 0)

            let byAlice = try await memory.resolveEntities(alias: "Alice")
            #expect(byAlice.map(\.key) == ["person:alice"])
            #expect(byAlice.first?.kind == "person")
            #expect(byAlice.first?.id == entityID)

            let byExample = try await memory.resolveEntities(alias: "A. Example")
            #expect(byExample.map(\.key) == ["person:alice"])

            let factID = try await memory.assertFact(
                subject: "person:alice",
                predicate: "favoriteTea",
                object: .string("oolong")
            )
            #expect(factID.rawValue > 0)

            let beforeRetract = try await memory.facts(
                subject: "person:alice",
                predicate: "favoriteTea"
            )
            #expect(beforeRetract.hits.count == 1)
            #expect(beforeRetract.hits[0].id == factID)
            #expect(beforeRetract.hits[0].subject == "person:alice")
            #expect(beforeRetract.hits[0].predicate == "favoriteTea")
            #expect(beforeRetract.hits[0].object == .string("oolong"))
            #expect(beforeRetract.hits[0].relation == .sets)
            #expect(beforeRetract.wasTruncated == false)

            try await memory.close()

            let reopenedWithFact = try await Memory(at: url, config: Self.structuredConfig)
            let persisted = try await reopenedWithFact.facts(
                subject: "person:alice",
                predicate: "favoriteTea"
            )
            #expect(persisted.hits.map(\.object) == [.string("oolong")])
            #expect(persisted.hits.map(\.id) == [factID])

            try await reopenedWithFact.retractFact(factID)
            let afterRetract = try await reopenedWithFact.facts(
                subject: "person:alice",
                predicate: "favoriteTea"
            )
            #expect(afterRetract.hits.isEmpty)

            try await reopenedWithFact.close()

            let reopenedAfterRetract = try await Memory(at: url, config: Self.structuredConfig)
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

    @Test
    func temporalQueryUsesHalfOpenMillisecondRanges() async throws {
        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url, config: Self.structuredConfig)
            _ = try await memory.upsertEntity(key: "person:alice", kind: "person")
            _ = try await memory.assertFact(
                subject: "person:alice",
                predicate: "favoriteTea",
                object: .string("oolong"),
                validFromMs: 1_000,
                validToMs: 2_000
            )

            let inside = try await memory.facts(
                subject: "person:alice",
                predicate: "favoriteTea",
                validAsOfMs: 1_000
            )
            #expect(inside.hits.map(\.object) == [.string("oolong")])
            #expect(inside.hits[0].valid == Memory.MillisecondTimeRange(fromMs: 1_000, toMs: 2_000))

            let atEnd = try await memory.facts(
                subject: "person:alice",
                predicate: "favoriteTea",
                validAsOfMs: 2_000
            )
            #expect(atEnd.hits.isEmpty)

            try await memory.close()
        }
    }

    @Test
    func edgesTraverseEntityValuedFacts() async throws {
        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url, config: Self.structuredConfig)
            _ = try await memory.upsertEntity(key: "person:alice", kind: "person")
            _ = try await memory.upsertEntity(key: "person:bob", kind: "person")
            let factID = try await memory.assertFact(
                subject: "person:alice",
                predicate: "works_with",
                object: .entity("person:bob")
            )

            let outbound = try await memory.edges(
                for: "person:alice",
                direction: .outbound,
                predicate: "works_with"
            )
            #expect(outbound.hits == [
                Memory.Edge(
                    factID: factID,
                    predicate: "works_with",
                    direction: .outbound,
                    neighbor: "person:bob"
                ),
            ])
            #expect(outbound.wasTruncated == false)

            let inbound = try await memory.edges(
                for: "person:bob",
                direction: .inbound
            )
            #expect(inbound.hits.map(\.neighbor) == ["person:alice"])
            #expect(inbound.hits.map(\.direction) == [.inbound])

            try await memory.close()
        }
    }

    @Test
    func structuredMethodsThrowFeatureDisabledWhenOff() async throws {
        try await TempFiles.withTempFile { url in
            let memory = try await Memory(
                at: url,
                config: .init(enableVectorSearch: false, enableStructuredMemory: false)
            )

            await expectFeatureDisabled {
                _ = try await memory.upsertEntity(key: "person:alice", kind: "person")
            }
            await expectFeatureDisabled {
                _ = try await memory.resolveEntities(alias: "Alice")
            }
            await expectFeatureDisabled {
                _ = try await memory.assertFact(
                    subject: "person:alice",
                    predicate: "favoriteTea",
                    object: .string("oolong")
                )
            }
            await expectFeatureDisabled {
                try await memory.retractFact(Memory.FactID(rawValue: 1))
            }
            await expectFeatureDisabled {
                _ = try await memory.facts(subject: "person:alice")
            }
            await expectFeatureDisabled {
                _ = try await memory.edges(for: "person:alice")
            }

            try await memory.close()
        }
    }

    @Test
    func publicDTOsExposeMemberwiseInitializers() {
        let entityID = Memory.EntityID(rawValue: 7)
        let factID = Memory.FactID(rawValue: 9)
        let match = Memory.EntityMatch(id: entityID, key: "person:alice", kind: "person")
        let range = Memory.MillisecondTimeRange(fromMs: 10, toMs: 20)
        let hit = Memory.FactHit(
            id: factID,
            spanID: 3,
            subject: "person:alice",
            predicate: "favoriteTea",
            object: .string("oolong"),
            relation: .sets,
            valid: range,
            system: Memory.MillisecondTimeRange(fromMs: 10, toMs: nil),
            isOpenEnded: true
        )
        let facts = Memory.FactsResult(hits: [hit], wasTruncated: false)
        let edge = Memory.Edge(
            factID: factID,
            predicate: "works_with",
            direction: .outbound,
            neighbor: "person:bob"
        )
        let edges = Memory.EdgesResult(hits: [edge], wasTruncated: true)

        #expect(match.key == "person:alice")
        #expect(facts.hits.count == 1)
        #expect(edges.wasTruncated)
        #expect(Memory.FactValue.integer(1) == .integer(1))
        #expect(Memory.FactValue.boolean(true) == .boolean(true))
        #expect(Memory.FactRelation.allCases == [.sets, .updates, .extends, .retracts])
    }
}

private func expectFeatureDisabled(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("expected WaxError.featureDisabled(feature: \"structured memory\")")
    } catch let error as WaxError {
        guard case .featureDisabled(let feature) = error else {
            Issue.record("expected WaxError.featureDisabled, got \(error)")
            return
        }
        #expect(feature == "structured memory")
    } catch {
        Issue.record("expected WaxError, got \(error)")
    }
}
