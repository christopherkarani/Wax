import Foundation
import Testing
import Wax

@Test func upsertEntityNormalizesAliasesAndResolves() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("person:alice"),
        kind: "person",
        aliases: ["Alice", "ALICE", " alice  "],
        nowMs: 100
    )

    let matches = try await engine.resolveEntities(matchingAlias: "alice", limit: 10)
    #expect(matches.map(\.key) == [EntityKey("person:alice")])
}

@Test func assertFactAndQueryAsOfReturnsCurrentFact() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("person:alice"),
        kind: "person",
        aliases: ["Alice"],
        nowMs: 10
    )
    _ = try await engine.upsertEntity(
        key: EntityKey("place:paris"),
        kind: "place",
        aliases: ["Paris"],
        nowMs: 10
    )

    _ = try await engine.assertFact(
        subject: EntityKey("person:alice"),
        predicate: PredicateKey("lives_in"),
        object: .entity(EntityKey("place:paris")),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 10, toMs: nil),
        evidence: [
            StructuredEvidence(
                sourceFrameId: 0,
                chunkIndex: nil,
                spanUTF8: nil,
                extractorId: "test",
                extractorVersion: "1",
                confidence: nil,
                assertedAtMs: 10
            ),
        ]
    )

    let result = try await engine.facts(
        about: EntityKey("person:alice"),
        predicate: PredicateKey("lives_in"),
        asOf: .init(asOfMs: 10),
        limit: 10
    )

    #expect(result.hits.count == 1)
    #expect(result.hits[0].fact.subject == EntityKey("person:alice"))
    #expect(result.hits[0].fact.object == .entity(EntityKey("place:paris")))
    #expect(result.hits[0].isOpenEnded == true)
}

@Test func asOfBoundariesAreHalfOpen() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("person:bob"),
        kind: "person",
        aliases: ["Bob"],
        nowMs: 0
    )
    _ = try await engine.upsertEntity(
        key: EntityKey("place:nyc"),
        kind: "place",
        aliases: ["NYC"],
        nowMs: 0
    )

    _ = try await engine.assertFact(
        subject: EntityKey("person:bob"),
        predicate: PredicateKey("born_in"),
        object: .entity(EntityKey("place:nyc")),
        valid: StructuredTimeRange(fromMs: 100, toMs: 200),
        system: StructuredTimeRange(fromMs: 100, toMs: nil),
        evidence: []
    )

    let atStart = try await engine.facts(
        about: EntityKey("person:bob"),
        predicate: PredicateKey("born_in"),
        asOf: .init(asOfMs: 100),
        limit: 10
    )

    let atEnd = try await engine.facts(
        about: EntityKey("person:bob"),
        predicate: PredicateKey("born_in"),
        asOf: .init(asOfMs: 200),
        limit: 10
    )

    #expect(atStart.hits.count == 1)
    #expect(atEnd.hits.isEmpty == true)
}

@Test func retractFactClosesSystemTimeAndIsIdempotent() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("person:eva"),
        kind: "person",
        aliases: ["Eva"],
        nowMs: 0
    )

    let factId = try await engine.assertFact(
        subject: EntityKey("person:eva"),
        predicate: PredicateKey("status"),
        object: .string("active"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: []
    )

    try await engine.retractFact(factId: factId, atMs: 50)
    try await engine.retractFact(factId: factId, atMs: 50)

    let after = try await engine.facts(
        about: EntityKey("person:eva"),
        predicate: PredicateKey("status"),
        asOf: .init(asOfMs: 60),
        limit: 10
    )
    #expect(after.hits.isEmpty == true)
}

@Test func queryOrderIsDeterministicForTies() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("thing:a"),
        kind: "thing",
        aliases: ["A"],
        nowMs: 0
    )
    _ = try await engine.upsertEntity(
        key: EntityKey("thing:b"),
        kind: "thing",
        aliases: ["B"],
        nowMs: 0
    )

    let factA = try await engine.assertFact(
        subject: EntityKey("thing:a"),
        predicate: PredicateKey("color"),
        object: .string("red"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: []
    )
    let factB = try await engine.assertFact(
        subject: EntityKey("thing:b"),
        predicate: PredicateKey("color"),
        object: .string("red"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: []
    )

    let result = try await engine.facts(
        about: nil,
        predicate: PredicateKey("color"),
        asOf: .init(asOfMs: 0),
        limit: 10
    )

    let ids = result.hits.map(\.factId)
    #expect(ids == [factA, factB])
}
