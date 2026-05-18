import Foundation

/// Structured fact triple.
package struct StructuredFact: Sendable, Equatable {
    package var subject: EntityKey
    package var predicate: PredicateKey
    package var object: FactValue

    package init(subject: EntityKey, predicate: PredicateKey, object: FactValue) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

/// Result hit for a structured fact query.
package struct StructuredFactHit: Sendable, Equatable {
    package var factId: FactRowID
    package var spanId: Int64
    package var fact: StructuredFact
    package var relation: VersionRelation
    package var valid: StructuredTimeRange
    package var system: StructuredTimeRange
    package var evidence: [StructuredEvidence]
    /// True iff the underlying span is package-ended on both axes.
    package var isOpenEnded: Bool

    package init(
        factId: FactRowID,
        spanId: Int64,
        fact: StructuredFact,
        relation: VersionRelation,
        valid: StructuredTimeRange,
        system: StructuredTimeRange,
        evidence: [StructuredEvidence],
        isOpenEnded: Bool
    ) {
        self.factId = factId
        self.spanId = spanId
        self.fact = fact
        self.relation = relation
        self.valid = valid
        self.system = system
        self.evidence = evidence
        self.isOpenEnded = isOpenEnded
    }
}

/// Result set for structured fact queries.
package struct StructuredFactsResult: Sendable, Equatable {
    package var hits: [StructuredFactHit]
    package var wasTruncated: Bool

    package init(hits: [StructuredFactHit], wasTruncated: Bool) {
        self.hits = hits
        self.wasTruncated = wasTruncated
    }
}
