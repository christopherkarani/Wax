import Foundation
import WaxCore
#if canImport(os)
import os
#endif

package enum VectorSerializer {
    package struct SegmentInfo: Sendable, Equatable {
        package var similarity: VecSimilarity
        package var dimension: UInt32
        package var vectorCount: UInt64
        package var payloadLength: UInt64
        /// Rows dropped while decoding because a vector component was NaN or infinite.
        /// `vectorCount` and `payloadLength` describe the rows that were kept.
        package var droppedNonFiniteRowCount: Int

        package init(
            similarity: VecSimilarity,
            dimension: UInt32,
            vectorCount: UInt64,
            payloadLength: UInt64,
            droppedNonFiniteRowCount: Int = 0
        ) {
            self.similarity = similarity
            self.dimension = dimension
            self.vectorCount = vectorCount
            self.payloadLength = payloadLength
            self.droppedNonFiniteRowCount = droppedNonFiniteRowCount
        }
    }

    package enum VecSegmentPayload: Sendable, Equatable {
        case metal(info: SegmentInfo, vectors: [Float], frameIds: [UInt64])
    }

    package enum VecEncoding: UInt8, Sendable {
        case uSearch = 1
        case metal = 2
        case flat = 3
    }

    package static func detectEncoding(from data: Data) throws -> VecEncoding {
        guard data.count >= 8 else {
            throw WaxError.invalidToc(reason: "vec segment too small: \(data.count) bytes")
        }
        let magic = data.prefix(4)
        guard magic == VecSegmentHeaderV1.magic else {
            throw WaxError.invalidToc(reason: "vec segment magic mismatch")
        }
        let version = UInt16(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
        })
        guard version == 1 else {
            throw WaxError.invalidToc(reason: "unsupported vec segment version \(version)")
        }
        let encodingRaw = data[data.startIndex + 6]
        guard let encoding = VecEncoding(rawValue: encodingRaw) else {
            throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(encodingRaw)")
        }
        return encoding
    }

    package static func serializeFlatVectors(
        _ vectors: [Float],
        frameIds: [UInt64],
        metric: VectorMetric,
        dimensions: Int
    ) throws -> Data {
        guard dimensions > 0 else {
            throw WaxError.invalidToc(reason: "dimensions must be > 0")
        }
        guard vectors.count == frameIds.count * dimensions else {
            throw WaxError.invalidToc(reason: "flat vector payload mismatch")
        }
        try validateUniqueFrameIds(frameIds)

        let vectorBytes = vectors.count * MemoryLayout<Float>.stride
        let frameIdBytes = frameIds.count * MemoryLayout<UInt64>.stride
        var header = VecSegmentHeaderV1(
            similarity: metric.toVecSimilarity(),
            dimension: UInt32(dimensions),
            vectorCount: UInt64(frameIds.count),
            payloadLength: UInt64(vectorBytes)
        )
        header.encoding = VecEncoding.flat.rawValue

        var encoder = BinaryEncoder()
        header.encode(to: &encoder)
        var data = encoder.data
        data.append(vectors.withUnsafeBufferPointer { Data(buffer: $0) })

        var frameIdBytesLE = UInt64(frameIdBytes).littleEndian
        withUnsafeBytes(of: &frameIdBytesLE) { data.append(contentsOf: $0) }
        data.append(frameIds.withUnsafeBufferPointer { Data(buffer: $0) })
        return data
    }

    package static func decodeVecSegment(from data: Data) throws -> VecSegmentPayload {
        guard data.count >= VecSegmentHeaderV1.encodedSize else {
            throw WaxError.invalidToc(reason: "vec segment too small: \(data.count) bytes")
        }

        let headerBytes = data.prefix(VecSegmentHeaderV1.encodedSize)
        var headerDecoder = try BinaryDecoder(data: Data(headerBytes))
        let header = try VecSegmentHeaderV1.decodeAnyEncoding(from: &headerDecoder)
        try headerDecoder.finalize()

        var info = SegmentInfo(
            similarity: header.similarity,
            dimension: header.dimension,
            vectorCount: header.vectorCount,
            payloadLength: header.payloadLength
        )

        switch header.encoding {
        case VecEncoding.uSearch.rawValue:
            throw WaxError.invalidToc(reason: Self.legacyUSearchUnsupportedReason)
        case VecEncoding.metal.rawValue, VecEncoding.flat.rawValue:
            guard header.payloadLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "vec payload_length exceeds Int.max: \(header.payloadLength)")
            }
            let vectorLength = Int(header.payloadLength)
            let expectedVectorBytes = try checkedVectorByteCount(
                vectorCount: header.vectorCount,
                dimension: header.dimension
            )
            guard header.payloadLength == expectedVectorBytes else {
                throw WaxError.invalidToc(reason: "vec vector data length mismatch")
            }

            // Offsets below are relative to data.startIndex (data may be a slice).
            var offset = VecSegmentHeaderV1.encodedSize
            let frameIdLengthOffset = offset + vectorLength
            guard data.count >= frameIdLengthOffset + MemoryLayout<UInt64>.stride else {
                throw WaxError.invalidToc(reason: "vec segment missing frameIds length")
            }

            let vectorsOffset = offset
            offset += vectorLength

            let frameIdLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += MemoryLayout<UInt64>.stride
            guard frameIdLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "vec frameId length exceeds Int.max: \(frameIdLength)")
            }
            let expectedFrameIdBytes = try checkedFrameIdByteCount(vectorCount: header.vectorCount)
            guard frameIdLength == expectedFrameIdBytes else {
                throw WaxError.invalidToc(reason: "vec frameId data length mismatch")
            }
            let expectedTotal = offset + Int(frameIdLength)
            guard data.count == expectedTotal else {
                throw WaxError.invalidToc(reason: "vec segment length mismatch: expected \(expectedTotal), got \(data.count)")
            }

            var vectors: [Float] = copyUnaligned(
                from: data,
                byteOffset: vectorsOffset,
                count: vectorLength / MemoryLayout<Float>.stride
            )
            var frameIds: [UInt64] = copyUnaligned(
                from: data,
                byteOffset: offset,
                count: Int(frameIdLength) / MemoryLayout<UInt64>.stride
            )
            try validateUniqueFrameIds(frameIds)

            // Stores written before inserts rejected NaN/Inf can contain non-finite rows.
            // Drop them (vector and frameId together) instead of failing the whole load.
            let dropped = dropNonFiniteRows(
                vectors: &vectors,
                frameIds: &frameIds,
                dimension: Int(header.dimension)
            )
            if dropped > 0 {
                info.droppedNonFiniteRowCount = dropped
                info.vectorCount = UInt64(frameIds.count)
                info.payloadLength = UInt64(vectors.count * MemoryLayout<Float>.stride)
                logDroppedNonFiniteRows(dropped, of: Int(header.vectorCount))
            }

            return .metal(info: info, vectors: vectors, frameIds: frameIds)
        default:
            throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(header.encoding)")
        }
    }

    /// Removes rows whose vector contains NaN or infinity. Returns the number removed.
    private static func dropNonFiniteRows(
        vectors: inout [Float],
        frameIds: inout [UInt64],
        dimension: Int
    ) -> Int {
        guard dimension > 0, !vectors.allSatisfy(\.isFinite) else { return 0 }
        var keptVectors: [Float] = []
        var keptFrameIds: [UInt64] = []
        keptVectors.reserveCapacity(vectors.count)
        keptFrameIds.reserveCapacity(frameIds.count)
        for (row, frameId) in frameIds.enumerated() {
            let start = row * dimension
            let rowValues = vectors[start..<(start + dimension)]
            guard rowValues.allSatisfy(\.isFinite) else { continue }
            keptVectors.append(contentsOf: rowValues)
            keptFrameIds.append(frameId)
        }
        let dropped = frameIds.count - keptFrameIds.count
        vectors = keptVectors
        frameIds = keptFrameIds
        return dropped
    }

    private static func logDroppedNonFiniteRows(_ dropped: Int, of total: Int) {
        #if canImport(os)
        Logger(subsystem: "com.wax.vectorsearch", category: "VectorSerializer").warning(
            "Dropped \(dropped, privacy: .public) of \(total, privacy: .public) vec index rows with non-finite values; the index is rewritten on the next commit"
        )
        #else
        let message = "Wax: dropped \(dropped) of \(total) vec index rows with non-finite values\n"
        FileHandle.standardError.write(Data(message.utf8))
        #endif
    }

    /// Copies `count` trivially-typed elements starting at `byteOffset` (relative to
    /// `data.startIndex`) into a properly aligned array. Never binds the source bytes
    /// to `T`, so it is safe for slices and arbitrarily aligned offsets.
    private static func copyUnaligned<T: BitwiseCopyable>(from data: Data, byteOffset: Int, count: Int) -> [T] {
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            [T](unsafeUninitializedCapacity: count) { buffer, initializedCount in
                let byteCount = count * MemoryLayout<T>.stride
                UnsafeMutableRawBufferPointer(buffer).copyMemory(
                    from: UnsafeRawBufferPointer(rebasing: raw[byteOffset..<byteOffset + byteCount])
                )
                initializedCount = count
            }
        }
    }

    private static func checkedVectorByteCount(vectorCount: UInt64, dimension: UInt32) throws -> UInt64 {
        let dimProduct = vectorCount.multipliedReportingOverflow(by: UInt64(dimension))
        guard !dimProduct.overflow else {
            throw WaxError.invalidToc(reason: "vec vector data length overflow")
        }
        let byteProduct = dimProduct.partialValue.multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.stride))
        guard !byteProduct.overflow else {
            throw WaxError.invalidToc(reason: "vec vector data length overflow")
        }
        guard byteProduct.partialValue <= UInt64(Int.max) else {
            throw WaxError.invalidToc(reason: "vec vector data length exceeds Int.max: \(byteProduct.partialValue)")
        }
        return byteProduct.partialValue
    }

    private static func checkedFrameIdByteCount(vectorCount: UInt64) throws -> UInt64 {
        let byteProduct = vectorCount.multipliedReportingOverflow(by: UInt64(MemoryLayout<UInt64>.stride))
        guard !byteProduct.overflow else {
            throw WaxError.invalidToc(reason: "vec frameId data length overflow")
        }
        guard byteProduct.partialValue <= UInt64(Int.max) else {
            throw WaxError.invalidToc(reason: "vec frameId data length exceeds Int.max: \(byteProduct.partialValue)")
        }
        return byteProduct.partialValue
    }

    package static func validateUniqueFrameIds(_ frameIds: [UInt64]) throws {
        var seen = Set<UInt64>()
        seen.reserveCapacity(frameIds.count)
        for frameId in frameIds {
            guard seen.insert(frameId).inserted else {
                throw WaxError.invalidToc(reason: "vec frameIds contain duplicate id \(frameId)")
            }
        }
    }

    package static let legacyUSearchUnsupportedReason =
        "Legacy USearch vector index is unsupported; rebuild the vector index."

    private struct VecSegmentHeaderV1 {
        static let encodedSize: Int = 36
        static let magic = Data([0x4D, 0x56, 0x32, 0x56])

        var version: UInt16 = 1
        var encoding: UInt8 = 1
        var similarity: VecSimilarity
        var dimension: UInt32
        var vectorCount: UInt64
        var payloadLength: UInt64

        init(similarity: VecSimilarity, dimension: UInt32, vectorCount: UInt64, payloadLength: UInt64) {
            self.similarity = similarity
            self.dimension = dimension
            self.vectorCount = vectorCount
            self.payloadLength = payloadLength
        }

        func encode(to encoder: inout BinaryEncoder) {
            encoder.encodeFixedBytes(Self.magic)
            encoder.encode(version)
            encoder.encode(encoding)
            encoder.encode(similarity.rawValue)
            encoder.encode(dimension)
            encoder.encode(vectorCount)
            encoder.encode(payloadLength)
            encoder.encodeFixedBytes(Data(repeating: 0, count: 8))
        }

        static func decodeAnyEncoding(from decoder: inout BinaryDecoder) throws -> VecSegmentHeaderV1 {
            let magic = try decoder.decodeFixedBytes(count: 4)
            guard magic == Self.magic else {
                throw WaxError.invalidToc(reason: "vec segment magic mismatch")
            }

            let version = try decoder.decode(UInt16.self)
            guard version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported vec segment version \(version)")
            }

            let encoding = try decoder.decode(UInt8.self)
            guard encoding == VecEncoding.uSearch.rawValue
                || encoding == VecEncoding.metal.rawValue
                || encoding == VecEncoding.flat.rawValue else {
                throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(encoding)")
            }

            let similarityRaw = try decoder.decode(UInt8.self)
            guard let similarity = VecSimilarity(rawValue: similarityRaw) else {
                throw WaxError.invalidToc(reason: "vec similarity must be 0..2 (got \(similarityRaw))")
            }

            let dimension = try decoder.decode(UInt32.self)
            let vectorCount = try decoder.decode(UInt64.self)
            let payloadLength = try decoder.decode(UInt64.self)
            let reserved = try decoder.decodeFixedBytes(count: 8)
            guard reserved == Data(repeating: 0, count: 8) else {
                throw WaxError.invalidToc(reason: "vec segment reserved bytes must be zero")
            }

            var header = VecSegmentHeaderV1(
                similarity: similarity,
                dimension: dimension,
                vectorCount: vectorCount,
                payloadLength: payloadLength
            )
            header.version = version
            header.encoding = encoding
            return header
        }
    }
}
