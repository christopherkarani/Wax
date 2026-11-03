#if canImport(Metal)
import Foundation
import Metal
import WaxCore

extension MetalVectorEngine {
    package func add(frameId: UInt64, vector: [Float]) async throws {
        try await withWriteLock {
            try validate(vector)

            if let existingIndex = positions[frameId] {
                // Determine offset in shared buffer
                let offset = existingIndex * dimensions
                let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)
                for dim in 0..<dimensions {
                    basePtr[offset + dim] = vector[dim]
                }
            } else {
                try await reserveIfNeeded(for: vectorCount + 1)
                
                // Append using pointer arithmetic on shared buffer
                let offset = Int(vectorCount) * dimensions
                let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)
                for dim in 0..<dimensions {
                    basePtr[offset + dim] = vector[dim]
                }
                
                positions[frameId] = frameIds.count
                frameIds.append(frameId)
                vectorCount += 1
            }

            dirty = true
        }
    }

    package func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatch: frameIds.count != vectors.count")
        }

        try await withWriteLock {
            for vector in vectors {
                try validate(vector)
            }

            let maxNewCount = vectorCount + UInt64(frameIds.count)
            try await reserveIfNeeded(for: maxNewCount)
            
            let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)

            self.positions.reserveCapacity(Int(maxNewCount))
            for (frameId, vector) in zip(frameIds, vectors) {
                if let existingIndex = self.positions[frameId] {
                    let offset = existingIndex * dimensions
                    for dim in 0..<dimensions {
                        basePtr[offset + dim] = vector[dim]
                    }
                } else {
                    let offset = Int(vectorCount) * dimensions
                    for dim in 0..<dimensions {
                        basePtr[offset + dim] = vector[dim]
                    }
                    self.positions[frameId] = self.frameIds.count
                    self.frameIds.append(frameId)
                    vectorCount += 1
                }
            }

            dirty = true
        }
    }

    package func addBatchStreaming(frameIds: [UInt64], vectors: [[Float]], chunkSize: Int = 256) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatchStreaming: frameIds.count != vectors.count")
        }

        guard frameIds.count > chunkSize else {
            try await addBatch(frameIds: frameIds, vectors: vectors)
            return
        }

        for start in stride(from: 0, to: frameIds.count, by: chunkSize) {
            let end = min(start + chunkSize, frameIds.count)
            let chunkFrameIds = Array(frameIds[start..<end])
            let chunkVectors = Array(vectors[start..<end])
            try await addBatch(frameIds: chunkFrameIds, vectors: chunkVectors)
        }
    }

    package func remove(frameId: UInt64) async throws {
        await withWriteLock {
            guard vectorCount > 0 else { return }
            guard let index = positions[frameId] else { return }

            // To efficiently remove, we need to shift all subsequent vectors.
            // memmove is efficient for this.
            
            let countAfter = Int(vectorCount) - 1 - index
            if countAfter > 0 {
                let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)
                let dst = basePtr.advanced(by: index * dimensions)
                let src = basePtr.advanced(by: (index + 1) * dimensions)
                // Overlap exists, move is required
                dst.moveUpdate(from: src, count: countAfter * dimensions)
            }
            
            positions.removeValue(forKey: frameId)
            frameIds.remove(at: index)
            for next in index..<frameIds.count {
                positions[frameIds[next]] = next
            }
            vectorCount -= 1
            dirty = true
        }
    }

    func validate(_ vector: [Float]) throws {
        try VectorValidation.validate(vector, dimensions: dimensions)
    }
}

#endif // canImport(Metal)
