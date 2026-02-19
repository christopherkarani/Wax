import Foundation

public enum WALEntryCodec {
    public enum OpCode: UInt8 {
        case putFrame = 0x01
        case deleteFrame = 0x02
        case supersedeFrame = 0x03
        case putEmbedding = 0x04
    }

    public static func encode(_ entry: WALEntry) throws -> Data {
        var encoder = BinaryEncoder()
        switch entry {
        case .putFrame(let put):
            encoder.encode(OpCode.putFrame.rawValue)
            encoder.encode(put.frameId)
            encoder.encode(put.timestampMs)
            var options = put.options
            try options.encode(to: &encoder)
            encoder.encode(put.payloadOffset)
            encoder.encode(put.payloadLength)
            encoder.encode(put.canonicalEncoding.rawValue)
            encoder.encode(put.canonicalLength)
            guard put.canonicalChecksum.count == WALRecord.checksumSize else {
                throw WaxError.encodingError(reason: "canonical_checksum must be 32 bytes")
            }
            guard put.storedChecksum.count == WALRecord.checksumSize else {
                throw WaxError.encodingError(reason: "stored_checksum must be 32 bytes")
            }
            encoder.encodeFixedBytes(put.canonicalChecksum)
            encoder.encodeFixedBytes(put.storedChecksum)
        case .deleteFrame(let delete):
            encoder.encode(OpCode.deleteFrame.rawValue)
            encoder.encode(delete.frameId)
        case .supersedeFrame(let supersede):
            encoder.encode(OpCode.supersedeFrame.rawValue)
            encoder.encode(supersede.supersededId)
            encoder.encode(supersede.supersedingId)
        case .putEmbedding(let embedding):
            encoder.encode(OpCode.putEmbedding.rawValue)
            encoder.encode(embedding.frameId)
            encoder.encode(embedding.dimension)
            guard Int(embedding.dimension) == embedding.vector.count else {
                throw WaxError.encodingError(reason: "embedding dimension mismatch")
            }
            guard embedding.vector.count <= Constants.maxEmbeddingDimensions else {
                throw WaxError.encodingError(reason: "embedding dimension exceeds limit")
            }
            // Bulk copy: safe on little-endian platforms (all Apple targets).
            let floatBytes = embedding.vector.withUnsafeBufferPointer { buf in
                Data(buffer: buf)
            }
            encoder.encodeFixedBytes(floatBytes)
        }

        return encoder.data
    }

    public static func decode(_ payload: Data, offset: UInt64) throws -> WALEntry {
        do {
            var decoder = try BinaryDecoder(data: payload)
            let rawOpcode = try decoder.decode(UInt8.self)
            guard let opcode = OpCode(rawValue: rawOpcode) else {
                throw WaxError.walCorruption(offset: offset, reason: "unknown opcode 0x\(String(format: "%02X", rawOpcode))")
            }

            switch opcode {
            case .putFrame:
                let frameId = try decoder.decode(UInt64.self)
                let timestampMs = try decoder.decode(Int64.self)
                let options = try FrameMetaSubset.decode(from: &decoder)
                let payloadOffset = try decoder.decode(UInt64.self)
                let payloadLength = try decoder.decode(UInt64.self)
                let canonicalEncodingRaw = try decoder.decode(UInt8.self)
                guard let canonicalEncoding = CanonicalEncoding(rawValue: canonicalEncodingRaw) else {
                    throw WaxError.walCorruption(offset: offset, reason: "invalid canonical_encoding \(canonicalEncodingRaw)")
                }
                let canonicalLength = try decoder.decode(UInt64.self)
                let canonicalChecksum = try decoder.decodeFixedBytes(count: WALRecord.checksumSize)
                let storedChecksum = try decoder.decodeFixedBytes(count: WALRecord.checksumSize)
                try decoder.finalize()
                return .putFrame(
                    PutFrame(
                        frameId: frameId,
                        timestampMs: timestampMs,
                        options: options,
                        payloadOffset: payloadOffset,
                        payloadLength: payloadLength,
                        canonicalEncoding: canonicalEncoding,
                        canonicalLength: canonicalLength,
                        canonicalChecksum: canonicalChecksum,
                        storedChecksum: storedChecksum
                    )
                )
            case .deleteFrame:
                let frameId = try decoder.decode(UInt64.self)
                try decoder.finalize()
                return .deleteFrame(DeleteFrame(frameId: frameId))
            case .supersedeFrame:
                let supersededId = try decoder.decode(UInt64.self)
                let supersedingId = try decoder.decode(UInt64.self)
                try decoder.finalize()
                return .supersedeFrame(SupersedeFrame(supersededId: supersededId, supersedingId: supersedingId))
            case .putEmbedding:
                let frameId = try decoder.decode(UInt64.self)
                let dimension = try decoder.decode(UInt32.self)
                guard dimension <= UInt32(Constants.maxEmbeddingDimensions) else {
                    throw WaxError.walCorruption(offset: offset, reason: "embedding dimension exceeds limit")
                }
                let dimInt = Int(dimension)
                guard dimInt <= Int.max / 4 else {
                    throw WaxError.walCorruption(offset: offset, reason: "embedding dimension overflows buffer")
                }
                let byteCount = dimInt * 4
                let bytes = try decoder.decodeFixedBytes(count: byteCount)

                // Bulk copy: safe on little-endian platforms (all Apple targets).
                var vector = [Float](repeating: 0, count: dimInt)
                vector.withUnsafeMutableBufferPointer { floatBuf in
                    bytes.withUnsafeBytes { src in
                        UnsafeMutableRawBufferPointer(floatBuf).copyMemory(from: src)
                    }
                }

                try decoder.finalize()
                return .putEmbedding(PutEmbedding(frameId: frameId, dimension: dimension, vector: vector))
            }
        } catch let error as WaxError {
            switch error {
            case .walCorruption:
                throw error
            default:
                throw WaxError.walCorruption(offset: offset, reason: error.localizedDescription)
            }
        } catch {
            throw WaxError.walCorruption(offset: offset, reason: String(describing: error))
        }
    }
}
