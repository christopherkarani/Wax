import Foundation

package struct TimelineQuery: Sendable, Equatable {
    package enum Order: Sendable, Equatable {
        case chronological
        case reverseChronological
    }

    package var limit: Int
    package var order: Order
    package var after: Int64?
    package var before: Int64?
    package var includeDeleted: Bool
    package var includeSuperseded: Bool

    package init(
        limit: Int,
        order: Order = .reverseChronological,
        after: Int64? = nil,
        before: Int64? = nil,
        includeDeleted: Bool = false,
        includeSuperseded: Bool = false
    ) {
        self.limit = limit
        self.order = order
        self.after = after
        self.before = before
        self.includeDeleted = includeDeleted
        self.includeSuperseded = includeSuperseded
    }

    package func contains(_ timestamp: Int64) -> Bool {
        if let after, timestamp < after { return false }
        if let before, timestamp >= before { return false }
        return true
    }

    package static func filter(frames: [FrameMeta], query: TimelineQuery) -> [FrameMeta] {
        let filtered = frames
            .filter { query.contains($0.timestamp) }
            .filter { query.includeDeleted || $0.status != .deleted }
            .filter { query.includeSuperseded || $0.supersededBy == nil }

        let ordered: [FrameMeta]
        switch query.order {
        case .chronological:
            ordered = filtered.sorted { $0.timestamp < $1.timestamp }
        case .reverseChronological:
            ordered = filtered.sorted { $0.timestamp > $1.timestamp }
        }
        if query.limit <= 0 { return [] }
        return Array(ordered.prefix(query.limit))
    }
}
