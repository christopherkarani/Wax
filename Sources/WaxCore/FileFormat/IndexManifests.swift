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

package struct VecIndexManifest: Equatable, Sendable {
    package var vectorCount: UInt64
    package var dimension: UInt32
    package var bytesOffset: UInt64
    package var bytesLength: UInt64
    package var checksum: Data
    package var similarity: VecSimilarity

    package init(
        vectorCount: UInt64,
        dimension: UInt32,
        bytesOffset: UInt64,
        bytesLength: UInt64,
        checksum: Data,
        similarity: VecSimilarity
    ) {
        self.vectorCount = vectorCount
        self.dimension = dimension
        self.bytesOffset = bytesOffset
        self.bytesLength = bytesLength
        self.checksum = checksum
        self.similarity = similarity
    }
}

extension VecIndexManifest: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        encoder.encode(vectorCount)
        encoder.encode(dimension)
        encoder.encode(bytesOffset)
        encoder.encode(bytesLength)
        guard checksum.count == 32 else {
            throw WaxError.encodingError(reason: "vec checksum must be 32 bytes (got \(checksum.count))")
        }
        encoder.encodeFixedBytes(checksum)
        encoder.encode(similarity.rawValue)
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> VecIndexManifest {
        let vectorCount = try decoder.decode(UInt64.self)
        let dimension = try decoder.decode(UInt32.self)
        let bytesOffset = try decoder.decode(UInt64.self)
        let bytesLength = try decoder.decode(UInt64.self)
        let checksum = try decoder.decodeFixedBytes(count: 32)
        let similarityRaw = try decoder.decode(UInt8.self)
        guard let similarity = VecSimilarity(rawValue: similarityRaw) else {
            throw WaxError.invalidToc(reason: "vec similarity must be 0..2 (got \(similarityRaw))")
        }
        return VecIndexManifest(
            vectorCount: vectorCount,
            dimension: dimension,
            bytesOffset: bytesOffset,
            bytesLength: bytesLength,
            checksum: checksum,
            similarity: similarity
        )
    }
}

package struct IndexManifests: Equatable, Sendable {
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
        try encoder.encode(vec) { encoder, value in
            var mutable = value
            try mutable.encode(to: &encoder)
        }
        encoder.encode(UInt8(0)) // clip manifest absent in v1
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> IndexManifests {
        let lex = try decodeOptional(LexIndexManifest.self, from: &decoder)
        let vec = try decodeOptional(VecIndexManifest.self, from: &decoder)
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
