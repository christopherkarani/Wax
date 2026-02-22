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

@Test func structuredMemorySessionWrapperResolvesAndRetractsFacts() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.structuredMemory()

        _ = try await session.upsertEntity(
            key: EntityKey("person:ada"),
            kind: "person",
            aliases: ["Ada"],
            nowMs: 100
        )

        let resolved = try await session.resolveEntities(matchingAlias: " ada ", limit: 10)
        #expect(resolved.map(\.key) == [EntityKey("person:ada")])

        let factID = try await session.assertFact(
            subject: EntityKey("person:ada"),
            predicate: PredicateKey("status"),
            object: .string("active"),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 100, toMs: nil),
            evidence: []
        )
        try await session.retractFact(factId: factID, atMs: 150)

        let after = try await session.facts(
            about: EntityKey("person:ada"),
            predicate: PredicateKey("status"),
            asOf: .init(asOfMs: 200),
            limit: 10
        )
        #expect(after.hits.isEmpty)

        try await wax.close()
    }
}

// MARK: - Phase 5A additions

// 1. evidenceFrameIds with multiple subjects, maxFacts, maxFrames limits, requireEvidenceSpan filtering

@Test func evidenceFrameIdsReturnsFramesForMultipleSubjects() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("person:leo"),
        kind: "person",
        aliases: ["Leo"],
        nowMs: 0
    )
    _ = try await engine.upsertEntity(
        key: EntityKey("person:mia"),
        kind: "person",
        aliases: ["Mia"],
        nowMs: 0
    )

    _ = try await engine.assertFact(
        subject: EntityKey("person:leo"),
        predicate: PredicateKey("likes"),
        object: .string("chess"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: [
            StructuredEvidence(
                sourceFrameId: 10,
                chunkIndex: nil,
                spanUTF8: nil,
                extractorId: "test",
                extractorVersion: "1",
                confidence: 0.9,
                assertedAtMs: 0
            ),
        ]
    )

    _ = try await engine.assertFact(
        subject: EntityKey("person:mia"),
        predicate: PredicateKey("likes"),
        object: .string("piano"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: [
            StructuredEvidence(
                sourceFrameId: 20,
                chunkIndex: nil,
                spanUTF8: nil,
                extractorId: "test",
                extractorVersion: "1",
                confidence: 0.8,
                assertedAtMs: 0
            ),
        ]
    )

    let frameIds = try await engine.evidenceFrameIds(
        subjectKeys: [EntityKey("person:leo"), EntityKey("person:mia")],
        asOf: .init(asOfMs: 100),
        maxFacts: 100,
        maxFrames: 100,
        requireEvidenceSpan: false
    )

    #expect(frameIds.contains(10))
    #expect(frameIds.contains(20))
}

@Test func evidenceFrameIdsRespectsMaxFramesLimit() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("thing:x"),
        kind: "thing",
        aliases: ["X"],
        nowMs: 0
    )

    for frameId in UInt64(1)...5 {
        _ = try await engine.assertFact(
            subject: EntityKey("thing:x"),
            predicate: PredicateKey("tag"),
            object: .int(Int64(frameId)),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: [
                StructuredEvidence(
                    sourceFrameId: frameId,
                    chunkIndex: nil,
                    spanUTF8: nil,
                    extractorId: "test",
                    extractorVersion: "1",
                    confidence: nil,
                    assertedAtMs: 0
                ),
            ]
        )
    }

    let frameIds = try await engine.evidenceFrameIds(
        subjectKeys: [EntityKey("thing:x")],
        asOf: .init(asOfMs: 100),
        maxFacts: 100,
        maxFrames: 2,
        requireEvidenceSpan: false
    )

    #expect(frameIds.count <= 2)
}

@Test func evidenceFrameIdsRequireEvidenceSpanFiltersUnspanned() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("doc:a"),
        kind: "doc",
        aliases: ["A"],
        nowMs: 0
    )

    // Evidence without a span
    _ = try await engine.assertFact(
        subject: EntityKey("doc:a"),
        predicate: PredicateKey("mention"),
        object: .string("no-span"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: [
            StructuredEvidence(
                sourceFrameId: 99,
                chunkIndex: nil,
                spanUTF8: nil,
                extractorId: "ext",
                extractorVersion: "1",
                confidence: nil,
                assertedAtMs: 0
            ),
        ]
    )

    // requireEvidenceSpan: true must exclude evidence without span_start/end
    let withSpanRequired = try await engine.evidenceFrameIds(
        subjectKeys: [EntityKey("doc:a")],
        asOf: .init(asOfMs: 100),
        maxFacts: 100,
        maxFrames: 100,
        requireEvidenceSpan: true
    )
    #expect(withSpanRequired.isEmpty)

    // Without requirement, should find frame 99
    let withoutSpanRequired = try await engine.evidenceFrameIds(
        subjectKeys: [EntityKey("doc:a")],
        asOf: .init(asOfMs: 100),
        maxFacts: 100,
        maxFrames: 100,
        requireEvidenceSpan: false
    )
    #expect(withoutSpanRequired.contains(99))
}

@Test func evidenceFrameIdsEmptySubjectsReturnsEmpty() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    let result = try await engine.evidenceFrameIds(
        subjectKeys: [],
        asOf: .init(asOfMs: 100),
        maxFacts: 100,
        maxFrames: 100,
        requireEvidenceSpan: false
    )
    #expect(result.isEmpty)
}

@Test func evidenceFrameIdsZeroMaxFactsReturnsEmpty() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("thing:y"),
        kind: "thing",
        aliases: ["Y"],
        nowMs: 0
    )
    _ = try await engine.assertFact(
        subject: EntityKey("thing:y"),
        predicate: PredicateKey("prop"),
        object: .string("val"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: [
            StructuredEvidence(
                sourceFrameId: 7,
                chunkIndex: nil,
                spanUTF8: nil,
                extractorId: "e",
                extractorVersion: "1",
                confidence: nil,
                assertedAtMs: 0
            ),
        ]
    )

    let result = try await engine.evidenceFrameIds(
        subjectKeys: [EntityKey("thing:y")],
        asOf: .init(asOfMs: 100),
        maxFacts: 0,
        maxFrames: 100,
        requireEvidenceSpan: false
    )
    #expect(result.isEmpty)
}

// 2. assertFact with valid_to <= valid_from throws encodingError

@Test func assertFactRejectsValidToNotGreaterThanValidFrom() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("node:a"),
        kind: "node",
        aliases: ["A"],
        nowMs: 0
    )

    do {
        _ = try await engine.assertFact(
            subject: EntityKey("node:a"),
            predicate: PredicateKey("prop"),
            object: .string("v"),
            valid: StructuredTimeRange(fromMs: 100, toMs: 100), // equal: not strictly greater
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: []
        )
        Issue.record("Expected encodingError for valid_to == valid_from")
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
        #expect(reason.contains("valid_to_ms"))
    }
}

@Test func assertFactRejectsValidToLessThanValidFrom() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("node:b"),
        kind: "node",
        aliases: ["B"],
        nowMs: 0
    )

    do {
        _ = try await engine.assertFact(
            subject: EntityKey("node:b"),
            predicate: PredicateKey("prop"),
            object: .string("v"),
            valid: StructuredTimeRange(fromMs: 200, toMs: 100), // inverted
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: []
        )
        Issue.record("Expected encodingError for valid_to < valid_from")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
    }
}

// 3. assertFact with system_to <= system_from throws encodingError

@Test func assertFactRejectsSystemToNotGreaterThanSystemFrom() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("node:c"),
        kind: "node",
        aliases: ["C"],
        nowMs: 0
    )

    do {
        _ = try await engine.assertFact(
            subject: EntityKey("node:c"),
            predicate: PredicateKey("prop"),
            object: .string("v"),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 50, toMs: 50), // equal: rejected
            evidence: []
        )
        Issue.record("Expected encodingError for system_to == system_from")
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
        #expect(reason.contains("system_to_ms"))
    }
}

// 4. All 7 FactValue types round-trip through assertFact → facts query

@Test func assertFactAllValueTypesRoundTrip() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("subj:rt"),
        kind: "subj",
        aliases: ["RT"],
        nowMs: 0
    )
    _ = try await engine.upsertEntity(
        key: EntityKey("ref:obj"),
        kind: "ref",
        aliases: ["Obj"],
        nowMs: 0
    )

    let cases: [(PredicateKey, FactValue)] = [
        (PredicateKey("v_string"),  .string("hello")),
        (PredicateKey("v_int"),     .int(Int64.min)),
        (PredicateKey("v_double"),  .double(-3.14)),
        (PredicateKey("v_bool"),    .bool(false)),
        (PredicateKey("v_data"),    .data(Data([0xDE, 0xAD, 0xBE, 0xEF]))),
        (PredicateKey("v_time"),    .timeMs(1_700_000_000_000)),
        (PredicateKey("v_entity"),  .entity(EntityKey("ref:obj"))),
    ]

    for (predicate, value) in cases {
        _ = try await engine.assertFact(
            subject: EntityKey("subj:rt"),
            predicate: predicate,
            object: value,
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: []
        )
    }

    for (predicate, expectedValue) in cases {
        let result = try await engine.facts(
            about: EntityKey("subj:rt"),
            predicate: predicate,
            asOf: .init(asOfMs: 0),
            limit: 10
        )
        #expect(result.hits.count == 1, "Missing fact for predicate \(predicate.rawValue)")
        #expect(result.hits[0].fact.object == expectedValue, "Wrong value for predicate \(predicate.rawValue)")
    }
}

// 5. Non-finite double detection

@Test func assertFactRejectsInfiniteDouble() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("node:inf"),
        kind: "node",
        aliases: ["Inf"],
        nowMs: 0
    )

    do {
        _ = try await engine.assertFact(
            subject: EntityKey("node:inf"),
            predicate: PredicateKey("score"),
            object: .double(Double.infinity),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: []
        )
        Issue.record("Expected encodingError for infinite Double")
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
        #expect(reason.contains("non-finite"))
    }
}

@Test func assertFactRejectsNaNDouble() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("node:nan"),
        kind: "node",
        aliases: ["NaN"],
        nowMs: 0
    )

    do {
        _ = try await engine.assertFact(
            subject: EntityKey("node:nan"),
            predicate: PredicateKey("score"),
            object: .double(Double.nan),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: []
        )
        Issue.record("Expected encodingError for NaN Double")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
    }
}

// 6. indexBatch with mismatched counts throws encodingError

@Test func indexBatchMismatchedCountsThrows() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    do {
        try await engine.indexBatch(
            frameIds: [1, 2, 3],
            texts: ["one", "two"]
        )
        Issue.record("Expected encodingError for count mismatch")
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
        #expect(reason.contains("frameIds.count"))
    }
}

@Test func indexBatchEmptyArrayIsNoOp() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    // Should not throw — empty batch is documented as a no-op
    try await engine.indexBatch(frameIds: [], texts: [])
    let count = try await engine.count()
    #expect(count == 0)
}

// 7. Empty text → removal delegation

@Test func indexEmptyTextDelegatesRemoval() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    try await engine.index(frameId: 42, text: "some content")
    let countAfterIndex = try await engine.count()
    #expect(countAfterIndex == 1)

    // Indexing with empty text (after trimming) removes the frame
    try await engine.index(frameId: 42, text: "   \n  ")
    let countAfterRemoval = try await engine.count()
    #expect(countAfterRemoval == 0)

    // Search should find nothing
    let results = try await engine.search(query: "some content", topK: 10)
    #expect(results.isEmpty)
}

// 8. frameId overflow (UInt64.max) should throw io error about sqlite int64 range

@Test func indexFrameIdMaxUInt64ThrowsIOError() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    do {
        try await engine.index(frameId: UInt64.max, text: "overflow test")
        Issue.record("Expected WaxError.io for frameId exceeding Int64 range")
    } catch let error as WaxError {
        guard case .io(let message) = error else {
            Issue.record("Expected WaxError.io, got \(error)")
            return
        }
        #expect(message.contains("sqlite int64 range"))
    }
}

// 9. retractFact where atMs <= system_from_ms throws encodingError

@Test func retractFactAtMsAtOrBeforeSystemFromThrows() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("person:frank"),
        kind: "person",
        aliases: ["Frank"],
        nowMs: 0
    )

    let factId = try await engine.assertFact(
        subject: EntityKey("person:frank"),
        predicate: PredicateKey("role"),
        object: .string("engineer"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 100, toMs: nil),
        evidence: []
    )

    // atMs == system_from_ms (100): not strictly after, must throw
    do {
        try await engine.retractFact(factId: factId, atMs: 100)
        Issue.record("Expected encodingError for retraction time equal to system_from_ms")
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
        #expect(reason.contains("retraction time"))
    }
}

@Test func retractFactAtMsBeforeSystemFromThrows() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    _ = try await engine.upsertEntity(
        key: EntityKey("person:gina"),
        kind: "person",
        aliases: ["Gina"],
        nowMs: 0
    )

    let factId = try await engine.assertFact(
        subject: EntityKey("person:gina"),
        predicate: PredicateKey("role"),
        object: .string("designer"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 200, toMs: nil),
        evidence: []
    )

    do {
        try await engine.retractFact(factId: factId, atMs: 50) // 50 < 200
        Issue.record("Expected encodingError for retraction time before system_from_ms")
    } catch let error as WaxError {
        guard case .encodingError = error else {
            Issue.record("Expected WaxError.encodingError, got \(error)")
            return
        }
    }
}

// 10. serialize/deserialize round-trip preserving both text search and structured memory data

@Test func serializeDeserializeRoundTripPreservesStructuredMemory() async throws {
    let original = try FTS5SearchEngine.inMemory()

    _ = try await original.upsertEntity(
        key: EntityKey("person:helen"),
        kind: "person",
        aliases: ["Helen"],
        nowMs: 0
    )
    _ = try await original.assertFact(
        subject: EntityKey("person:helen"),
        predicate: PredicateKey("job"),
        object: .string("architect"),
        valid: StructuredTimeRange(fromMs: 0, toMs: nil),
        system: StructuredTimeRange(fromMs: 0, toMs: nil),
        evidence: []
    )
    try await original.index(frameId: 1, text: "Helen designs systems")

    let blob = try await original.serialize()

    let restored = try FTS5SearchEngine.deserialize(from: blob)

    // Text search should survive the round-trip
    let textResults = try await restored.search(query: "Helen systems", topK: 10)
    #expect(textResults.contains { $0.frameId == 1 })

    // Structured memory should survive the round-trip
    let facts = try await restored.facts(
        about: EntityKey("person:helen"),
        predicate: PredicateKey("job"),
        asOf: .init(asOfMs: 0),
        limit: 10
    )
    #expect(facts.hits.count == 1)
    #expect(facts.hits[0].fact.object == .string("architect"))

    // Entity alias resolution should survive the round-trip
    let matches = try await restored.resolveEntities(matchingAlias: "helen", limit: 10)
    #expect(matches.map(\.key) == [EntityKey("person:helen")])
}

// 11. upsertEntity with empty alias is skipped/ignored

@Test func upsertEntityEmptyAliasIsIgnored() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("thing:z"),
        kind: "thing",
        aliases: ["", "   ", "\t\n", "ValidAlias"],
        nowMs: 0
    )

    // The empty/whitespace aliases should be skipped; the valid one is registered
    let valid = try await engine.resolveEntities(matchingAlias: "ValidAlias", limit: 10)
    #expect(valid.map(\.key) == [EntityKey("thing:z")])

    // Nothing should match the empty string (normalizes to empty → guard skips it)
    let empty = try await engine.resolveEntities(matchingAlias: "", limit: 10)
    #expect(empty.isEmpty)
}

// 12. upsertEntity updating kind when existing kind is empty

@Test func upsertEntityUpdatesKindWhenExistingKindIsEmpty() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    // Insert with no kind
    _ = try await engine.upsertEntity(
        key: EntityKey("item:k"),
        kind: "",
        aliases: ["K"],
        nowMs: 0
    )

    // Re-upsert with a real kind — should update the existing row's kind
    _ = try await engine.upsertEntity(
        key: EntityKey("item:k"),
        kind: "widget",
        aliases: ["K"],
        nowMs: 1
    )

    let matches = try await engine.resolveEntities(matchingAlias: "K", limit: 10)
    #expect(matches.count == 1)
    #expect(matches[0].kind == "widget")
}

// 13. resolveEntities with empty alias string returns empty

@Test func resolveEntitiesEmptyAliasReturnsEmpty() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    _ = try await engine.upsertEntity(
        key: EntityKey("person:jill"),
        kind: "person",
        aliases: ["Jill"],
        nowMs: 0
    )

    let result = try await engine.resolveEntities(matchingAlias: "   ", limit: 10)
    #expect(result.isEmpty)
}

// 14. facts query with nil subject and nil predicate returns all facts

@Test func factsQueryNilSubjectNilPredicateReturnsAll() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    for suffix in ["x", "y", "z"] {
        _ = try await engine.upsertEntity(
            key: EntityKey("item:\(suffix)"),
            kind: "item",
            aliases: [suffix.uppercased()],
            nowMs: 0
        )
        _ = try await engine.assertFact(
            subject: EntityKey("item:\(suffix)"),
            predicate: PredicateKey("color"),
            object: .string(suffix),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: []
        )
    }

    let result = try await engine.facts(
        about: nil,
        predicate: nil,
        asOf: .init(asOfMs: 0),
        limit: 100
    )

    #expect(result.hits.count == 3)
}

// 15. facts query wasTruncated flag when limit is reached

@Test func factsQueryWasTruncatedWhenLimitIsReached() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    for i in 0..<5 {
        _ = try await engine.upsertEntity(
            key: EntityKey("num:\(i)"),
            kind: "num",
            aliases: ["\(i)"],
            nowMs: 0
        )
        _ = try await engine.assertFact(
            subject: EntityKey("num:\(i)"),
            predicate: PredicateKey("index"),
            object: .int(Int64(i)),
            valid: StructuredTimeRange(fromMs: 0, toMs: nil),
            system: StructuredTimeRange(fromMs: 0, toMs: nil),
            evidence: []
        )
    }

    // Request exactly 3 facts from a set of 5 — should be truncated
    let truncated = try await engine.facts(
        about: nil,
        predicate: nil,
        asOf: .init(asOfMs: 0),
        limit: 3
    )
    #expect(truncated.hits.count == 3)
    #expect(truncated.wasTruncated == true)

    // Request all 5 — should not be truncated
    let notTruncated = try await engine.facts(
        about: nil,
        predicate: nil,
        asOf: .init(asOfMs: 0),
        limit: 100
    )
    #expect(notTruncated.hits.count == 5)
    #expect(notTruncated.wasTruncated == false)
}

// 16. Flush threshold: insert >2048 pending text ops forces flush

@Test func flushThresholdForcesFlushAfter2048PendingOps() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    // Insert 2049 frames — the internal batch flush threshold is 2048.
    // The 2049th write triggers a flush; we verify count is correct afterwards.
    let total = 2_049
    for i in 0..<total {
        try await engine.index(frameId: UInt64(i), text: "document number \(i)")
    }

    let count = try await engine.count()
    #expect(count == total)
}

// 17. Structured flush threshold: insert >512 structured ops forces flush

@Test func structuredFlushThresholdForcesFlushAfter512Ops() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    // The internal structured flush threshold is 512.
    // Inserting 513 entities exercises the auto-flush path inside upsertEntity.
    let total = 513
    for i in 0..<total {
        _ = try await engine.upsertEntity(
            key: EntityKey("ent:\(i)"),
            kind: "ent",
            aliases: ["entity\(i)"],
            nowMs: Int64(i)
        )
    }

    // Verify all entities were persisted correctly
    let matches = try await engine.resolveEntities(matchingAlias: "entity0", limit: 10)
    #expect(matches.map(\.key) == [EntityKey("ent:0")])

    let last = try await engine.resolveEntities(matchingAlias: "entity\(total - 1)", limit: 10)
    #expect(last.map(\.key) == [EntityKey("ent:\(total - 1)")])
}
