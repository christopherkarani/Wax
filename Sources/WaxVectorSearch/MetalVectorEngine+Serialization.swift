#if canImport(Metal)
import Foundation
import Metal
import WaxCore

extension MetalVectorEngine {
    package func serialize() async throws -> Data {
        await withReadLock {
            var data = Data()

            data.append(contentsOf: [0x4D, 0x56, 0x32, 0x56])
            var version = UInt16(1).littleEndian
            withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
            data.append(UInt8(2))
            data.append(metric.toVecSimilarity().rawValue)
            var dims = UInt32(dimensions).littleEndian
            withUnsafeBytes(of: &dims) { data.append(contentsOf: $0) }
            var vecCount = vectorCount.littleEndian
            withUnsafeBytes(of: &vecCount) { data.append(contentsOf: $0) }

            // Read from Shared Vector Buffer
            let vectorDataCount = Int(vectorCount) * dimensions * MemoryLayout<Float>.stride
            var vecDataCountLE = UInt64(vectorDataCount).littleEndian
            withUnsafeBytes(of: &vecDataCountLE) { data.append(contentsOf: $0) }
            data.append(contentsOf: Data(repeating: 0, count: 8))
            
            // Should be efficient memcpy
            let basePtr = vectorsBuffer.contents()
            let vectorsData = Data(bytes: basePtr, count: vectorDataCount)
            data.append(vectorsData)

            let frameIdDataCount = frameIds.count * MemoryLayout<UInt64>.stride
            var frameIdDataCountLE = UInt64(frameIdDataCount).littleEndian
            withUnsafeBytes(of: &frameIdDataCountLE) { data.append(contentsOf: $0) }
            data.append(contentsOf: frameIds.withUnsafeBufferPointer { Data(buffer: $0) })

            return data
        }
    }

    package func deserialize(_ data: Data) async throws {
        try await withWriteLock {
            guard data.count >= 36 else {
                throw WaxError.invalidToc(reason: "Metal segment too small: \(data.count) bytes")
            }

            var offset = 0

            // Read and verify magic
            let magic = data[offset..<offset+4]
            offset += 4
            guard magic == Data([0x4D, 0x56, 0x32, 0x56]) else {
                throw WaxError.invalidToc(reason: "Metal segment magic mismatch")
            }

            // Read version
            let version = UInt16(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            })
            offset += 2
            guard version == 1 else {
                throw WaxError.invalidToc(reason: "Unsupported Metal segment version \(version)")
            }

            // Read encoding
            let encoding = data[offset]
            offset += 1
            guard encoding == 2 else {
                throw WaxError.invalidToc(reason: "Unsupported Metal segment encoding \(encoding)")
            }

            // Read similarity
            let similarityRaw = data[offset]
            offset += 1
            guard let similarity = VecSimilarity(rawValue: similarityRaw),
                  similarity == metric.toVecSimilarity() else {
                throw WaxError.invalidToc(reason: "Metric mismatch: expected \(metric.toVecSimilarity()), got \(similarityRaw)")
            }

            // Read dimensions
            let savedDimensions = UInt32(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            })
            offset += 4
            guard savedDimensions == UInt32(dimensions) else {
                throw WaxError.invalidToc(reason: "Dimension mismatch: expected \(dimensions), got \(savedDimensions)")
            }

            // Read vector count
            let savedVectorCount = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += 8

            let vectorLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += 8
            
            // Read reserved bytes
            let reserved = data[offset..<offset + 8]
            offset += 8
            guard reserved == Data(repeating: 0, count: 8) else {
                throw WaxError.invalidToc(reason: "Metal segment reserved bytes must be zero")
            }

            let vectorElementCount = savedVectorCount.multipliedReportingOverflow(by: UInt64(dimensions))
            let expectedVectorLength = vectorElementCount.partialValue.multipliedReportingOverflow(
                by: UInt64(MemoryLayout<Float>.stride)
            )
            guard !vectorElementCount.overflow,
                  !expectedVectorLength.overflow,
                  vectorLength == expectedVectorLength.partialValue,
                  vectorLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "Vector data length mismatch")
            }
            let vectorLengthInt = Int(vectorLength)
            guard data.count - offset >= vectorLengthInt + MemoryLayout<UInt64>.stride else {
                throw WaxError.invalidToc(reason: "Metal segment missing frameId length")
            }
            
            // Resize buffer for deserialized vectors.
            // Keep vectorCount = 0 during resize so resizeBuffersIfNeeded() does NOT
            // try to copy from the old (undersized) buffer — there are no existing
            // vectors to preserve during deserialization.
            reservedCapacity = max(reservedCapacity, UInt32(min(savedVectorCount, UInt64(UInt32.max))))
            try resizeBuffersIfNeeded(for: reservedCapacity)
            
            let destPtr = vectorsBuffer.contents()
            data.withUnsafeBytes { srcBuffer in
                 if let srcBase = srcBuffer.baseAddress {
                     destPtr.copyMemory(from: srcBase.advanced(by: offset), byteCount: vectorLengthInt)
                 }
            }
            offset += vectorLengthInt

            let frameIdLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += 8
            let expectedFrameIdLength = savedVectorCount.multipliedReportingOverflow(
                by: UInt64(MemoryLayout<UInt64>.stride)
            )
            guard !expectedFrameIdLength.overflow,
                  frameIdLength == expectedFrameIdLength.partialValue,
                  frameIdLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "FrameId data length mismatch")
            }
            let frameIdLengthInt = Int(frameIdLength)
            guard data.count - offset >= frameIdLengthInt else {
                throw WaxError.invalidToc(reason: "Metal segment missing frameId data")
            }
            let decodedFrameIds = data.withUnsafeBytes { rawBuffer in
                var decoded: [UInt64] = []
                decoded.reserveCapacity(Int(savedVectorCount))
                for byteOffset in stride(from: offset, to: offset + frameIdLengthInt, by: MemoryLayout<UInt64>.stride) {
                    decoded.append(UInt64(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt64.self)))
                }
                return decoded
            }
            try VectorSerializer.validateUniqueFrameIds(decodedFrameIds)
            offset += frameIdLengthInt
            guard offset == data.count else {
                throw WaxError.invalidToc(reason: "Metal segment has trailing bytes")
            }

            // Set vectorCount AFTER all structural validation succeeds.
            vectorCount = savedVectorCount
            frameIds = decodedFrameIds
            positions.removeAll(keepingCapacity: true)
            positions.reserveCapacity(decodedFrameIds.count)
            for (index, id) in decodedFrameIds.enumerated() {
                positions[id] = index
            }
            dirty = false
        }
    }

    /// Stage current state for commit to Wax.
    package func stageForCommit(into wax: Wax) async throws {
        if !dirty { return }
        let blob = try await serialize()
        try await wax.stageVecIndexForNextCommit(
            bytes: blob,
            vectorCount: vectorCount,
            dimension: UInt32(dimensions),
            similarity: metric.toVecSimilarity()
        )
        dirty = false
    }
}

#endif // canImport(Metal)
