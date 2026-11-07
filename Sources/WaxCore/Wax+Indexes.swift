import Foundation

/// The pending embeddings a staged vector index covers. Commit refuses the index as
/// stale (`WaxError.vectorIndexStale`) once a later embedding is pending.
package enum StagedVecIndexCoverage: Equatable, Sendable {
    /// The latest pending embedding when staged. Correct only when no embedding can be
    /// written between the engine's sync and the stage (see `Wax.withEmbeddingWritesPaused`).
    case latestPending
    /// Embeddings through this WAL sequence, the `latestSequence` the engine synced
    /// (`nil` when none were pending).
    case syncedThrough(UInt64?)
}

extension Wax {
    /// Internal only because of the file split.
    static func validateVecIndexSegment(
        _ data: Data,
        vectorCount expectedVectorCount: UInt64,
        dimension expectedDimension: UInt32,
        similarity expectedSimilarity: VecSimilarity
    ) throws {
        let headerSize = 36
        guard data.count >= headerSize else {
            throw WaxError.invalidToc(reason: "vec segment too small: \(data.count) bytes")
        }
        guard data.prefix(4) == Data([0x4D, 0x56, 0x32, 0x56]) else {
            throw WaxError.invalidToc(reason: "vec segment magic mismatch")
        }

        let version = UInt16(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
        })
        guard version == 1 else {
            throw WaxError.invalidToc(reason: "unsupported vec segment version \(version)")
        }

        let encoding = data[6]
        guard encoding == 1 || encoding == 2 || encoding == 3 else {
            throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(encoding)")
        }
        let similarityRaw = data[7]
        guard let similarity = VecSimilarity(rawValue: similarityRaw) else {
            throw WaxError.invalidToc(reason: "vec similarity must be 0..2 (got \(similarityRaw))")
        }
        guard similarity == expectedSimilarity else {
            throw WaxError.invalidToc(
                reason: "staged vec similarity mismatch vs segment: expected \(expectedSimilarity), got \(similarity)"
            )
        }

        let dimension = UInt32(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
        })
        guard dimension == expectedDimension else {
            throw WaxError.invalidToc(
                reason: "staged vec dimension mismatch vs segment: expected \(expectedDimension), got \(dimension)"
            )
        }

        let vectorCount = UInt64(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 12, as: UInt64.self)
        })
        guard vectorCount == expectedVectorCount else {
            throw WaxError.invalidToc(
                reason: "staged vec vector count mismatch vs segment: expected \(expectedVectorCount), got \(vectorCount)"
            )
        }

        let payloadLength = UInt64(littleEndian: data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 20, as: UInt64.self)
        })
        guard payloadLength <= UInt64(Int.max) else {
            throw WaxError.invalidToc(reason: "vec payload_length exceeds Int.max: \(payloadLength)")
        }
        guard data[28..<36].allSatisfy({ $0 == 0 }) else {
            throw WaxError.invalidToc(reason: "vec segment reserved bytes must be zero")
        }

        switch encoding {
        case 1:
            let expectedTotal = headerSize + Int(payloadLength)
            guard data.count == expectedTotal else {
                throw WaxError.invalidToc(reason: "vec segment length mismatch: expected \(expectedTotal), got \(data.count)")
            }
        case 2, 3:
            let dimProduct = vectorCount.multipliedReportingOverflow(by: UInt64(dimension))
            guard !dimProduct.overflow else {
                throw WaxError.invalidToc(reason: "vec vector data length overflow")
            }
            let byteProduct = dimProduct.partialValue.multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.stride))
            guard !byteProduct.overflow else {
                throw WaxError.invalidToc(reason: "vec vector data length overflow")
            }
            let vectorBytes = byteProduct.partialValue
            guard payloadLength == vectorBytes else {
                throw WaxError.invalidToc(reason: "vec vector data length mismatch")
            }
            let vectorLength = Int(payloadLength)
            let frameIdLengthOffset = headerSize + vectorLength
            guard data.count >= frameIdLengthOffset + MemoryLayout<UInt64>.stride else {
                throw WaxError.invalidToc(reason: "vec segment missing frameIds length")
            }
            let frameIdLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: frameIdLengthOffset, as: UInt64.self)
            })
            let expectedFrameIdBytes = vectorCount * UInt64(MemoryLayout<UInt64>.stride)
            guard frameIdLength == expectedFrameIdBytes else {
                throw WaxError.invalidToc(reason: "vec frameId data length mismatch")
            }
            guard frameIdLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "vec frameId length exceeds Int.max: \(frameIdLength)")
            }
            let expectedTotal = frameIdLengthOffset + MemoryLayout<UInt64>.stride + Int(frameIdLength)
            guard data.count == expectedTotal else {
                throw WaxError.invalidToc(reason: "vec segment length mismatch: expected \(expectedTotal), got \(data.count)")
            }
            try validateUniqueVecFrameIds(
                in: data,
                offset: frameIdLengthOffset + MemoryLayout<UInt64>.stride,
                byteCount: Int(frameIdLength)
            )
        default:
            throw WaxError.invalidToc(reason: "unsupported vec segment encoding \(encoding)")
        }
    }

    private static func validateUniqueVecFrameIds(in data: Data, offset: Int, byteCount: Int) throws {
        var seen = Set<UInt64>()
        seen.reserveCapacity(byteCount / MemoryLayout<UInt64>.stride)
        try data.withUnsafeBytes { rawBuffer in
            for byteOffset in stride(from: offset, to: offset + byteCount, by: MemoryLayout<UInt64>.stride) {
                let frameId = UInt64(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt64.self))
                guard seen.insert(frameId).inserted else {
                    throw WaxError.invalidToc(reason: "vec frameIds contain duplicate id \(frameId)")
                }
            }
        }
    }

    package func readCommittedLexIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let manifest = toc.indexes.lex else { return nil }
            guard manifest.version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported lex index version \(manifest.version)")
            }
            guard manifest.bytesLength > 0 else { return nil }
            let maxBlob = UInt64(Constants.maxBlobBytes)
            guard manifest.bytesLength <= maxBlob else {
                throw WaxError.capacityExceeded(limit: maxBlob, requested: manifest.bytesLength)
            }
            guard manifest.bytesLength <= UInt64(Int.max) else {
                throw WaxError.io("lex index size exceeds Int.max: \(manifest.bytesLength)")
            }

            let dataStart = header.walOffset + header.walSize
            guard manifest.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "lex index below data region")
            }
            guard manifest.bytesOffset <= UInt64.max - manifest.bytesLength else {
                throw WaxError.invalidToc(reason: "lex index range overflows")
            }
            let end = manifest.bytesOffset + manifest.bytesLength
            guard end <= header.footerOffset else {
                throw WaxError.invalidToc(reason: "lex index exceeds footer offset")
            }

            let file = self.file
            let bytes = try await io.run {
                try file.readExactly(length: Int(manifest.bytesLength), at: manifest.bytesOffset)
            }
            let computed = SHA256Checksum.digest(bytes)
            guard computed == manifest.checksum else {
                throw WaxError.checksumMismatch("lex index checksum mismatch")
            }
            return bytes
        }
    }

    package func committedLexIndexManifest() async -> LexIndexManifest? {
        await withReadLock {
            toc.indexes.lex
        }
    }

    package func readCommittedVecIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let manifest = toc.indexes.vec else { return nil }
            guard manifest.bytesLength > 0 else { return nil }
            let maxBlob = UInt64(Constants.maxBlobBytes)
            guard manifest.bytesLength <= maxBlob else {
                throw WaxError.capacityExceeded(limit: maxBlob, requested: manifest.bytesLength)
            }
            guard manifest.bytesLength <= UInt64(Int.max) else {
                throw WaxError.io("vec index size exceeds Int.max: \(manifest.bytesLength)")
            }

            let dataStart = header.walOffset + header.walSize
            guard manifest.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "vec index below data region")
            }
            guard manifest.bytesOffset <= UInt64.max - manifest.bytesLength else {
                throw WaxError.invalidToc(reason: "vec index range overflows")
            }
            let end = manifest.bytesOffset + manifest.bytesLength
            guard end <= header.footerOffset else {
                throw WaxError.invalidToc(reason: "vec index exceeds footer offset")
            }

            committedVecIndexReads &+= 1
            let file = self.file
            let bytes = try await io.run {
                try file.readExactly(length: Int(manifest.bytesLength), at: manifest.bytesOffset)
            }
            let computed = SHA256Checksum.digest(bytes)
            guard computed == manifest.checksum else {
                throw WaxError.checksumMismatch("vec index checksum mismatch")
            }
            return bytes
        }
    }

    package func readStagedVecIndexBytes() async -> (bytes: Data, dimension: UInt32, similarity: VecSimilarity)? {
        await withReadLock {
            guard let staged = stagedVecIndex else { return nil }
            return (bytes: staged.bytes, dimension: staged.dimension, similarity: staged.similarity)
        }
    }

    /// Reads of the committed vector segment (each one reads and hashes all of it) since this
    /// handle opened.
    package func committedVecIndexReadsForTesting() async -> UInt64 {
        await withReadLock { committedVecIndexReads }
    }

    package func committedVecIndexManifest() async -> VecIndexManifest? {
        await withReadLock {
            toc.indexes.vec
        }
    }

    /// Internal only because of the file split.
    struct StagedLexIndex {
        var bytes: Data
        var docCount: UInt64
        var version: UInt32
        var checksum: Data
    }

    /// Internal only because of the file split.
    struct StagedVecIndex {
        var bytes: Data
        var vectorCount: UInt64
        var dimension: UInt32
        var similarity: VecSimilarity
        var pendingEmbeddingMaxSequence: UInt64?
        var checksum: Data
    }
}
