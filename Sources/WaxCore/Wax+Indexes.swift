import Foundation

extension Wax {
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

    /// Reads of every committed vector run (`readCommittedVectors()`) since this handle opened.
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
}
