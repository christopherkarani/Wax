import Foundation

package enum VectorTopK {
    /// Bounded top-k selection, O(n log k). Ordering matches a full sort by score
    /// descending with ascending frameId as the tie-break.
    package static func select(
        frameIds: [UInt64],
        scores: [Float],
        limit: Int
    ) -> [(frameId: UInt64, score: Float)] {
        typealias Hit = (frameId: UInt64, score: Float)
        func ranksBefore(_ lhs: Hit, _ rhs: Hit) -> Bool {
            if lhs.score == rhs.score { return lhs.frameId < rhs.frameId }
            return lhs.score > rhs.score
        }
        guard limit > 0 else { return [] }

        // Heap root is the worst kept hit, so a better candidate replaces it.
        var heap: [Hit] = []
        heap.reserveCapacity(limit)

        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard ranksBefore(heap[parent], heap[child]) else { return }
                heap.swapAt(parent, child)
                child = parent
            }
        }

        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { return }
                var worst = left
                let right = left + 1
                if right < heap.count, ranksBefore(heap[left], heap[right]) {
                    worst = right
                }
                guard ranksBefore(heap[parent], heap[worst]) else { return }
                heap.swapAt(parent, worst)
                parent = worst
            }
        }

        for index in frameIds.indices {
            let candidate: Hit = (frameIds[index], scores[index])
            if heap.count < limit {
                heap.append(candidate)
                siftUp(heap.count - 1)
            } else if ranksBefore(candidate, heap[0]) {
                heap[0] = candidate
                siftDown(0)
            }
        }

        heap.sort(by: ranksBefore)
        return heap
    }
}
