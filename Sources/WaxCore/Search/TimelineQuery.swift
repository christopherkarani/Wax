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

    /// The first `limit` frames in `order` among those the query admits. Frames with equal
    /// timestamps keep their order in `frames`.
    ///
    /// One pass with a bounded heap of indices, O(n log limit), copying only the selected
    /// frames. Hybrid search runs this over the whole frame list for every temporal query.
    package static func filter(frames: [FrameMeta], query: TimelineQuery) -> [FrameMeta] {
        guard query.limit > 0 else { return [] }
        let chronological = query.order == .chronological
        /// Whether the frame at index `lhs` comes before the one at `rhs` in the result.
        func precedes(_ lhs: Int, _ rhs: Int) -> Bool {
            let left = frames[lhs].timestamp
            let right = frames[rhs].timestamp
            if left != right { return chronological ? left < right : left > right }
            return lhs < rhs
        }

        // Root is the last kept frame, so a frame that precedes it replaces it.
        var heap: [Int] = []
        heap.reserveCapacity(min(query.limit, frames.count))
        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[parent], heap[child]) else { return }
                heap.swapAt(parent, child)
                child = parent
            }
        }
        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { return }
                var last = left
                if left + 1 < heap.count, precedes(heap[left], heap[left + 1]) { last = left + 1 }
                guard precedes(heap[parent], heap[last]) else { return }
                heap.swapAt(parent, last)
                parent = last
            }
        }

        for index in frames.indices {
            guard query.contains(frames[index].timestamp),
                  query.includeDeleted || frames[index].status != .deleted,
                  query.includeSuperseded || frames[index].supersededBy == nil
            else { continue }
            if heap.count < query.limit {
                heap.append(index)
                siftUp(heap.count - 1)
            } else if precedes(index, heap[0]) {
                heap[0] = index
                siftDown(0)
            }
        }
        return heap.sorted(by: precedes).map { frames[$0] }
    }
}
