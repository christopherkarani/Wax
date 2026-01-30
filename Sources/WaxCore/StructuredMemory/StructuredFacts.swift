import Foundation

/// Structured fact triple.
public struct StructuredFact: Sendable, Equatable {
    public var subject: EntityKey
    public var predicate: PredicateKey
    public var object: FactValue

    public init(subject: EntityKey, predicate: PredicateKey, object: FactValue) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

/// Result hit for a structured fact query.
public struct StructuredFactHit: Sendable, Equatable {
    public var factId: FactRowID
    public var fact: StructuredFact
    public var evidence: [StructuredEvidence]
    /// True iff the underlying span is open-ended on both axes.
    public var isOpenEnded: Bool

    public init(
        factId: FactRowID,
        fact: StructuredFact,
        evidence: [StructuredEvidence],
        isOpenEnded: Bool
    ) {
        self.factId = factId
        self.fact = fact
        self.evidence = evidence
        self.isOpenEnded = isOpenEnded
    }
}

/// Result set for structured fact queries.
public struct StructuredFactsResult: Sendable, Equatable {
    public var hits: [StructuredFactHit]
    public var wasTruncated: Bool

    public init(hits: [StructuredFactHit], wasTruncated: Bool) {
        self.hits = hits
        self.wasTruncated = wasTruncated
    }
}
