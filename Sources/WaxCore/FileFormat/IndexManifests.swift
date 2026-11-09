import Foundation

/// One lex run: the base image or a delta run (see ``LexRunCodec``).
package struct LexRunManifest: Equatable, Sendable {
    package var bytesOffset: UInt64
    package var bytesLength: UInt64
    /// SHA-256 of the whole run.
    package var checksum: Data
    /// Footer generation of the commit that wrote the run; 0 for an adopted v2 lex blob.
    package var addedGeneration: UInt64
    /// Length of the image after applying the run.
    package var imageLength: UInt64

    package init(bytesOffset: UInt64, bytesLength: UInt64, checksum: Data, addedGeneration: UInt64, imageLength: UInt64) {
        self.bytesOffset = bytesOffset
        self.bytesLength = bytesLength
        self.checksum = checksum
        self.addedGeneration = addedGeneration
        self.imageLength = imageLength
    }
}

extension LexRunManifest: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        encoder.encode(bytesOffset)
        encoder.encode(bytesLength)
        guard checksum.count == 32 else {
            throw WaxError.encodingError(reason: "lex run checksum must be 32 bytes (got \(checksum.count))")
        }
        encoder.encodeFixedBytes(checksum)
        encoder.encode(addedGeneration)
        encoder.encode(imageLength)
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> LexRunManifest {
        LexRunManifest(
            bytesOffset: try decoder.decode(UInt64.self),
            bytesLength: try decoder.decode(UInt64.self),
            checksum: try decoder.decodeFixedBytes(count: 32),
            addedGeneration: try decoder.decode(UInt64.self),
            imageLength: try decoder.decode(UInt64.self)
        )
    }
}

/// The committed text index: a base image and delta runs, applied oldest first (see
/// `Wax+LexRuns.swift`).
package struct LexIndexManifest: Equatable, Sendable {
    package var docCount: UInt64
    package var version: UInt32
    /// Page size of the delta runs; 0 while an adopted v2 blob has none.
    package var pageSize: UInt32
    /// The base first, then the deltas, oldest first.
    package var runs: [LexRunManifest]

    package init(docCount: UInt64, version: UInt32, pageSize: UInt32, runs: [LexRunManifest]) {
        self.docCount = docCount
        self.version = version
        self.pageSize = pageSize
        self.runs = runs
    }

    /// Length of the committed image.
    package var imageLength: UInt64 { runs.last?.imageLength ?? 0 }

    /// Optional tag of a v2 manifest: one whole-image blob.
    static let legacyTag: UInt8 = 1
    /// Optional tag of a manifest of runs.
    static let runsTag: UInt8 = 2

    mutating func encode(to encoder: inout BinaryEncoder) throws {
        encoder.encode(docCount)
        encoder.encode(version)
        encoder.encode(pageSize)
        encoder.encode(UInt32(runs.count))
        for index in runs.indices {
            try runs[index].encode(to: &encoder)
        }
    }

    static func decodeRuns(from decoder: inout BinaryDecoder) throws -> LexIndexManifest {
        let docCount = try decoder.decode(UInt64.self)
        let version = try decoder.decode(UInt32.self)
        let pageSize = try decoder.decode(UInt32.self)
        let runCount = try decoder.decode(UInt32.self)
        guard runCount > 0, runCount <= 1024 else {
            throw WaxError.decodingError(reason: "lex run count \(runCount) out of range")
        }
        var runs: [LexRunManifest] = []
        for _ in 0..<runCount {
            runs.append(try LexRunManifest.decode(from: &decoder))
        }
        return LexIndexManifest(docCount: docCount, version: version, pageSize: pageSize, runs: runs)
    }

    /// A v2 manifest: its blob is the raw image, so it becomes the base in place.
    static func decodeLegacy(from decoder: inout BinaryDecoder) throws -> LexIndexManifest {
        let docCount = try decoder.decode(UInt64.self)
        let bytesOffset = try decoder.decode(UInt64.self)
        let bytesLength = try decoder.decode(UInt64.self)
        let checksum = try decoder.decodeFixedBytes(count: 32)
        let version = try decoder.decode(UInt32.self)
        let base = LexRunManifest(
            bytesOffset: bytesOffset,
            bytesLength: bytesLength,
            checksum: checksum,
            addedGeneration: 0,
            imageLength: bytesLength
        )
        return LexIndexManifest(docCount: docCount, version: version, pageSize: 0, runs: [base])
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
        if var lex {
            encoder.encode(LexIndexManifest.runsTag)
            try lex.encode(to: &encoder)
        } else {
            encoder.encode(UInt8(0))
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
        let lexTag = try decoder.decode(UInt8.self)
        let lex: LexIndexManifest?
        switch lexTag {
        case 0: lex = nil
        case LexIndexManifest.legacyTag: lex = try LexIndexManifest.decodeLegacy(from: &decoder)
        case LexIndexManifest.runsTag: lex = try LexIndexManifest.decodeRuns(from: &decoder)
        default: throw WaxError.decodingError(reason: "invalid optional tag \(lexTag)")
        }
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
