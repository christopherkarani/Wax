import Foundation

/// A store's committed vectors, merged across its runs: one row per frame, in row order.
package struct CommittedVectors: Equatable, Sendable {
    package var dimension: UInt32
    package var similarity: VecSimilarity
    package var frameIds: [UInt64]
    /// Row-major, `dimension` floats per frame, as the embeddings were written.
    package var vectors: [Float]
    /// Rows left out because they held NaN or infinity (stores written before inserts
    /// rejected them).
    package var droppedNonFiniteRowCount: Int

    package init(
        dimension: UInt32,
        similarity: VecSimilarity,
        frameIds: [UInt64],
        vectors: [Float],
        droppedNonFiniteRowCount: Int = 0
    ) {
        self.dimension = dimension
        self.similarity = similarity
        self.frameIds = frameIds
        self.vectors = vectors
        self.droppedNonFiniteRowCount = droppedNonFiniteRowCount
    }
}

/// The dimension and similarity a store's vectors are indexed with.
package struct VectorIndexConfiguration: Equatable, Sendable {
    package var dimension: UInt32
    package var similarity: VecSimilarity

    package init(dimension: UInt32, similarity: VecSimilarity) {
        self.dimension = dimension
        self.similarity = similarity
    }
}

/// A pending vector change, in WAL order.
enum PendingVectorChange {
    case put(PutEmbedding)
    case remove(UInt64)

    var frameId: UInt64 {
        switch self {
        case .put(let embedding): embedding.frameId
        case .remove(let frameId): frameId
        }
    }

    /// Each frame's last change: the last embedding of the frames whose last change puts one,
    /// in the order the frames first changed, and the frames whose last change removes.
    static func lastChanges(_ changes: [PendingVectorChange]) -> (embeddings: [PutEmbedding], removedFrameIds: [UInt64]) {
        var last: [UInt64: Int] = [:]
        last.reserveCapacity(changes.count)
        var order: [UInt64] = []
        for (index, change) in changes.enumerated() where last.updateValue(index, forKey: change.frameId) == nil {
            order.append(change.frameId)
        }
        var embeddings: [PutEmbedding] = []
        var removed: [UInt64] = []
        for frameId in order {
            switch changes[last[frameId]!] {
            case .put(let embedding): embeddings.append(embedding)
            case .remove: removed.append(frameId)
            }
        }
        return (embeddings, removed)
    }
}

/// Vector runs: a commit writes the embeddings and removals since the previous commit as
/// one new run instead of rewriting every vector, and merges runs in bounded steps.
///
/// Runs are ordered oldest first. Each has a level: a commit's run starts at 0, and when
/// `mergeFanout` runs share the lowest level that many runs have, one commit merges them
/// into a run one level up. Levels never increase from older to newer runs, so the runs of
/// one level are adjacent and a merge keeps the order. When more than a fifth of all rows
/// are replaced or removed, the commit merges every run instead. A commit merges at most
/// once. Merged-away runs are freed only after the header naming the merged run is durable.
extension Wax {
    static let vecRunMergeFanout = 8
    /// Level of a run that holds a whole index at once: a v1 store's vector blob, adopted
    /// in place, or vectors a rewrite imports. Smaller runs merge below it.
    static let vecRunBaseLevel: UInt8 = 64

    /// Records the dimension and similarity the store's vectors are indexed with, for the
    /// first commit that writes vectors. Later commits take them from the committed index,
    /// which they must match.
    package func setVectorIndexConfiguration(dimension: UInt32, similarity: VecSimilarity) async throws {
        try await withWriteLock {
            guard dimension > 0 else {
                throw WaxError.io("vec index dimension must be > 0")
            }
            guard dimension <= UInt32(Constants.maxEmbeddingDimensions) else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxEmbeddingDimensions),
                    requested: UInt64(dimension)
                )
            }
            if let committed = toc.indexes.vec {
                guard committed.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "vec dimension mismatch vs committed vec index: expected \(committed.dimension), got \(dimension)"
                    )
                }
                guard committed.similarity == similarity else {
                    throw WaxError.invalidToc(
                        reason: "vec similarity mismatch vs committed vec index: expected \(committed.similarity), got \(similarity)"
                    )
                }
                return
            }
            if pendingMutationSummary.pendingEmbeddingHasMixedDimensions
                || (pendingMutationSummary.pendingEmbeddingDimension.map { $0 != dimension } ?? false) {
                let actual = pendingMutationSummary.pendingEmbeddingHasMixedDimensions
                    ? "mixed"
                    : String(pendingMutationSummary.pendingEmbeddingDimension ?? 0)
                throw WaxError.invalidToc(
                    reason: "pending embedding dimension mismatch vs vec index: expected \(dimension), got \(actual)"
                )
            }
            vectorConfiguration = VectorIndexConfiguration(dimension: dimension, similarity: similarity)
        }
    }

    /// The committed vector index's dimension and similarity, else the ones recorded for
    /// the first commit; `nil` when neither exists.
    package func vectorIndexConfiguration() async -> VectorIndexConfiguration? {
        await withReadLock {
            if let committed = toc.indexes.vec {
                return VectorIndexConfiguration(dimension: committed.dimension, similarity: committed.similarity)
            }
            return vectorConfiguration
        }
    }

    /// The committed vectors, every run read and its checksum verified.
    package func readCommittedVectors() async throws -> CommittedVectors? {
        try await withReadLock {
            guard let manifest = toc.indexes.vec else { return nil }
            committedVecIndexReads &+= 1
            var table = VecRunTable(dimension: Int(manifest.dimension))
            for run in manifest.runs {
                table.apply(try await readVecRunLocked(run, of: manifest))
            }
            let rows = table.compacted()
            return Self.droppingNonFiniteRows(
                CommittedVectors(
                    dimension: manifest.dimension,
                    similarity: manifest.similarity,
                    frameIds: rows.frameIds,
                    vectors: rows.vectors
                )
            )
        }
    }

    /// Frames with a committed vector. Reads only the runs' keys.
    package func committedVectorFrameIds() async throws -> Set<UInt64> {
        try await withReadLock {
            if let committedVectorKeys { return committedVectorKeys }
            return try await loadCommittedVectorKeysLocked(recordingKeysChecksums: false)
        }
    }

    /// Stages `vectors` as the store's first vector run, for a rewrite into a new store.
    package func stageVectorImportForNextCommit(_ vectors: CommittedVectors) async throws {
        try await withWriteLock {
            guard toc.indexes.vec == nil else {
                throw WaxError.invalidToc(reason: "vector import requires a store without committed vectors")
            }
            guard vectors.vectors.count == vectors.frameIds.count * Int(vectors.dimension) else {
                throw WaxError.encodingError(reason: "vector import rows do not match its frame ids")
            }
            stagedVectorImport = vectors
            dirty = true
        }
    }

    // MARK: - Commit

    /// The size and level of a run, for planning merges.
    struct VecRunShape: Equatable {
        var rowCount: UInt64
        var level: UInt8
    }

    /// A run a commit keeps or merges: committed, or added by the commit and not yet written.
    enum VecRunSource {
        case committed(VecRunManifest)
        case unwritten(VecRun, level: UInt8)

        var shape: VecRunShape {
            switch self {
            case .committed(let run):
                VecRunShape(rowCount: run.rowCount, level: run.level)
            case .unwritten(let run, let level):
                VecRunShape(rowCount: UInt64(run.frameIds.count), level: level)
            }
        }
    }

    /// What a commit's vector runs changed, applied once its header is durable.
    struct VectorRunCommit {
        var supersededRanges: [Range<UInt64>] = []
        /// Frames with a vector after the commit; `nil` when the commit wrote no runs.
        var liveFrameIds: Set<UInt64>?
    }

    /// Removes vec catalog entries no run names and returns their ranges, to free once the
    /// commit is durable. Released 1.0 builds left one per superseded vector segment.
    /// Internal only because of the file split; call only from the commit, after
    /// ``writeVectorRunsLocked(_:generation:)``, while holding `opLock` for writing.
    func removeUnreferencedVecSegmentsLocked() -> [Range<UInt64>] {
        let named = Set((toc.indexes.vec?.runs ?? []).map(\.bytesOffset))
        var unreferenced: [Range<UInt64>] = []
        toc.segmentCatalog.entries.removeAll { entry in
            guard entry.kind == .vec, !named.contains(entry.bytesOffset) else { return false }
            if entry.bytesLength > 0 {
                unreferenced.append(entry.bytesOffset..<(entry.bytesOffset + entry.bytesLength))
            }
            return true
        }
        return unreferenced
    }

    /// Writes this commit's run and at most one merge, and updates the vec manifest and
    /// catalog in `toc`. Internal only because of the file split; call only from the commit,
    /// while holding `opLock` for writing.
    func writeVectorRunsLocked(
        _ changes: [PendingVectorChange],
        generation: UInt64
    ) async throws -> VectorRunCommit {
        let imported = stagedVectorImport
        guard !changes.isEmpty || imported != nil else { return VectorRunCommit() }

        let configuration: VectorIndexConfiguration
        if let committed = toc.indexes.vec {
            configuration = VectorIndexConfiguration(dimension: committed.dimension, similarity: committed.similarity)
        } else if let imported {
            configuration = VectorIndexConfiguration(dimension: imported.dimension, similarity: imported.similarity)
        } else if let vectorConfiguration {
            configuration = vectorConfiguration
        } else {
            if !PendingVectorChange.lastChanges(changes).embeddings.isEmpty {
                throw WaxError.vectorIndexNotStaged
            }
            // Removals only, and no vectors to remove them from.
            return VectorRunCommit()
        }

        // Reading the keys can record keys checksums in `toc`, so read them first.
        var live = try await committedVectorKeysLocked()
        var manifest = toc.indexes.vec ?? VecIndexManifest(
            vectorCount: 0,
            dimension: configuration.dimension,
            similarity: configuration.similarity,
            runs: []
        )
        var result = VectorRunCommit()

        // The runs after this commit, in order: the committed ones, then the import and this
        // commit's changes, which are written only if no merge takes them in.
        var sources = manifest.runs.map(VecRunSource.committed)
        if let imported {
            let frameCount = UInt64(toc.frames.count)
            guard imported.frameIds.allSatisfy({ $0 < frameCount }) else {
                throw WaxError.invalidToc(reason: "vector import references a frame the store does not have")
            }
            sources.append(.unwritten(
                VecRun(
                    dimension: imported.dimension,
                    similarity: imported.similarity,
                    frameIds: imported.frameIds,
                    vectors: imported.vectors,
                    tombstones: []
                ),
                level: Self.vecRunBaseLevel
            ))
            live = Set(imported.frameIds)
        }

        let run = try Self.vecRun(
            for: changes,
            configuration: configuration,
            committedFrameIds: live
        )
        if !run.frameIds.isEmpty || !run.tombstones.isEmpty {
            sources.append(.unwritten(run, level: 0))
            live.subtract(run.tombstones)
            live.formUnion(run.frameIds)
        }
        manifest.vectorCount = UInt64(live.count)

        let group = Self.vecRunMergePlan(sources.map(\.shape), liveCount: manifest.vectorCount)
        var runs: [VecRunManifest] = []
        for index in sources.indices {
            if let group, group.contains(index) {
                guard index == group.lowerBound else { continue }
                let merge = try await mergeVecRunsLocked(
                    Array(sources[group]),
                    startingAtTheOldest: group.lowerBound == 0,
                    of: manifest,
                    generation: generation
                )
                runs += merge.run.map { [$0] } ?? []
                result.supersededRanges = merge.superseded
                continue
            }
            switch sources[index] {
            case .committed(let committed):
                runs.append(committed)
            case .unwritten(let unwritten, let level):
                runs.append(try await writeVecRunLocked(unwritten, level: level, generation: generation))
            }
        }
        manifest.runs = runs

        guard !manifest.runs.isEmpty || toc.indexes.vec != nil else { return result }
        toc.indexes.vec = manifest
        result.liveFrameIds = live
        return result
    }

    /// One run holding each frame's last change in `changes`: its last vector, or a
    /// tombstone when it was removed last and has a committed vector.
    static func vecRun(
        for changes: [PendingVectorChange],
        configuration: VectorIndexConfiguration,
        committedFrameIds: Set<UInt64>
    ) throws -> VecRun {
        let reduced = PendingVectorChange.lastChanges(changes)
        var frameIds: [UInt64] = []
        var vectors: [Float] = []
        frameIds.reserveCapacity(reduced.embeddings.count)
        vectors.reserveCapacity(reduced.embeddings.count * Int(configuration.dimension))
        for embedding in reduced.embeddings {
            guard embedding.dimension == configuration.dimension,
                  embedding.vector.count == Int(configuration.dimension)
            else {
                throw WaxError.invalidToc(
                    reason: "putEmbedding dimension \(embedding.dimension) != vec index dimension \(configuration.dimension)"
                )
            }
            frameIds.append(embedding.frameId)
            vectors.append(contentsOf: embedding.vector)
        }
        let tombstones = reduced.removedFrameIds.filter(committedFrameIds.contains)
        return VecRun(
            dimension: configuration.dimension,
            similarity: configuration.similarity,
            frameIds: frameIds,
            vectors: vectors,
            tombstones: tombstones
        )
    }

    /// The adjacent runs this commit merges, if any: every run once more than a fifth of all
    /// rows are dead, else the runs of the lowest level that has `vecRunMergeFanout` of them.
    static func vecRunMergePlan(_ runs: [VecRunShape], liveCount: UInt64) -> Range<Int>? {
        guard runs.count > 1 else { return nil }
        let totalRows = runs.reduce(UInt64(0)) { $0 + $1.rowCount }
        if totalRows > liveCount, (totalRows - liveCount) * 5 > totalRows {
            return runs.indices
        }
        for level in Set(runs.map(\.level)).sorted() {
            let indices = runs.indices.filter { runs[$0].level == level }
            guard indices.count >= vecRunMergeFanout,
                  let first = indices.first, let last = indices.last,
                  last - first + 1 == indices.count
            else { continue }
            return first..<(last + 1)
        }
        return nil
    }

    /// Writes `runs` merged into one run, and returns it with the committed runs' ranges, to
    /// free once the commit is durable. Unwritten runs merge from memory: a run this commit
    /// has not made durable is never read back.
    private func mergeVecRunsLocked(
        _ runs: [VecRunSource],
        startingAtTheOldest: Bool,
        of manifest: VecIndexManifest,
        generation: UInt64
    ) async throws -> (run: VecRunManifest?, superseded: [Range<UInt64>]) {
        var table = VecRunTable(dimension: Int(manifest.dimension))
        var mergedOffsets = Set<UInt64>()
        for source in runs {
            switch source {
            case .committed(let committed):
                table.apply(try await readVecRunLocked(committed, of: manifest))
                mergedOffsets.insert(committed.bytesOffset)
            case .unwritten(let unwritten, _):
                table.apply(unwritten)
            }
        }
        let rows = table.compacted()
        // The oldest runs have nothing older for a tombstone to remove.
        let tombstones = startingAtTheOldest ? [] : table.tombstones.sorted()
        let levels = runs.map(\.shape.level)
        let minLevel = levels.min() ?? 0
        let maxLevel = levels.max() ?? 0
        let level = minLevel == maxLevel ? min(minLevel + 1, Self.vecRunBaseLevel) : maxLevel

        var merged: VecRunManifest?
        if !rows.frameIds.isEmpty || !tombstones.isEmpty {
            merged = try await writeVecRunLocked(
                VecRun(
                    dimension: manifest.dimension,
                    similarity: manifest.similarity,
                    frameIds: rows.frameIds,
                    vectors: rows.vectors,
                    tombstones: tombstones
                ),
                level: level,
                generation: generation
            )
        }

        var superseded: [Range<UInt64>] = []
        toc.segmentCatalog.entries.removeAll { entry in
            guard entry.kind == .vec, mergedOffsets.contains(entry.bytesOffset) else { return false }
            if entry.bytesLength > 0 {
                superseded.append(entry.bytesOffset..<(entry.bytesOffset + entry.bytesLength))
            }
            return true
        }
        return (merged, superseded)
    }

    private func writeVecRunLocked(_ run: VecRun, level: UInt8, generation: UInt64) async throws -> VecRunManifest {
        let bytes = try VecRunCodec.encode(run)
        let keysOffset = try VecRunCodec.keysOffset(rowCount: UInt64(run.frameIds.count), dimension: run.dimension)
        let checksum = SHA256Checksum.digest(bytes)
        let keysChecksum = bytes.withUnsafeBytes { raw in
            var hasher = SHA256Checksum()
            hasher.update(UnsafeRawBufferPointer(rebasing: raw[Int(keysOffset)...]))
            return hasher.finalize()
        }
        let length = UInt64(bytes.count)
        let offset = allocateDataLocked(length: length)
        let file = self.file
        try await io.run {
            try file.writeAll(bytes, at: offset)
        }
        toc.segmentCatalog.entries.append(SegmentCatalogEntry(
            segmentId: nextSegmentId(),
            bytesOffset: offset,
            bytesLength: length,
            checksum: checksum,
            compression: .none,
            kind: .vec
        ))
        return VecRunManifest(
            bytesOffset: offset,
            bytesLength: length,
            checksum: checksum,
            rowCount: UInt64(run.frameIds.count),
            tombstoneCount: UInt64(run.tombstones.count),
            level: level,
            addedGeneration: generation,
            keysChecksum: keysChecksum
        )
    }

    // MARK: - Reading runs

    /// The frames with a committed vector, loaded once and then kept by each commit.
    private func committedVectorKeysLocked() async throws -> Set<UInt64> {
        if let committedVectorKeys { return committedVectorKeys }
        let keys = try await loadCommittedVectorKeysLocked(recordingKeysChecksums: true)
        committedVectorKeys = keys
        return keys
    }

    /// Reads each run's keys, verified by its keys checksum. A run without one (a v1 store's
    /// adopted blob) is read whole once; under the write lock its keys checksum is recorded
    /// for the next commit's TOC.
    private func loadCommittedVectorKeysLocked(recordingKeysChecksums: Bool) async throws -> Set<UInt64> {
        guard let manifest = toc.indexes.vec else { return [] }
        var keys = VecRunKeys()
        for (index, run) in manifest.runs.enumerated() {
            let keysOffset = try VecRunCodec.keysOffset(rowCount: run.rowCount, dimension: manifest.dimension)
            guard keysOffset <= run.bytesLength else {
                throw WaxError.invalidToc(reason: "vec run shorter than its rows")
            }
            if let keysChecksum = run.keysChecksum {
                let bytes = try await readVerifiedLocked(
                    offset: run.bytesOffset + keysOffset,
                    length: run.bytesLength - keysOffset,
                    checksum: keysChecksum,
                    what: "vec run keys"
                )
                let decoded = try VecRunCodec.decodeKeys(bytes, rowCount: run.rowCount, tombstoneCount: run.tombstoneCount)
                keys.apply(frameIds: decoded.frameIds, tombstones: decoded.tombstones)
            } else {
                let bytes = try await readVerifiedLocked(
                    offset: run.bytesOffset,
                    length: run.bytesLength,
                    checksum: run.checksum,
                    what: "vec run"
                )
                let keyBytes = bytes.subdata(in: Int(keysOffset)..<bytes.count)
                let decoded = try VecRunCodec.decodeKeys(keyBytes, rowCount: run.rowCount, tombstoneCount: run.tombstoneCount)
                keys.apply(frameIds: decoded.frameIds, tombstones: decoded.tombstones)
                if recordingKeysChecksums {
                    toc.indexes.vec?.runs[index].keysChecksum = SHA256Checksum.digest(keyBytes)
                }
            }
        }
        return keys.frameIds
    }

    private func readVecRunLocked(_ run: VecRunManifest, of manifest: VecIndexManifest) async throws -> VecRun {
        let bytes = try await readVerifiedLocked(
            offset: run.bytesOffset,
            length: run.bytesLength,
            checksum: run.checksum,
            what: "vec index"
        )
        let decoded = try VecRunCodec.decode(bytes)
        guard decoded.dimension == manifest.dimension, decoded.similarity == manifest.similarity else {
            throw WaxError.invalidToc(reason: "vec run dimension or similarity differs from its manifest")
        }
        guard UInt64(decoded.frameIds.count) == run.rowCount,
              UInt64(decoded.tombstones.count) == run.tombstoneCount
        else {
            throw WaxError.invalidToc(reason: "vec run row or tombstone count differs from its manifest")
        }
        return decoded
    }

    private func readVerifiedLocked(offset: UInt64, length: UInt64, checksum: Data, what: String) async throws -> Data {
        let dataStart = header.walOffset + header.walSize
        guard offset >= dataStart else {
            throw WaxError.invalidToc(reason: "\(what) below data region")
        }
        guard offset <= UInt64.max - length, offset + length <= header.footerOffset else {
            throw WaxError.invalidToc(reason: "\(what) exceeds footer offset")
        }
        guard length <= UInt64(Int.max) else {
            throw WaxError.io("\(what) size exceeds Int.max: \(length)")
        }
        let file = self.file
        let bytes = try await io.run {
            try file.readExactly(length: Int(length), at: offset)
        }
        guard SHA256Checksum.digest(bytes) == checksum else {
            throw WaxError.checksumMismatch("\(what) checksum mismatch")
        }
        return bytes
    }

    private static func droppingNonFiniteRows(_ vectors: CommittedVectors) -> CommittedVectors {
        guard !vectors.vectors.allSatisfy(\.isFinite) else { return vectors }
        let dimension = Int(vectors.dimension)
        var kept = vectors
        kept.frameIds = []
        kept.vectors = []
        for (row, frameId) in vectors.frameIds.enumerated() {
            let values = vectors.vectors[(row * dimension)..<((row + 1) * dimension)]
            guard values.allSatisfy(\.isFinite) else { continue }
            kept.frameIds.append(frameId)
            kept.vectors.append(contentsOf: values)
        }
        kept.droppedNonFiniteRowCount = vectors.frameIds.count - kept.frameIds.count
        return kept
    }
}

// MARK: - Format 1.0 files

extension Wax {
    /// Internal only because of the file split; call from `open` only.
    func markLegacyHeaderPageOnDisk() {
        legacyHeaderPageOnDisk = true
    }

    /// Rewrites both header pages as the current format, naming the durable commit, so a
    /// build that reads only format 1.0 refuses the file. Each write goes to the page that is
    /// not selected, so a torn write falls back to the other page, which names the same commit.
    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func ensureHeaderPagesCurrentLocked() async throws {
        guard legacyHeaderPageOnDisk else { return }
        // The fence, when not yet durable, writes one page.
        try await ensureRecoveryFenceLocked()
        var page = header
        page.walReplaySnapshot = nil
        page.headerPageGeneration &+= 1
        let index = try await writeOtherHeaderPageDurably(page)
        header = page
        markHeaderPageSelected(index)
        legacyHeaderPageOnDisk = false
    }
}

// MARK: - Recovery

extension Wax {
    /// The newest of `candidates` (by ``newerFooter(_:_:headerFooterOffset:)``) whose commit is
    /// whole, with its TOC. A header page is written only after its commit is synced, so the
    /// commit it names is whole. A footer only a scan or a replay snapshot found may have been
    /// synced while the vector runs its commit wrote were not, so it counts only when those runs
    /// (`addedGeneration` equal to its generation) match their checksums; otherwise the next
    /// newest candidate is taken, and that commit's WAL records replay as pending. Runs of
    /// older generations were synced by their own commits.
    /// Internal only because of the file split; call from `open` and `verify` only.
    static func newestWholeCommit(
        _ candidates: [FooterSlice],
        headerFooterOffset: UInt64,
        headerGeneration: UInt64,
        file: FDFile
    ) throws -> (footer: FooterSlice, toc: WaxTOC) {
        var remaining = candidates
        while let first = remaining.first {
            let newest = remaining.dropFirst().reduce(first) {
                newerFooter($0, $1, headerFooterOffset: headerFooterOffset)
            }
            let toc = try WaxTOC.decode(from: newest)
            let namedByHeader = newest.footerOffset == headerFooterOffset
                && newest.footer.generation == headerGeneration
            if namedByHeader || vectorRunsWritten(by: newest.footer.generation, in: toc, file: file) {
                return (newest, toc)
            }
            remaining.removeAll { $0.footerOffset == newest.footerOffset }
        }
        throw WaxError.invalidFooter(reason: "no valid footer found within max_footer_scan_bytes")
    }

    /// Whether every run `generation` wrote matches its checksum.
    private static func vectorRunsWritten(by generation: UInt64, in toc: WaxTOC, file: FDFile) -> Bool {
        guard let runs = toc.indexes.vec?.runs else { return true }
        for run in runs where run.addedGeneration == generation {
            guard run.bytesLength <= UInt64(Int.max),
                  let bytes = try? file.readExactly(length: Int(run.bytesLength), at: run.bytesOffset),
                  SHA256Checksum.digest(bytes) == run.checksum
            else { return false }
        }
        return true
    }
}
