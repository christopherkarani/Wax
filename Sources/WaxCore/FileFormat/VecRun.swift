import Foundation

/// One vector run: the vectors and removals a single commit (or merge) wrote.
///
/// Layout, little-endian, with the 36-byte header of the v1 vector blob:
/// `"MV2V"`, version `u16`, encoding `u8` (3 = flat), similarity `u8`, dimension `u32`,
/// row count `u64`, vector byte count `u64`, tombstone count `u64` (zero in a v1 blob);
/// then the row-major float32 vectors, the frame-id byte count `u64`, the row frame ids,
/// and the tombstoned frame ids. A v1 file's whole-index blob (version 1) is therefore a
/// run without tombstones, so migration adopts it in place.
///
/// Everything from the frame-id byte count on is the run's *keys*: what a commit reads to
/// know which frames have a vector, without reading the vectors.
package struct VecRun: Equatable, Sendable {
    package var dimension: UInt32
    package var similarity: VecSimilarity
    /// Frame ids of the rows, one per `dimension` floats of `vectors`.
    package var frameIds: [UInt64]
    /// Row-major float32 vectors.
    package var vectors: [Float]
    /// Frames whose vector in an older run this run removes. Disjoint from `frameIds`.
    package var tombstones: [UInt64]

    package init(
        dimension: UInt32,
        similarity: VecSimilarity,
        frameIds: [UInt64],
        vectors: [Float],
        tombstones: [UInt64]
    ) {
        self.dimension = dimension
        self.similarity = similarity
        self.frameIds = frameIds
        self.vectors = vectors
        self.tombstones = tombstones
    }
}

enum VecRunCodec {
    static let magic = Data([0x4D, 0x56, 0x32, 0x56])
    static let headerSize = 36
    /// A v1 file's whole-index vector blob.
    static let legacyVersion: UInt16 = 1
    static let runVersion: UInt16 = 2
    /// A USearch graph, written by builds before 1.0's flat and Metal encodings; not readable.
    static let legacyUSearchEncoding: UInt8 = 1
    static let metalEncoding: UInt8 = 2
    static let flatEncoding: UInt8 = 3

    /// Offset of the keys (frame-id byte count onward) in a run of `rowCount` rows.
    static func keysOffset(rowCount: UInt64, dimension: UInt32) throws -> UInt64 {
        let vectorBytes = try vectorByteCount(rowCount: rowCount, dimension: dimension)
        return UInt64(headerSize) + vectorBytes
    }

    static func encode(_ run: VecRun) throws -> Data {
        let dimension = Int(run.dimension)
        guard dimension > 0 else {
            throw WaxError.encodingError(reason: "vec run dimension must be > 0")
        }
        guard run.vectors.count == run.frameIds.count * dimension else {
            throw WaxError.encodingError(reason: "vec run vectors do not match its frame ids")
        }
        try validateKeys(frameIds: run.frameIds, tombstones: run.tombstones)
        let vectorBytes = run.vectors.count * MemoryLayout<Float>.stride
        let frameIdBytes = run.frameIds.count * MemoryLayout<UInt64>.stride
        let tombstoneBytes = run.tombstones.count * MemoryLayout<UInt64>.stride
        let total = headerSize + vectorBytes + MemoryLayout<UInt64>.stride + frameIdBytes + tombstoneBytes

        var data = Data(count: total)
        data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            let base = output.baseAddress!
            magic.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: 4) }
            output.storeBytes(of: runVersion.littleEndian, toByteOffset: 4, as: UInt16.self)
            output[6] = flatEncoding
            output[7] = run.similarity.rawValue
            output.storeBytes(of: run.dimension.littleEndian, toByteOffset: 8, as: UInt32.self)
            output.storeBytes(of: UInt64(run.frameIds.count).littleEndian, toByteOffset: 12, as: UInt64.self)
            output.storeBytes(of: UInt64(vectorBytes).littleEndian, toByteOffset: 20, as: UInt64.self)
            output.storeBytes(of: UInt64(run.tombstones.count).littleEndian, toByteOffset: 28, as: UInt64.self)
            var offset = headerSize
            run.vectors.withUnsafeBytes { raw in
                if let source = raw.baseAddress {
                    (base + offset).copyMemory(from: source, byteCount: vectorBytes)
                }
            }
            offset += vectorBytes
            output.storeBytes(of: UInt64(frameIdBytes).littleEndian, toByteOffset: offset, as: UInt64.self)
            offset += MemoryLayout<UInt64>.stride
            for frameId in run.frameIds {
                output.storeBytes(of: frameId.littleEndian, toByteOffset: offset, as: UInt64.self)
                offset += MemoryLayout<UInt64>.stride
            }
            for frameId in run.tombstones {
                output.storeBytes(of: frameId.littleEndian, toByteOffset: offset, as: UInt64.self)
                offset += MemoryLayout<UInt64>.stride
            }
        }
        return data
    }

    struct Header: Equatable {
        var version: UInt16
        var similarity: VecSimilarity
        var dimension: UInt32
        var rowCount: UInt64
        var tombstoneCount: UInt64
    }

    static func decodeHeader(_ data: Data) throws -> Header {
        guard data.count >= headerSize else {
            throw WaxError.invalidToc(reason: "vec run too small: \(data.count) bytes")
        }
        guard data.prefix(4) == magic else {
            throw WaxError.invalidToc(reason: "vec run magic mismatch")
        }
        func load<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
            T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
        }
        let version = load(4, UInt16.self)
        let encoding = data[data.startIndex + 6]
        switch version {
        case legacyVersion:
            guard encoding != legacyUSearchEncoding else {
                throw WaxError.invalidToc(
                    reason: "Legacy USearch vector index is unsupported; rebuild the vector index."
                )
            }
            guard encoding == metalEncoding || encoding == flatEncoding else {
                throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(encoding)")
            }
        case runVersion:
            guard encoding == flatEncoding else {
                throw WaxError.invalidToc(reason: "unsupported vec run encoding \(encoding)")
            }
        default:
            throw WaxError.invalidToc(reason: "unsupported vec segment version \(version)")
        }
        let similarityRaw = data[data.startIndex + 7]
        guard let similarity = VecSimilarity(rawValue: similarityRaw) else {
            throw WaxError.invalidToc(reason: "vec similarity must be 0..2 (got \(similarityRaw))")
        }
        let dimension = load(8, UInt32.self)
        guard dimension > 0, dimension <= UInt32(Constants.maxEmbeddingDimensions) else {
            throw WaxError.invalidToc(reason: "vec run dimension \(dimension) out of range")
        }
        let rowCount = load(12, UInt64.self)
        let vectorBytes = load(20, UInt64.self)
        guard vectorBytes == (try vectorByteCount(rowCount: rowCount, dimension: dimension)) else {
            throw WaxError.invalidToc(reason: "vec vector data length mismatch")
        }
        let tombstoneCount = load(28, UInt64.self)
        guard version == runVersion || tombstoneCount == 0 else {
            throw WaxError.invalidToc(reason: "vec segment reserved bytes must be zero")
        }
        return Header(
            version: version,
            similarity: similarity,
            dimension: dimension,
            rowCount: rowCount,
            tombstoneCount: tombstoneCount
        )
    }

    /// Decodes a whole run, `data` being exactly its bytes.
    static func decode(_ data: Data) throws -> VecRun {
        let header = try decodeHeader(data)
        let keysOffset = try keysOffset(rowCount: header.rowCount, dimension: header.dimension)
        guard UInt64(data.count) >= keysOffset else {
            throw WaxError.invalidToc(reason: "vec run truncated before its keys")
        }
        let keys = try decodeKeys(
            data.subdata(in: (data.startIndex + Int(keysOffset))..<data.endIndex),
            rowCount: header.rowCount,
            tombstoneCount: header.tombstoneCount
        )
        let vectorCount = Int(header.rowCount) * Int(header.dimension)
        let vectors: [Float] = data.withUnsafeBytes { raw in
            [Float](unsafeUninitializedCapacity: vectorCount) { buffer, initialized in
                UnsafeMutableRawBufferPointer(buffer).copyMemory(
                    from: UnsafeRawBufferPointer(rebasing: raw[headerSize..<(headerSize + vectorCount * 4)])
                )
                initialized = vectorCount
            }
        }
        return VecRun(
            dimension: header.dimension,
            similarity: header.similarity,
            frameIds: keys.frameIds,
            vectors: vectors,
            tombstones: keys.tombstones
        )
    }

    /// Decodes a run's keys: its bytes from the frame-id byte count to the end.
    static func decodeKeys(
        _ keys: Data,
        rowCount: UInt64,
        tombstoneCount: UInt64
    ) throws -> (frameIds: [UInt64], tombstones: [UInt64]) {
        let stride = UInt64(MemoryLayout<UInt64>.stride)
        let (frameIdBytes, frameOverflow) = rowCount.multipliedReportingOverflow(by: stride)
        let (tombstoneBytes, tombstoneOverflow) = tombstoneCount.multipliedReportingOverflow(by: stride)
        guard !frameOverflow, !tombstoneOverflow,
              frameIdBytes <= UInt64(Int.max) / 2, tombstoneBytes <= UInt64(Int.max) / 2
        else {
            throw WaxError.invalidToc(reason: "vec run key count overflows")
        }
        guard UInt64(keys.count) == stride + frameIdBytes + tombstoneBytes else {
            throw WaxError.invalidToc(reason: "vec run length mismatch")
        }
        func load(_ offset: Int) -> UInt64 {
            UInt64(littleEndian: keys.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) })
        }
        guard load(0) == frameIdBytes else {
            throw WaxError.invalidToc(reason: "vec frameId data length mismatch")
        }
        let rows = Int(rowCount)
        let frameIds = (0..<rows).map { load(8 + $0 * 8) }
        let tombstones = (0..<Int(tombstoneCount)).map { load(8 + (rows + $0) * 8) }
        try validateKeys(frameIds: frameIds, tombstones: tombstones)
        return (frameIds, tombstones)
    }

    private static func validateKeys(frameIds: [UInt64], tombstones: [UInt64]) throws {
        var seen = Set<UInt64>()
        seen.reserveCapacity(frameIds.count + tombstones.count)
        for frameId in frameIds {
            guard seen.insert(frameId).inserted else {
                throw WaxError.invalidToc(reason: "vec frameIds contain duplicate id \(frameId)")
            }
        }
        for frameId in tombstones {
            guard seen.insert(frameId).inserted else {
                throw WaxError.invalidToc(reason: "vec run tombstones repeat or overlap id \(frameId)")
            }
        }
    }

    private static func vectorByteCount(rowCount: UInt64, dimension: UInt32) throws -> UInt64 {
        let (floats, floatOverflow) = rowCount.multipliedReportingOverflow(by: UInt64(dimension))
        let (bytes, byteOverflow) = floats.multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.stride))
        guard !floatOverflow, !byteOverflow, bytes <= UInt64(Int.max) / 2 else {
            throw WaxError.invalidToc(reason: "vec vector data length overflow")
        }
        return bytes
    }
}
