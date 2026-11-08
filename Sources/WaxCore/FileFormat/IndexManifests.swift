import Foundation

package struct LexIndexManifest: Equatable, Sendable {
    package var docCount: UInt64
    package var bytesOffset: UInt64
    package var bytesLength: UInt64
    package var checksum: Data
    package var version: UInt32

    package init(
        docCount: UInt64,
        bytesOffset: UInt64,
        bytesLength: UInt64,
        checksum: Data,
        version: UInt32
    ) {
        self.docCount = docCount
        self.bytesOffset = bytesOffset
        self.bytesLength = bytesLength
        self.checksum = checksum
        self.version = version
    }
}

extension LexIndexManifest: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        encoder.encode(docCount)
        encoder.encode(bytesOffset)
        encoder.encode(bytesLength)
        guard checksum.count == 32 else {
            throw WaxError.encodingError(reason: "lex checksum must be 32 bytes (got \(checksum.count))")
        }
        encoder.encodeFixedBytes(checksum)
        encoder.encode(version)
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> LexIndexManifest {
        let docCount = try decoder.decode(UInt64.self)
        let bytesOffset = try decoder.decode(UInt64.self)
        let bytesLength = try decoder.decode(UInt64.self)
        let checksum = try decoder.decodeFixedBytes(count: 32)
        let version = try decoder.decode(UInt32.self)
        return LexIndexManifest(
            docCount: docCount,
            bytesOffset: bytesOffset,
            bytesLength: bytesLength,
            checksum: checksum,
            version: version
        )
    }
}

/// One vector run: a segment holding the vectors and removals one commit or merge wrote.
package struct VecRunManifest: Equatable, Sendable {
    package var bytesOffset: UInt64
    package var bytesLength: UInt64
    /// SHA-256 of the whole run.
    package var checksum: Data
    package var rowCount: UInt64
    package var tombstoneCount: UInt64
    /// 0 for a commit's run; a merge of runs writes one level up.
    package var level: UInt8
    /// Footer generation of the commit that wrote the run.
    package var addedGeneration: UInt64
    /// SHA-256 of the run's keys (frame-id byte count onward), so a commit can read them
    /// without the vectors. `nil` for a v1 store's vector blob until a commit records it.
    package var keysChecksum: Data?

    package init(
        bytesOffset: UInt64,
        bytesLength: UInt64,
        checksum: Data,
        rowCount: UInt64,
        tombstoneCount: UInt64,
        level: UInt8,
        addedGeneration: UInt64,
        keysChecksum: Data?
    ) {
        self.bytesOffset = bytesOffset
        self.bytesLength = bytesLength
        self.checksum = checksum
        self.rowCount = rowCount
        self.tombstoneCount = tombstoneCount
        self.level = level
        self.addedGeneration = addedGeneration
        self.keysChecksum = keysChecksum
    }
}

extension VecRunManifest: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        encoder.encode(bytesOffset)
        encoder.encode(bytesLength)
        guard checksum.count == 32 else {
            throw WaxError.encodingError(reason: "vec run checksum must be 32 bytes (got \(checksum.count))")
        }
        encoder.encodeFixedBytes(checksum)
        encoder.encode(rowCount)
        encoder.encode(tombstoneCount)
        encoder.encode(level)
        encoder.encode(addedGeneration)
        if let keysChecksum {
            guard keysChecksum.count == 32 else {
                throw WaxError.encodingError(reason: "vec run keys checksum must be 32 bytes (got \(keysChecksum.count))")
            }
            encoder.encode(UInt8(1))
            encoder.encodeFixedBytes(keysChecksum)
        } else {
            encoder.encode(UInt8(0))
        }
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> VecRunManifest {
        let bytesOffset = try decoder.decode(UInt64.self)
        let bytesLength = try decoder.decode(UInt64.self)
        let checksum = try decoder.decodeFixedBytes(count: 32)
        let rowCount = try decoder.decode(UInt64.self)
        let tombstoneCount = try decoder.decode(UInt64.self)
        let level = try decoder.decode(UInt8.self)
        let addedGeneration = try decoder.decode(UInt64.self)
        let keysTag = try decoder.decode(UInt8.self)
        let keysChecksum: Data?
        switch keysTag {
        case 0: keysChecksum = nil
        case 1: keysChecksum = try decoder.decodeFixedBytes(count: 32)
        default: throw WaxError.decodingError(reason: "invalid vec run keys checksum tag \(keysTag)")
        }
        return VecRunManifest(
            bytesOffset: bytesOffset,
            bytesLength: bytesLength,
            checksum: checksum,
            rowCount: rowCount,
            tombstoneCount: tombstoneCount,
            level: level,
            addedGeneration: addedGeneration,
            keysChecksum: keysChecksum
        )
    }
}

/// The committed vectors: runs applied oldest first (see `Wax+VectorRuns.swift`).
package struct VecIndexManifest: Equatable, Sendable {
    /// Frames with a vector after applying every run.
    package var vectorCount: UInt64
    package var dimension: UInt32
    package var similarity: VecSimilarity
    /// Oldest first.
    package var runs: [VecRunManifest]

    package init(vectorCount: UInt64, dimension: UInt32, similarity: VecSimilarity, runs: [VecRunManifest]) {
        self.vectorCount = vectorCount
        self.dimension = dimension
        self.similarity = similarity
        self.runs = runs
    }

    /// Optional tag of a v1 manifest: one whole-index blob.
    static let legacyTag: UInt8 = 1
    /// Optional tag of a manifest of runs.
    static let runsTag: UInt8 = 2

    mutating func encode(to encoder: inout BinaryEncoder) throws {
        encoder.encode(vectorCount)
        encoder.encode(dimension)
        encoder.encode(similarity.rawValue)
        encoder.encode(UInt32(runs.count))
        for index in runs.indices {
            try runs[index].encode(to: &encoder)
        }
    }

    static func decodeRuns(from decoder: inout BinaryDecoder) throws -> VecIndexManifest {
        let vectorCount = try decoder.decode(UInt64.self)
        let dimension = try decoder.decode(UInt32.self)
        let similarity = try decodeSimilarity(from: &decoder)
        let runCount = try decoder.decode(UInt32.self)
        var runs: [VecRunManifest] = []
        for _ in 0..<runCount {
            runs.append(try VecRunManifest.decode(from: &decoder))
        }
        return VecIndexManifest(vectorCount: vectorCount, dimension: dimension, similarity: similarity, runs: runs)
    }

    /// A v1 manifest: its blob has the layout of a run without tombstones, so it becomes the
    /// first run in place. Its keys checksum is recorded by the first commit that reads it.
    static func decodeLegacy(from decoder: inout BinaryDecoder) throws -> VecIndexManifest {
        let vectorCount = try decoder.decode(UInt64.self)
        let dimension = try decoder.decode(UInt32.self)
        let bytesOffset = try decoder.decode(UInt64.self)
        let bytesLength = try decoder.decode(UInt64.self)
        let checksum = try decoder.decodeFixedBytes(count: 32)
        let similarity = try decodeSimilarity(from: &decoder)
        let run = VecRunManifest(
            bytesOffset: bytesOffset,
            bytesLength: bytesLength,
            checksum: checksum,
            rowCount: vectorCount,
            tombstoneCount: 0,
            level: Wax.vecRunBaseLevel,
            addedGeneration: 0,
            keysChecksum: nil
        )
        return VecIndexManifest(vectorCount: vectorCount, dimension: dimension, similarity: similarity, runs: [run])
    }

    private static func decodeSimilarity(from decoder: inout BinaryDecoder) throws -> VecSimilarity {
        let similarityRaw = try decoder.decode(UInt8.self)
        guard let similarity = VecSimilarity(rawValue: similarityRaw) else {
            throw WaxError.invalidToc(reason: "vec similarity must be 0..2 (got \(similarityRaw))")
        }
        return similarity
    }
}

struct IndexManifests: Equatable, Sendable {
    package var lex: LexIndexManifest?
    package var vec: VecIndexManifest?

    package init(lex: LexIndexManifest? = nil, vec: VecIndexManifest? = nil) {
        self.lex = lex
        self.vec = vec
    }
}

extension IndexManifests: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        try encoder.encode(lex) { encoder, value in
            var mutable = value
            try mutable.encode(to: &encoder)
        }
        if var vec {
            encoder.encode(VecIndexManifest.runsTag)
            try vec.encode(to: &encoder)
        } else {
            encoder.encode(UInt8(0))
        }
        encoder.encode(UInt8(0)) // clip manifest absent in v1
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> IndexManifests {
        let lex = try decodeOptional(LexIndexManifest.self, from: &decoder)
        let vecTag = try decoder.decode(UInt8.self)
        let vec: VecIndexManifest?
        switch vecTag {
        case 0: vec = nil
        case VecIndexManifest.legacyTag: vec = try VecIndexManifest.decodeLegacy(from: &decoder)
        case VecIndexManifest.runsTag: vec = try VecIndexManifest.decodeRuns(from: &decoder)
        default: throw WaxError.decodingError(reason: "invalid optional tag \(vecTag)")
        }
        let clipTag = try decoder.decode(UInt8.self)
        guard clipTag == 0 else {
            throw WaxError.invalidToc(reason: "clip manifest not supported in v1")
        }
        return IndexManifests(lex: lex, vec: vec)
    }
}

private func decodeOptional<T: BinaryDecodable>(_ type: T.Type, from decoder: inout BinaryDecoder) throws -> T? {
    let tag = try decoder.decode(UInt8.self)
    switch tag {
    case 0:
        return nil
    case 1:
        return try T.decode(from: &decoder)
    default:
        throw WaxError.decodingError(reason: "invalid optional tag \(tag)")
    }
}
