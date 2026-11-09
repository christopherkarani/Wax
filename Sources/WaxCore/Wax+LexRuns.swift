import Foundation
#if canImport(os)
import os
#endif

/// Lex runs: a commit writes the pages of the text index image that differ from the committed
/// image, instead of the whole image.
///
/// The lex manifest lists a base (the whole image) and then delta runs, applied oldest first
/// (see ``LexRunCodec``). Staging compares the image page by page with fingerprints of the
/// committed image, kept in memory, and stages the changed pages as a delta run. It stages a
/// fresh base instead when the delta runs would then hold more than a quarter of the image's
/// bytes or number more than `maxLexRuns`. A quarter bounds what the runs add to the store and
/// to the bytes open reads at a quarter of the image, while a commit writes about five times
/// its changed pages on average (its delta, plus its share of the next base) instead of the
/// whole image. The runs a base replaces are freed only after the header naming it is durable.
extension Wax {
    /// A base replaces the runs once their deltas would exceed this fraction of the image.
    static let lexRunRebaseDivisor = 4
    static let maxLexRuns = 32
    /// Page size of an image without a SQLite header.
    static let defaultLexPageSize = 4096

    /// Page fingerprints of the committed lex image, identified by its runs' checksums.
    struct LexPageFingerprints {
        var runChecksums: [Data]
        var pageSize: Int
        var imageLength: Int
        var hashes: [UInt64]
    }

    /// What the next commit writes for the lex index.
    struct StagedLexIndex {
        enum Content {
            /// The whole image, copied.
            case base(Data)
            /// An encoded delta run against the committed image.
            case delta(Data)
        }

        var content: Content
        var docCount: UInt64
        var version: UInt32
        var pageSize: Int
        var imageLength: Int
        /// Fingerprints of the staged image, which become the committed ones.
        var fingerprints: [UInt64]
    }

    /// Stages the lex index image `bytes` for the next commit, as the pages that differ from
    /// the committed image. Keeps no reference to `bytes` after it returns, so a caller may pass
    /// a view of memory it holds unchanged only for the call.
    package func stageLexIndexForNextCommit(bytes: Data, docCount: UInt64, version: UInt32 = 1) async throws {
        try await withWriteLock {
            guard version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported lex index version \(version)")
            }
            guard !bytes.isEmpty else {
                throw WaxError.io("lex index bytes must be non-empty (expected sqlite3_serialize output)")
            }
            guard bytes.count <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(bytes.count)
                )
            }
            let seed = lexFingerprintSeed
            let (pageSize, fingerprints) = bytes.withUnsafeBytes { (image: UnsafeRawBufferPointer) -> (Int, [UInt64]) in
                let pageSize = LexRunCodec.pageSize(of: image, fallback: Self.defaultLexPageSize)
                return (pageSize, LexPageFingerprint.fingerprints(of: image, pageSize: pageSize, seed: seed))
            }

            if let staged = stagedLexIndex,
               staged.docCount == docCount,
               staged.version == version,
               staged.pageSize == pageSize,
               staged.imageLength == bytes.count,
               staged.fingerprints == fingerprints {
                return
            }

            let content: StagedLexIndex.Content
            if let manifest = toc.indexes.lex,
               let committed = await committedLexFingerprintsLocked(pageSize: pageSize) {
                let changed = fingerprints.indices.filter { index in
                    index >= committed.hashes.count || committed.hashes[index] != fingerprints[index]
                }
                if changed.isEmpty,
                   committed.imageLength == bytes.count,
                   manifest.docCount == docCount,
                   manifest.version == version {
                    stagedLexIndex = nil
                    stagedLexIndexStamp = nil
                    return
                }
                let deltaLength = LexRunCodec.encodedLength(pages: changed, pageSize: pageSize, imageLength: bytes.count)
                if Self.lexDeltaFits(deltaLength, after: manifest, pageSize: pageSize, imageLength: bytes.count) {
                    content = .delta(try bytes.withUnsafeBytes { (image: UnsafeRawBufferPointer) in
                        try LexRunCodec.encode(pages: changed, of: image, pageSize: pageSize)
                    })
                } else {
                    content = .base(Self.copying(bytes))
                }
            } else {
                content = .base(Self.copying(bytes))
            }

            stagedLexIndex = StagedLexIndex(
                content: content,
                docCount: docCount,
                version: version,
                pageSize: pageSize,
                imageLength: bytes.count,
                fingerprints: fingerprints
            )
            stagedLexIndexStampCounter &+= 1
            stagedLexIndexStamp = stagedLexIndexStampCounter
            dirty = true
        }
    }

    /// Whether a delta of `deltaLength` bytes can follow the runs of `manifest`, or the commit
    /// should write a fresh base.
    static func lexDeltaFits(_ deltaLength: Int, after manifest: LexIndexManifest, pageSize: Int, imageLength: Int) -> Bool {
        guard manifest.runs.count < maxLexRuns else { return false }
        // Every delta of a manifest has its page size; an adopted v2 blob has no deltas yet.
        guard manifest.runs.count == 1 || Int(manifest.pageSize) == pageSize else { return false }
        let deltaBytes = manifest.runs.dropFirst().reduce(UInt64(deltaLength)) { $0 + $1.bytesLength }
        return deltaBytes * UInt64(lexRunRebaseDivisor) <= UInt64(imageLength)
    }

    /// A copy that owns its bytes: `bytes` may view memory its owner changes after the call.
    private static func copying(_ bytes: Data) -> Data {
        bytes.withUnsafeBytes { Data($0) }
    }

    /// Fingerprints of the committed image with pages of `pageSize`; read from the runs when
    /// this handle has none for them. `nil` without a committed image, or when its runs do not
    /// read back whole: the commit then writes a base, which replaces every run. That failure
    /// is logged and counted; `verify(deep: true)` reports the same runs as corrupt.
    private func committedLexFingerprintsLocked(pageSize: Int) async -> LexPageFingerprints? {
        guard let manifest = toc.indexes.lex else { return nil }
        let identity = manifest.runs.map(\.checksum)
        if let cached = committedLexFingerprints, cached.runChecksums == identity, cached.pageSize == pageSize {
            return cached
        }
        let image: Data
        do {
            image = try await readCommittedLexImageLocked(manifest)
        } catch {
            committedLexReadFailures &+= 1
            Self.logUnreadableCommittedLexRuns(error)
            return nil
        }
        lexFingerprintBuilds &+= 1
        let seed = lexFingerprintSeed
        let hashes = image.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            LexPageFingerprint.fingerprints(of: raw, pageSize: pageSize, seed: seed)
        }
        let fingerprints = LexPageFingerprints(
            runChecksums: identity,
            pageSize: pageSize,
            imageLength: image.count,
            hashes: hashes
        )
        committedLexFingerprints = fingerprints
        return fingerprints
    }

    private static func logUnreadableCommittedLexRuns(_ error: any Error) {
        let message = "committed lex runs unreadable, the next commit writes a fresh base"
        #if canImport(os)
        Logger(subsystem: "com.wax.core", category: "lex-runs")
            .error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        #else
        FileHandle.standardError.write(Data("wax: \(message): \(error)\n".utf8))
        #endif
    }

    /// Records the fingerprints of `image`, the committed image `manifest` names, so the next
    /// stage need not read it again; does nothing when this handle has them already. Safe
    /// under the read lock: the manifest changes only under the write lock.
    func recordCommittedLexFingerprintsLocked(of image: Data, manifest: LexIndexManifest) {
        let identity = manifest.runs.map(\.checksum)
        guard committedLexFingerprints?.runChecksums != identity else { return }
        lexFingerprintBuilds &+= 1
        let seed = lexFingerprintSeed
        let fingerprints = image.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> LexPageFingerprints in
            let pageSize = LexRunCodec.pageSize(of: raw, fallback: Self.defaultLexPageSize)
            return LexPageFingerprints(
                runChecksums: identity,
                pageSize: pageSize,
                imageLength: raw.count,
                hashes: LexPageFingerprint.fingerprints(of: raw, pageSize: pageSize, seed: seed)
            )
        }
        committedLexFingerprints = fingerprints
    }

    // MARK: - Commit

    /// What a commit's lex runs changed, applied once its header is durable.
    struct LexRunCommit {
        var supersededRanges: [Range<UInt64>] = []
        /// Fingerprints of the committed image after the commit; `nil` when it wrote no run.
        var fingerprints: LexPageFingerprints?
    }

    /// Writes the staged lex run and updates the lex manifest and catalog in `toc`. Internal
    /// only because of the file split; call only from the commit, while holding `opLock` for
    /// writing.
    func writeLexRunsLocked(generation: UInt64) async throws -> LexRunCommit {
        guard let staged = stagedLexIndex else { return LexRunCommit() }
        var result = LexRunCommit()
        switch staged.content {
        case .base(let image):
            let run = try await writeLexSegmentLocked(image, imageLength: staged.imageLength, generation: generation)
            result.supersededRanges = removeSupersededSegmentsLocked(kind: .lex)
            toc.segmentCatalog.entries.append(run.entry)
            toc.indexes.lex = LexIndexManifest(
                docCount: staged.docCount,
                version: staged.version,
                pageSize: UInt32(staged.pageSize),
                runs: [run.manifest]
            )
        case .delta(let bytes):
            guard var manifest = toc.indexes.lex else {
                throw WaxError.invalidToc(reason: "lex delta run staged without a committed lex index")
            }
            let run = try await writeLexSegmentLocked(bytes, imageLength: staged.imageLength, generation: generation)
            toc.segmentCatalog.entries.append(run.entry)
            manifest.runs.append(run.manifest)
            manifest.docCount = staged.docCount
            manifest.pageSize = UInt32(staged.pageSize)
            toc.indexes.lex = manifest
        }
        result.fingerprints = LexPageFingerprints(
            runChecksums: (toc.indexes.lex?.runs ?? []).map(\.checksum),
            pageSize: staged.pageSize,
            imageLength: staged.imageLength,
            hashes: staged.fingerprints
        )
        return result
    }

    /// Removes lex catalog entries no run names and returns their ranges, to free once the
    /// commit is durable. Internal only because of the file split; call only from the commit,
    /// after ``writeLexRunsLocked(generation:)``, while holding `opLock` for writing.
    func removeUnreferencedLexSegmentsLocked() -> [Range<UInt64>] {
        let named = Set((toc.indexes.lex?.runs ?? []).map(\.bytesOffset))
        var unreferenced: [Range<UInt64>] = []
        toc.segmentCatalog.entries.removeAll { entry in
            guard entry.kind == .lex, !named.contains(entry.bytesOffset) else { return false }
            if entry.bytesLength > 0 {
                unreferenced.append(entry.bytesOffset..<(entry.bytesOffset + entry.bytesLength))
            }
            return true
        }
        return unreferenced
    }

    private func writeLexSegmentLocked(
        _ bytes: Data,
        imageLength: Int,
        generation: UInt64
    ) async throws -> (manifest: LexRunManifest, entry: SegmentCatalogEntry) {
        let checksum = SHA256Checksum.digest(bytes)
        let length = UInt64(bytes.count)
        let offset = allocateDataLocked(length: length)
        let file = self.file
        try await io.run {
            try file.writeAll(bytes, at: offset)
        }
        let entry = SegmentCatalogEntry(
            segmentId: nextSegmentId(),
            bytesOffset: offset,
            bytesLength: length,
            checksum: checksum,
            compression: .none,
            kind: .lex
        )
        let manifest = LexRunManifest(
            bytesOffset: offset,
            bytesLength: length,
            checksum: checksum,
            addedGeneration: generation,
            imageLength: UInt64(imageLength)
        )
        return (manifest, entry)
    }

    // MARK: - Reading

    /// The committed image: the base with every delta applied, each run's checksum verified.
    /// Internal only because of the file split; call only under `opLock`.
    func readCommittedLexImageLocked(_ manifest: LexIndexManifest) async throws -> Data {
        let file = self.file
        let dataStart = header.walOffset + header.walSize
        let dataEnd = header.footerOffset
        return try await io.run {
            try Self.reconstructLexImage(manifest, file: file, dataStart: dataStart, dataEnd: dataEnd)
        }
    }

    /// The image `manifest` names in `file`. Blocking.
    static func reconstructLexImage(
        _ manifest: LexIndexManifest,
        file: FDFile,
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> Data {
        guard let base = manifest.runs.first else {
            throw WaxError.invalidToc(reason: "lex index manifest has no runs")
        }
        var image = try readVerifiedLexRun(base, file: file, dataStart: dataStart, dataEnd: dataEnd)
        guard UInt64(image.count) == base.imageLength else {
            throw WaxError.invalidToc(reason: "lex base length differs from its manifest")
        }
        for run in manifest.runs.dropFirst() {
            let bytes = try readVerifiedLexRun(run, file: file, dataStart: dataStart, dataEnd: dataEnd)
            try LexRunCodec.apply(bytes, to: &image, pageSize: Int(manifest.pageSize))
            guard UInt64(image.count) == run.imageLength else {
                throw WaxError.invalidToc(reason: "lex run image length differs from its manifest")
            }
        }
        return image
    }

    private static func readVerifiedLexRun(
        _ run: LexRunManifest,
        file: FDFile,
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> Data {
        guard run.bytesLength > 0, run.bytesLength <= UInt64(Constants.maxBlobBytes) else {
            throw WaxError.capacityExceeded(limit: UInt64(Constants.maxBlobBytes), requested: run.bytesLength)
        }
        guard run.bytesOffset >= dataStart else {
            throw WaxError.invalidToc(reason: "lex run below data region")
        }
        guard run.bytesOffset <= UInt64.max - run.bytesLength, run.bytesOffset + run.bytesLength <= dataEnd else {
            throw WaxError.invalidToc(reason: "lex run exceeds footer offset")
        }
        let bytes = try file.readExactly(length: Int(run.bytesLength), at: run.bytesOffset)
        guard SHA256Checksum.digest(bytes) == run.checksum else {
            throw WaxError.checksumMismatch("lex index checksum mismatch")
        }
        return bytes
    }

    /// The image the next commit would make committed: the staged base, or the committed
    /// image with the staged delta applied.
    package func readStagedLexIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let staged = stagedLexIndex else { return nil }
            switch staged.content {
            case .base(let image):
                return image
            case .delta(let run):
                guard let manifest = toc.indexes.lex else {
                    throw WaxError.invalidToc(reason: "lex delta run staged without a committed lex index")
                }
                var image = try await readCommittedLexImageLocked(manifest)
                try LexRunCodec.apply(run, to: &image, pageSize: staged.pageSize)
                return image
            }
        }
    }
}
