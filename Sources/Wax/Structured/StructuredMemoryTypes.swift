import Foundation
import WaxCore

public extension Memory {
    /// Stable identifier for a stored entity.
    struct EntityID: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: Int64
        public init(rawValue: Int64) { self.rawValue = rawValue }
    }

    /// Stable identifier for a stored fact.
    struct FactID: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: Int64
        public init(rawValue: Int64) { self.rawValue = rawValue }
    }

    /// Typed value for a structured fact.
    enum FactValue: Sendable, Equatable, Hashable {
        case string(String)
        case integer(Int64)
        case double(Double)
        case boolean(Bool)
        case data(Data)
        case timeMilliseconds(Int64)
        case entity(String)
    }

    /// Version relation applied when asserting a fact.
    enum FactRelation: String, Sendable, Equatable, CaseIterable {
        case sets
        case updates
        case extends
        case retracts
    }

    /// Direction of an entity-valued edge.
    enum EdgeDirection: String, Sendable, Equatable, CaseIterable {
        case outbound
        case inbound
    }

    /// Half-open millisecond range `[fromMs, toMs)`. A nil end is open-ended.
    struct MillisecondTimeRange: Sendable, Equatable, Hashable {
        public var fromMs: Int64
        public var toMs: Int64?

        public init(fromMs: Int64, toMs: Int64? = nil) {
            self.fromMs = fromMs
            self.toMs = toMs
        }
    }

    /// Entity returned by alias resolution.
    struct EntityMatch: Sendable, Equatable, Hashable {
        public var id: EntityID
        public var key: String
        public var kind: String

        public init(id: EntityID, key: String, kind: String) {
            self.id = id
            self.key = key
            self.kind = kind
        }
    }

    /// One fact span returned by a structured query.
    struct FactHit: Sendable, Equatable, Hashable {
        public var id: FactID
        public var spanID: Int64
        public var subject: String
        public var predicate: String
        public var object: FactValue
        public var relation: FactRelation
        public var valid: MillisecondTimeRange
        public var system: MillisecondTimeRange
        public var isOpenEnded: Bool

        public init(
            id: FactID,
            spanID: Int64,
            subject: String,
            predicate: String,
            object: FactValue,
            relation: FactRelation,
            valid: MillisecondTimeRange,
            system: MillisecondTimeRange,
            isOpenEnded: Bool
        ) {
            self.id = id
            self.spanID = spanID
            self.subject = subject
            self.predicate = predicate
            self.object = object
            self.relation = relation
            self.valid = valid
            self.system = system
            self.isOpenEnded = isOpenEnded
        }
    }

    /// Result set for ``Memory/facts(subject:predicate:systemAsOfMs:validAsOfMs:limit:)``.
    struct FactsResult: Sendable, Equatable, Hashable {
        public var hits: [FactHit]
        public var wasTruncated: Bool

        public init(hits: [FactHit], wasTruncated: Bool) {
            self.hits = hits
            self.wasTruncated = wasTruncated
        }
    }

    /// One entity-valued edge returned by ``Memory/edges(for:direction:predicate:systemAsOfMs:validAsOfMs:limit:)``.
    struct Edge: Sendable, Equatable, Hashable {
        public var factID: FactID
        public var predicate: String
        public var direction: EdgeDirection
        public var neighbor: String

        public init(
            factID: FactID,
            predicate: String,
            direction: EdgeDirection,
            neighbor: String
        ) {
            self.factID = factID
            self.predicate = predicate
            self.direction = direction
            self.neighbor = neighbor
        }
    }

    /// Result set for ``Memory/edges(for:direction:predicate:systemAsOfMs:validAsOfMs:limit:)``.
    struct EdgesResult: Sendable, Equatable, Hashable {
        public var hits: [Edge]
        public var wasTruncated: Bool

        public init(hits: [Edge], wasTruncated: Bool) {
            self.hits = hits
            self.wasTruncated = wasTruncated
        }
    }
}

extension Memory.EntityID {
    package init(_ id: EntityRowID) {
        self.init(rawValue: id.rawValue)
    }

    package var coreID: EntityRowID {
        EntityRowID(rawValue: rawValue)
    }
}

extension Memory.FactID {
    package init(_ id: FactRowID) {
        self.init(rawValue: id.rawValue)
    }

    package var coreID: FactRowID {
        FactRowID(rawValue: rawValue)
    }
}

extension Memory.FactValue {
    package init(_ value: WaxCore.FactValue) {
        switch value {
        case .string(let string):
            self = .string(string)
        case .int(let integer):
            self = .integer(integer)
        case .double(let double):
            self = .double(double)
        case .bool(let boolean):
            self = .boolean(boolean)
        case .data(let data):
            self = .data(data)
        case .timeMs(let milliseconds):
            self = .timeMilliseconds(milliseconds)
        case .entity(let key):
            self = .entity(key.rawValue)
        }
    }

    package var coreValue: WaxCore.FactValue {
        switch self {
        case .string(let string):
            return .string(string)
        case .integer(let integer):
            return .int(integer)
        case .double(let double):
            return .double(double)
        case .boolean(let boolean):
            return .bool(boolean)
        case .data(let data):
            return .data(data)
        case .timeMilliseconds(let milliseconds):
            return .timeMs(milliseconds)
        case .entity(let key):
            return .entity(EntityKey(key))
        }
    }
}

extension Memory.FactRelation {
    package init(_ relation: VersionRelation) {
        switch relation {
        case .sets:
            self = .sets
        case .updates:
            self = .updates
        case .extends:
            self = .extends
        case .retracts:
            self = .retracts
        }
    }

    package var coreRelation: VersionRelation {
        switch self {
        case .sets:
            return .sets
        case .updates:
            return .updates
        case .extends:
            return .extends
        case .retracts:
            return .retracts
        }
    }
}

extension Memory.EdgeDirection {
    package init(_ direction: StructuredEdgeDirection) {
        switch direction {
        case .outbound:
            self = .outbound
        case .inbound:
            self = .inbound
        }
    }

    package var coreDirection: StructuredEdgeDirection {
        switch self {
        case .outbound:
            return .outbound
        case .inbound:
            return .inbound
        }
    }
}

extension Memory.MillisecondTimeRange {
    package init(_ range: StructuredTimeRange) {
        self.init(fromMs: range.fromMs, toMs: range.toMs)
    }
}

extension Memory.EntityMatch {
    package init(_ match: StructuredEntityMatch) {
        self.init(
            id: Memory.EntityID(rawValue: match.id),
            key: match.key.rawValue,
            kind: match.kind
        )
    }
}

extension Memory.FactHit {
    package init(_ hit: StructuredFactHit) {
        self.init(
            id: Memory.FactID(hit.factId),
            spanID: hit.spanId,
            subject: hit.fact.subject.rawValue,
            predicate: hit.fact.predicate.rawValue,
            object: Memory.FactValue(hit.fact.object),
            relation: Memory.FactRelation(hit.relation),
            valid: Memory.MillisecondTimeRange(hit.valid),
            system: Memory.MillisecondTimeRange(hit.system),
            isOpenEnded: hit.isOpenEnded
        )
    }
}

extension Memory.FactsResult {
    package init(_ result: StructuredFactsResult) {
        self.init(
            hits: result.hits.map(Memory.FactHit.init),
            wasTruncated: result.wasTruncated
        )
    }
}

extension Memory.Edge {
    package init(_ hit: EdgeHit) {
        self.init(
            factID: Memory.FactID(hit.factId),
            predicate: hit.predicate.rawValue,
            direction: Memory.EdgeDirection(hit.direction),
            neighbor: hit.neighbor.rawValue
        )
    }
}

extension Memory.EdgesResult {
    package init(_ result: StructuredEdgesResult) {
        self.init(
            hits: result.hits.map(Memory.Edge.init),
            wasTruncated: result.wasTruncated
        )
    }
}
