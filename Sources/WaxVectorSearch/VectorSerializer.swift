import Foundation
import USearch
import WaxCore

public enum VectorSerializer {
    public struct SegmentInfo: Sendable, Equatable {
        public var similarity: VecSimilarity
        public var dimension: UInt32
        public var vectorCount: UInt64
        public var payloadLength: UInt64

        public init(similarity: VecSimilarity, dimension: UInt32, vectorCount: UInt64, payloadLength: UInt64) {
            self.similarity = similarity
            self.dimension = dimension
            self.vectorCount = vectorCount
            self.payloadLength = payloadLength
        }
    }

    public enum VecSegmentPayload: Sendable, Equatable {
        case uSearch(info: SegmentInfo, payload: Data)
        case metal(info: SegmentInfo, vectors: [Float], frameIds: [UInt64])
    }

    public static func serializeUSearchIndex(
        _ index: USearchIndex,
        metric: VectorMetric,
        dimensions: Int,
        vectorCount: UInt64
    ) throws -> Data {
        let payload = try saveUSearchPayload(index)
        let header = VecSegmentHeaderV1(
            similarity: metric.toVecSimilarity(),
            dimension: UInt32(dimensions),
            vectorCount: vectorCount,
            payloadLength: UInt64(payload.count)
        )
        var encoder = BinaryEncoder()
        header.encode(to: &encoder)
        var data = encoder.data
        data.append(payload)
        return data
    }

    public static func decodeUSearchPayload(from data: Data) throws -> (info: SegmentInfo, payload: Data) {
        let payload = try decodeVecSegment(from: data)
        switch payload {
        case .uSearch(let info, let bytes):
            return (info, bytes)
        case .metal:
            throw WaxError.invalidToc(reason: "vec segment encoding is metal; USearch payload unavailable")
        }
    }

    public static func decodeVecSegment(from data: Data) throws -> VecSegmentPayload {
        guard data.count >= VecSegmentHeaderV1.encodedSize else {
            throw WaxError.invalidToc(reason: "vec segment too small: \(data.count) bytes")
        }

        let headerBytes = data.prefix(VecSegmentHeaderV1.encodedSize)
        var headerDecoder = try BinaryDecoder(data: Data(headerBytes))
        let header = try VecSegmentHeaderV1.decodeAnyEncoding(from: &headerDecoder)
        try headerDecoder.finalize()

        let info = SegmentInfo(
            similarity: header.similarity,
            dimension: header.dimension,
            vectorCount: header.vectorCount,
            payloadLength: header.payloadLength
        )

        switch header.encoding {
        case 1:
            guard header.payloadLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "vec payload_length exceeds Int.max: \(header.payloadLength)")
            }
            let expectedTotal = VecSegmentHeaderV1.encodedSize + Int(header.payloadLength)
            guard data.count == expectedTotal else {
                throw WaxError.invalidToc(reason: "vec segment length mismatch: expected \(expectedTotal), got \(data.count)")
            }
            let payload = data.suffix(Int(header.payloadLength))
            return .uSearch(info: info, payload: payload)
        case 2:
            guard header.payloadLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "vec payload_length exceeds Int.max: \(header.payloadLength)")
            }
            let vectorLength = Int(header.payloadLength)
            let expectedVectorBytes = Int(header.vectorCount) * Int(header.dimension) * MemoryLayout<Float>.stride
            guard vectorLength == expectedVectorBytes else {
                throw WaxError.invalidToc(reason: "vec vector data length mismatch")
            }

            var offset = VecSegmentHeaderV1.encodedSize
            guard data.count >= offset + vectorLength + MemoryLayout<UInt64>.stride else {
                throw WaxError.invalidToc(reason: "vec segment missing frameIds length")
            }

            let vectorsData = data[offset..<offset + vectorLength]
            offset += vectorLength

            let frameIdLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += MemoryLayout<UInt64>.stride
            guard frameIdLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "vec frameId length exceeds Int.max: \(frameIdLength)")
            }
            let expectedFrameIdBytes = Int(header.vectorCount) * MemoryLayout<UInt64>.stride
            guard Int(frameIdLength) == expectedFrameIdBytes else {
                throw WaxError.invalidToc(reason: "vec frameId data length mismatch")
            }
            let expectedTotal = offset + Int(frameIdLength)
            guard data.count == expectedTotal else {
                throw WaxError.invalidToc(reason: "vec segment length mismatch: expected \(expectedTotal), got \(data.count)")
            }

            let vectors = Array(vectorsData.withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            })
            let frameIds = Array(data[offset..<offset + Int(frameIdLength)].withUnsafeBytes {
                Array($0.bindMemory(to: UInt64.self))
            })

            return .metal(info: info, vectors: vectors, frameIds: frameIds)
        default:
            throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(header.encoding)")
        }
    }

    /// Loads the index directly from an in-memory buffer.
    /// This is ~10-100x faster than the file-based approach.
    public static func loadUSearchIndex(_ index: USearchIndex, fromPayload payload: Data) throws {
        // Use buffer-based loading (no temp file I/O)
        try index.deserializeFromData(payload)
    }

    // MARK: - Private

    /// Serializes the index directly to an in-memory buffer.
    /// This is ~10-100x faster than the file-based approach.
    private static func saveUSearchPayload(_ index: USearchIndex) throws -> Data {
        // Use buffer-based saving (no temp file I/O)
        try index.serializeToData()
    }

    private struct VecSegmentHeaderV1 {
        static let encodedSize: Int = 36
        static let magic = Data([0x4D, 0x56, 0x32, 0x56]) // "MV2V"

        var version: UInt16 = 1
        var encoding: UInt8 = 1 // 1 = usearch
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

        static func decode(from decoder: inout BinaryDecoder) throws -> VecSegmentHeaderV1 {
            let header = try decodeAnyEncoding(from: &decoder)
            guard header.encoding == 1 else {
                throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(header.encoding)")
            }
            return header
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
            guard encoding == 1 || encoding == 2 else {
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

