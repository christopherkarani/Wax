import Foundation
import Testing
@testable import WaxCore

// MARK: - hashFact with all FactValue types

@Test func hashFactWithIntValue() throws {
    let hash = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("Alice"),
        predicate: PredicateKey("age"),
        object: .int(30),
        qualifiersHash: nil
    )
    #expect(hash.count == 32)
}

@Test func hashFactWithDoubleValue() throws {
    let hash = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("pi"),
        predicate: PredicateKey("value"),
        object: .double(3.14159),
        qualifiersHash: nil
    )
    #expect(hash.count == 32)
}

@Test func hashFactWithBoolValue() throws {
    let hash = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("feature"),
        predicate: PredicateKey("enabled"),
        object: .bool(true),
        qualifiersHash: nil
    )
    #expect(hash.count == 32)
}

@Test func hashFactWithDataValue() throws {
    let hash = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("doc"),
        predicate: PredicateKey("blob"),
        object: .data(Data([0x01, 0x02, 0x03])),
        qualifiersHash: nil
    )
    #expect(hash.count == 32)
}

@Test func hashFactWithTimeMsValue() throws {
    let hash = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("event"),
        predicate: PredicateKey("occurredAt"),
        object: .timeMs(1700000000000),
        qualifiersHash: nil
    )
    #expect(hash.count == 32)
}

@Test func hashFactWithDoubleZeroCanonicalizes() throws {
    let hashZero = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("x"),
        predicate: PredicateKey("val"),
        object: .double(0.0),
        qualifiersHash: nil
    )
    let hashNegZero = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("x"),
        predicate: PredicateKey("val"),
        object: .double(-0.0),
        qualifiersHash: nil
    )
    // Both should canonicalize to +0.0
    #expect(hashZero == hashNegZero)
}

@Test func hashFactWithNonFiniteDoubleThrows() {
    #expect(throws: WaxError.self) {
        _ = try StructuredMemoryHasher.hashFact(
            subject: EntityKey("x"),
            predicate: PredicateKey("val"),
            object: .double(Double.infinity),
            qualifiersHash: nil
        )
    }
}

@Test func hashFactDifferentTypesProduceDifferentHashes() throws {
    let hashInt = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("x"),
        predicate: PredicateKey("v"),
        object: .int(42),
        qualifiersHash: nil
    )
    let hashString = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("x"),
        predicate: PredicateKey("v"),
        object: .string("42"),
        qualifiersHash: nil
    )
    #expect(hashInt != hashString)
}

@Test func hashFactPreservesEntityAndPredicateKeyCase() throws {
    let upper = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("Person:Alice"),
        predicate: PredicateKey("Status"),
        object: .entity(EntityKey("Place:Paris")),
        qualifiersHash: nil
    )
    let lowerSubject = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("person:alice"),
        predicate: PredicateKey("Status"),
        object: .entity(EntityKey("Place:Paris")),
        qualifiersHash: nil
    )
    let lowerPredicate = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("Person:Alice"),
        predicate: PredicateKey("status"),
        object: .entity(EntityKey("Place:Paris")),
        qualifiersHash: nil
    )
    let lowerEntityObject = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("Person:Alice"),
        predicate: PredicateKey("Status"),
        object: .entity(EntityKey("place:paris")),
        qualifiersHash: nil
    )

    #expect(upper != lowerSubject)
    #expect(upper != lowerPredicate)
    #expect(upper != lowerEntityObject)
}

@Test func hashFactPreservesStringObjectCase() throws {
    let upper = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("person:alice"),
        predicate: PredicateKey("employer"),
        object: .string("OpenAI"),
        qualifiersHash: nil
    )
    let lower = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("person:alice"),
        predicate: PredicateKey("employer"),
        object: .string("openai"),
        qualifiersHash: nil
    )

    #expect(upper != lower)
}

@Test func hashFactPreservesStringObjectDiacritics() throws {
    let accented = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("person:zoe"),
        predicate: PredicateKey("display_name"),
        object: .string("Zoë"),
        qualifiersHash: nil
    )
    let unaccented = try StructuredMemoryHasher.hashFact(
        subject: EntityKey("person:zoe"),
        predicate: PredicateKey("display_name"),
        object: .string("Zoe"),
        qualifiersHash: nil
    )

    #expect(accented != unaccented)
}
