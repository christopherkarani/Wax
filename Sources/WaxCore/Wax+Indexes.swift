import Foundation

extension Wax {
    /// The committed lex image: its base with every delta run applied, each run's checksum
    /// verified (Wax+LexRuns.swift).
    package func readCommittedLexIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let manifest = toc.indexes.lex else { return nil }
            guard manifest.version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported lex index version \(manifest.version)")
            }
            guard manifest.imageLength > 0 else { return nil }
            let image = try await readCommittedLexImageLocked(manifest)
            recordCommittedLexFingerprintsLocked(of: image, manifest: manifest)
            return image
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
}
