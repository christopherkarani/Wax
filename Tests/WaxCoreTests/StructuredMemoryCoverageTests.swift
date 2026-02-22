import Foundation
import Testing
@testable import WaxCore

@Test
func compressionKindRoundTripsCanonicalEncoding() {
    let mappings: [(CanonicalEncoding, CompressionKind)] = [
        (.plain, .none),
        (.lzfse, .lzfse),
        (.lz4, .lz4),
        (.deflate, .deflate),
    ]

    for (encoding, kind) in mappings {
        #expect(CompressionKind(canonicalEncoding: encoding) == kind)
        #expect(kind.canonicalEncoding == encoding)
    }
}

@Test
func structuredMemoryHasherSupportsAllFactValueKindsAndQualifiers() throws {
    let subject = EntityKey("entity:alpha")
    let predicate = PredicateKey("relates_to")
    let qualifiers = Data(repeating: 0xAA, count: 32)

    let values: [FactValue] = [
        .string("hello"),
        .int(42),
        .double(1.25),
        .bool(true),
        .data(Data([0x01, 0x02])),
        .timeMs(123_456),
        .entity(EntityKey("entity:beta")),
    ]

    var digests = Set<Data>()
    for value in values {
        let digest = try StructuredMemoryHasher.hashFact(
            subject: subject,
            predicate: predicate,
            object: value,
            qualifiersHash: qualifiers
        )
        #expect(digest.count == 32)
        digests.insert(digest)
    }

    #expect(digests.count == values.count)

    let withQualifiers = try StructuredMemoryHasher.hashFact(
        subject: subject,
        predicate: predicate,
        object: .string("same"),
        qualifiersHash: qualifiers
    )
    let withoutQualifiers = try StructuredMemoryHasher.hashFact(
        subject: subject,
        predicate: predicate,
        object: .string("same"),
        qualifiersHash: nil
    )
    #expect(withQualifiers != withoutQualifiers)
}

@Test
func structuredMemoryHasherRejectsInvalidInput() {
    do {
        _ = try StructuredMemoryHasher.hashFact(
            subject: EntityKey("entity:alpha"),
            predicate: PredicateKey("p"),
            object: .string("v"),
            qualifiersHash: Data(repeating: 0xFF, count: 31)
        )
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("qualifiers_hash"))
    } catch {
        #expect(Bool(false))
    }

    do {
        _ = try StructuredMemoryHasher.hashFact(
            subject: EntityKey("entity:alpha"),
            predicate: PredicateKey("p"),
            object: .double(.infinity),
            qualifiersHash: nil
        )
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("non-finite"))
    } catch {
        #expect(Bool(false))
    }
}

@Test
func structuredMemorySpanKeyUsesOpenEndedSentinel() {
    let openRange = StructuredTimeRange(fromMs: 100)
    let sentinelRange = StructuredTimeRange(fromMs: 100, toMs: -1)

    let openHash = StructuredMemoryHasher.hashSpanKey(
        factId: FactRowID(rawValue: 7),
        valid: openRange,
        systemFromMs: 55
    )
    let sentinelHash = StructuredMemoryHasher.hashSpanKey(
        factId: FactRowID(rawValue: 7),
        valid: sentinelRange,
        systemFromMs: 55
    )

    #expect(openHash == sentinelHash)
}

@Test
func structuredMemoryValueTypesCoverInitializersAndComparable() {
    let entityA = EntityKey("entity:a")
    let entityB = EntityKey(rawValue: "entity:b")
    let predicateA = PredicateKey("likes")
    let predicateB = PredicateKey(rawValue: "knows")

    #expect(entityA.rawValue == "entity:a")
    #expect(entityB.rawValue == "entity:b")
    #expect(predicateA.rawValue == "likes")
    #expect(predicateB.rawValue == "knows")

    #expect(EntityRowID(rawValue: 1) < EntityRowID(rawValue: 2))
    #expect(FactRowID(rawValue: 1) < FactRowID(rawValue: 2))
    #expect(PredicateRowID(rawValue: 1) < PredicateRowID(rawValue: 2))

    let latest = StructuredMemoryAsOf.latest
    #expect(latest.systemTimeMs == Int64.max)
    #expect(latest.validTimeMs == Int64.max)

    let queryContext = StructuredMemoryQueryContext(
        asOf: StructuredMemoryAsOf(systemTimeMs: 10, validTimeMs: 20),
        maxResults: 3,
        maxTraversalEdges: 4,
        maxDepth: 2
    )
    #expect(queryContext.maxResults == 3)
    #expect(queryContext.maxTraversalEdges == 4)
    #expect(queryContext.maxDepth == 2)

    let edge = EdgeHit(
        factId: FactRowID(rawValue: 99),
        predicate: PredicateKey("connected_to"),
        direction: .outbound,
        neighbor: EntityKey("entity:z")
    )
    let result = StructuredEdgesResult(hits: [edge], wasTruncated: false)
    #expect(result.hits.count == 1)
    #expect(!result.wasTruncated)
}
