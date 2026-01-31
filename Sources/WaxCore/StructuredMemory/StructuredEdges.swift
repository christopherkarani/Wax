import Foundation

/// Direction for entity-valued edges.
public enum StructuredEdgeDirection: Sendable, Equatable {
    case outbound
    case inbound
}

/// Edge hit between entities.
public struct EdgeHit: Sendable, Equatable {
    public var factId: FactRowID
    public var predicate: PredicateKey
    public var direction: StructuredEdgeDirection
    public var neighbor: EntityKey

    public init(
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
public struct StructuredEdgesResult: Sendable, Equatable {
    public var hits: [EdgeHit]
    public var wasTruncated: Bool

    public init(hits: [EdgeHit], wasTruncated: Bool) {
        self.hits = hits
        self.wasTruncated = wasTruncated
    }
}
