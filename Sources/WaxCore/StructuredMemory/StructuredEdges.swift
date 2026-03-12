import Foundation

/// Direction for entity-valued edges.
package enum StructuredEdgeDirection: Sendable, Equatable {
    case outbound
    case inbound
}

/// Edge hit between entities.
package struct EdgeHit: Sendable, Equatable {
    package var factId: FactRowID
    package var predicate: PredicateKey
    package var direction: StructuredEdgeDirection
    package var neighbor: EntityKey

    package init(
        factId: FactRowID,
        predicate: PredicateKey,
        direction: StructuredEdgeDirection,
        neighbor: EntityKey
    ) {
        self.factId = factId
        self.predicate = predicate
        self.direction = direction
        self.neighbor = neighbor
    }
}

/// Result set for structured edge queries.
package struct StructuredEdgesResult: Sendable, Equatable {
    package var hits: [EdgeHit]
    package var wasTruncated: Bool

    package init(hits: [EdgeHit], wasTruncated: Bool) {
        self.hits = hits
        self.wasTruncated = wasTruncated
    }
}
