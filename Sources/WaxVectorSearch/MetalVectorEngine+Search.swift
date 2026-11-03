#if canImport(Metal)
import Foundation
import Metal
import WaxCore

extension MetalVectorEngine {
    package func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        try await withReadLock {
            try validate(vector)
            guard vectorCount > 0 else { return [] }
            let limit = Self.clampTopK(topK)
            let topKCount = min(limit, Int(vectorCount))
            let reductionThreadsPerThreadgroup = Self.reductionThreadgroupSize(
                maxThreads: topKReduceDistancesPipeline.maxTotalThreadsPerThreadgroup
            )
            let useGpuTopK = Int(vectorCount) >= Self.gpuTopKThreshold && topKCount <= reductionThreadsPerThreadgroup
            
            // Zero-Copy: No sync needed. vectorsBuffer is always up to date.

            // Allocate transient buffers for concurrency safety
            let transientBuffers = try acquireTransientBuffers(vectorCount: Int(vectorCount))
            defer { releaseTransientBuffers(transientBuffers) }

            let transientQueryBuffer = transientBuffers.query
            let transientDistancesBuffer = transientBuffers.distances
            let transientCountBuffer = transientBuffers.count

            let query = Self.normalizedCosineQuery(vector)
            let queryPtr = transientQueryBuffer.contents().assumingMemoryBound(to: Float.self)
            queryPtr.update(from: query, count: query.count)

            var currentVectorCount = UInt32(vectorCount)
            withUnsafeBytes(of: &currentVectorCount) { raw in
                transientCountBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw WaxError.invalidToc(reason: "Failed to create command buffer")
            }

            var finalTopKBuffer: MTLBuffer?

            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw WaxError.invalidToc(reason: "Failed to create compute encoder")
            }

            computeEncoder.setBuffer(vectorsBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(transientQueryBuffer, offset: 0, index: 1)
            computeEncoder.setBuffer(transientDistancesBuffer, offset: 0, index: 2)
            computeEncoder.setBuffer(transientCountBuffer, offset: 0, index: 3)
            computeEncoder.setBuffer(dimensionsBuffer, offset: 0, index: 4)

            // Metal requires threadgroup memory lengths to be a multiple of 16 bytes.
            let queryBytes = dimensions * MemoryLayout<Float>.stride
            let threadgroupMemorySize = (queryBytes + 15) & ~15
            computeEncoder.setThreadgroupMemoryLength(threadgroupMemorySize, index: 0)

            let activePipeline = (useSIMD8 && computePipelineSIMD8 != nil) ? computePipelineSIMD8! : computePipeline
            computeEncoder.setComputePipelineState(activePipeline)

            let maxThreads = activePipeline.maxTotalThreadsPerThreadgroup
            let threadsPerThreadgroup = min(maxThreads, Self.maxThreadsPerThreadgroup)
            let threadgroups = MTLSize(
                width: (Int(vectorCount) + threadsPerThreadgroup - 1) / threadsPerThreadgroup,
                height: 1,
                depth: 1
            )
            let threadgroupSize = MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)

            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()

            if useGpuTopK {
                // GPU top-k reduction: per-threadgroup bitonic sort on chunks,
                // then iteratively merge until a single sorted top-k remains.
                let threadgroupSize = reductionThreadsPerThreadgroup
                let groupCount = (Int(vectorCount) + threadgroupSize - 1) / threadgroupSize
                let stage1Count = groupCount * topKCount
                let stage1Length = stage1Count * MemoryLayout<TopKEntry>.stride
                guard let stage1Buffer = device.makeBuffer(length: stage1Length, options: .storageModeShared) else {
                    throw WaxError.invalidToc(reason: "Failed to allocate top-k stage1 buffer")
                }

                guard let reduceEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw WaxError.invalidToc(reason: "Failed to create top-k reduction encoder")
                }
                reduceEncoder.setComputePipelineState(topKReduceDistancesPipeline)
                reduceEncoder.setBuffer(transientDistancesBuffer, offset: 0, index: 0)
                var vectorCount32 = UInt32(vectorCount)
                var topK32 = UInt32(topKCount)
                reduceEncoder.setBytes(&vectorCount32, length: MemoryLayout<UInt32>.stride, index: 1)
                reduceEncoder.setBytes(&topK32, length: MemoryLayout<UInt32>.stride, index: 2)
                reduceEncoder.setBuffer(stage1Buffer, offset: 0, index: 3)
                reduceEncoder.setThreadgroupMemoryLength(
                    threadgroupSize * MemoryLayout<TopKEntry>.stride,
                    index: 0
                )
                let reduceGroups = MTLSize(width: groupCount, height: 1, depth: 1)
                let reduceGroupSize = MTLSize(width: threadgroupSize, height: 1, depth: 1)
                reduceEncoder.dispatchThreadgroups(reduceGroups, threadsPerThreadgroup: reduceGroupSize)
                reduceEncoder.endEncoding()

                var currentBuffer = stage1Buffer
                var currentCount = stage1Count
                while currentCount > topKCount {
                    let nextGroupCount = (currentCount + threadgroupSize - 1) / threadgroupSize
                    let nextCount = nextGroupCount * topKCount
                    let nextLength = nextCount * MemoryLayout<TopKEntry>.stride
                    guard let nextBuffer = device.makeBuffer(length: nextLength, options: .storageModeShared) else {
                        throw WaxError.invalidToc(reason: "Failed to allocate top-k merge buffer")
                    }

                    guard let mergeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                        throw WaxError.invalidToc(reason: "Failed to create top-k merge encoder")
                    }
                    mergeEncoder.setComputePipelineState(topKReduceEntriesPipeline)
                    mergeEncoder.setBuffer(currentBuffer, offset: 0, index: 0)
                    var entryCount32 = UInt32(currentCount)
                    mergeEncoder.setBytes(&entryCount32, length: MemoryLayout<UInt32>.stride, index: 1)
                    mergeEncoder.setBytes(&topK32, length: MemoryLayout<UInt32>.stride, index: 2)
                    mergeEncoder.setBuffer(nextBuffer, offset: 0, index: 3)
                    mergeEncoder.setThreadgroupMemoryLength(
                        threadgroupSize * MemoryLayout<TopKEntry>.stride,
                        index: 0
                    )
                    let mergeGroups = MTLSize(width: nextGroupCount, height: 1, depth: 1)
                    mergeEncoder.dispatchThreadgroups(mergeGroups, threadsPerThreadgroup: reduceGroupSize)
                    mergeEncoder.endEncoding()

                    currentBuffer = nextBuffer
                    currentCount = nextCount
                }

                finalTopKBuffer = currentBuffer
            }

            await withCheckedContinuation { continuation in
                commandBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
                commandBuffer.commit()
            }
            try Self.validateCommandBufferCompleted(commandBuffer)

            if useGpuTopK, let finalTopKBuffer {
                guard let resultsBuffer = device.makeBuffer(
                    length: topKCount * MemoryLayout<TopKResult>.stride,
                    options: .storageModeShared
                ) else {
                    throw WaxError.invalidToc(reason: "Failed to allocate top-k results buffer")
                }

                let entriesPtr = finalTopKBuffer.contents().assumingMemoryBound(to: TopKEntry.self)
                let resultsPtr = resultsBuffer.contents().assumingMemoryBound(to: TopKResult.self)
                var resultCount = 0
                for i in 0..<topKCount {
                    let entry = entriesPtr[i]
                    if entry.index == UInt32.max || !entry.distance.isFinite { continue }
                    let index = Int(entry.index)
                    if index >= frameIds.count { continue }
                    let score = metric.score(fromDistance: entry.distance)
                    resultsPtr[resultCount] = TopKResult(frameId: frameIds[index], score: score)
                    resultCount += 1
                }

                var results: [(UInt64, Float)] = []
                results.reserveCapacity(resultCount)
                for i in 0..<resultCount {
                    let entry = resultsPtr[i]
                    results.append((entry.frameId, entry.score))
                }
                return results
            }

            let distancesPtr = transientDistancesBuffer.contents().assumingMemoryBound(to: Float.self)
            let topResults = Self.topK(distances: distancesPtr, count: Int(vectorCount), k: limit)

            var results: [(UInt64, Float)] = []
            results.reserveCapacity(topResults.count)

            for (index, distance) in topResults {
                let score = metric.score(fromDistance: distance)
                guard score.isFinite else { continue }
                results.append((frameIds[index], score))
            }

            return results
        }
    }

    /// O(n log k) partial selection to avoid full sort of distance buffer.
    private static func topK(distances: UnsafePointer<Float>, count: Int, k: Int) -> [(Int, Float)] {
        guard k > 0, count > 0 else { return [] }
        var heap: [(Float, Int)] = [] // (distance, index)
        heap.reserveCapacity(k)

        func siftDown(_ start: Int, _ end: Int) {
            var root = start
            while true {
                let child = root * 2 + 1
                if child > end { break }
                var swap = root
                if heap[swap].0 < heap[child].0 { swap = child }
                if child + 1 <= end, heap[swap].0 < heap[child + 1].0 { swap = child + 1 }
                if swap == root { return }
                heap.swapAt(root, swap)
                root = swap
            }
        }

        func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                if heap[parent].0 >= heap[child].0 { break }
                heap.swapAt(parent, child)
                child = parent
            }
        }

        let initial = min(k, count)
        for i in 0..<initial {
            heap.append((distances[i], i))
        }
        // Build max-heap
        for i in stride(from: (heap.count / 2), through: 0, by: -1) {
            siftDown(i, heap.count - 1)
        }

        if initial < count {
            for i in initial..<count {
                let value = distances[i]
                if value >= heap[0].0 { continue }
                heap[0] = (value, i)
                siftDown(0, heap.count - 1)
            }
        }

        // Heap contains k smallest distances unordered; sort ascending
        heap.sort { $0.0 < $1.0 }
        return heap.map { ($0.1, $0.0) }
    }

    private static func clampTopK(_ topK: Int) -> Int {
        if topK < 1 { return 1 }
        if topK > maxResults { return maxResults }
        return topK
    }

    private static func normalizedCosineQuery(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        for value in vector {
            sumOfSquares += value * value
        }

        guard sumOfSquares > 0 else { return vector }
        let magnitude = sumOfSquares.squareRoot()
        guard magnitude > 0 else { return vector }

        return vector.map { $0 / magnitude }
    }

    private static func validateCommandBufferCompleted(_ commandBuffer: MTLCommandBuffer) throws {
        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error.map { ": \($0.localizedDescription)" } ?? ""
            throw WaxError.invalidToc(
                reason: "Metal command buffer failed with status \(commandBuffer.status)\(detail)"
            )
        }
    }

    private static func reductionThreadgroupSize(maxThreads: Int) -> Int {
        let capped = min(maxThreads, maxThreadsPerThreadgroup)
        var size = 1
        while size * 2 <= capped {
            size *= 2
        }
        return size
    }
}

#endif // canImport(Metal)
