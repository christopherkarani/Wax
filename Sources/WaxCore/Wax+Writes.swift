import Foundation

/// The vector changes pending in the WAL, reduced to each frame's last change.
package struct PendingEmbeddingSnapshot: Equatable, Sendable {
    /// The last embedding of each frame whose last change is an embedding, in WAL order.
    package let embeddings: [PutEmbedding]
    /// Frames whose last change is a removal, ascending.
    package let removedFrameIds: [UInt64]
    /// Sequence of the newest pending vector change, whether or not it is in the window.
    package let latestSequence: UInt64?

    package init(embeddings: [PutEmbedding], removedFrameIds: [UInt64] = [], latestSequence: UInt64?) {
        self.embeddings = embeddings
        self.removedFrameIds = removedFrameIds
        self.latestSequence = latestSequence
    }
}

extension Wax {
    // MARK: - Mutations

    private func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func appendPendingMutation(sequence: UInt64, entry: WALEntry) {
        let mutation = PendingMutation(sequence: sequence, entry: entry)
        pendingMutations.append(mutation)
        pendingMutationSummary.record(mutation)
        rememberDedupIndex?.record(entry)
    }

    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func clearPendingMutations() {
        pendingMutations.removeAll(keepingCapacity: true)
        pendingMutationSummary = PendingMutationSummary()
    }

    /// Internal only because of the file split; call only while holding `opLock`.
    func orderedPendingMutationsLocked() -> [PendingMutation] {
        if pendingMutationSummary.isOrderedBySequence {
            return pendingMutations
        }
        return pendingMutations.sorted { $0.sequence < $1.sequence }
    }

    private func putLocked(
        _ content: Data,
        options: FrameMetaSubset,
        timestampMs: Int64?,
        compression: CanonicalEncoding
    ) async throws -> UInt64 {
        let committedCount = UInt64(toc.frames.count)
        let pendingPutCount = pendingMutationSummary.putFrameCount
        let frameId = committedCount + UInt64(pendingPutCount)

        let canonicalChecksum = SHA256Checksum.digest(content)

        var storedBytes = content
        var canonicalEncoding: CanonicalEncoding = .plain
        if compression != .plain {
            do {
                let compressed = try PayloadCompressor.compress(content, algorithm: CompressionKind(canonicalEncoding: compression))
                if compressed.count < content.count {
                    storedBytes = compressed
                    canonicalEncoding = compression
                }
            } catch {
                storedBytes = content
                canonicalEncoding = .plain
            }
        }

        let storedChecksum = SHA256Checksum.digest(storedBytes)

        var putFrame = PutFrame(
            frameId: frameId,
            timestampMs: timestampMs ?? currentTimestampMs(),
            options: options,
            payloadOffset: 0,
            payloadLength: UInt64(storedBytes.count),
            canonicalEncoding: canonicalEncoding,
            canonicalLength: UInt64(content.count),
            canonicalChecksum: canonicalChecksum,
            storedChecksum: storedChecksum
        )
        // The offset is fixed-width in the encoding, so the size is known before placement.
        let walPayloadSize = try WALEntryCodec.encode(.putFrame(putFrame)).count
        // May commit, which places segments and a TOC; place the payload only afterwards.
        try await ensureWalCapacityLocked(payloadSize: walPayloadSize)
        let payloadOffset = allocateDataLocked(length: UInt64(storedBytes.count))
        putFrame.payloadOffset = payloadOffset
        let entry = WALEntry.putFrame(putFrame)
        let payload = try WALEntryCodec.encode(entry)
        let file = self.file
        let wal = self.wal
        let bytesToStore = storedBytes
        let seq = try await io.run {
            try file.writeAll(bytesToStore, at: payloadOffset)
            return try wal.append(payload: payload)
        }

        appendPendingMutation(sequence: seq, entry: entry)
        dirty = true
        return frameId
    }

    package func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain
    ) async throws -> UInt64 {
        try await withWriteLock {
            try await putLocked(content, options: options, timestampMs: nil, compression: compression)
        }
    }

    package func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain,
        timestampMs: Int64
    ) async throws -> UInt64 {
        try await withWriteLock {
            try await putLocked(content, options: options, timestampMs: timestampMs, compression: compression)
        }
    }

    private func putBatchLocked(
        _ contents: [Data],
        options: [FrameMetaSubset],
        timestampsMs: [Int64]?,
        compression: CanonicalEncoding
    ) async throws -> [UInt64] {
        let committedCount = UInt64(toc.frames.count)
        let pendingPutCount = pendingMutationSummary.putFrameCount
        let baseFrameId = committedCount + UInt64(pendingPutCount)
        let defaultTimestampMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Pre-compute all frame data outside I/O
        struct PreparedFrame {
            let storedBytes: Data
            let putFrame: PutFrame
        }

        var prepared: [PreparedFrame] = []
        prepared.reserveCapacity(contents.count)
        var totalPayloadSize = 0
        var walPayloadSizes: [Int] = []
        walPayloadSizes.reserveCapacity(contents.count)

        for (index, content) in contents.enumerated() {
            let frameId = baseFrameId + UInt64(index)
            let canonicalChecksum = SHA256Checksum.digest(content)

            var storedBytes = content
            var canonicalEncoding: CanonicalEncoding = .plain
            if compression != .plain {
                do {
                    let compressed = try PayloadCompressor.compress(content, algorithm: CompressionKind(canonicalEncoding: compression))
                    if compressed.count < content.count {
                        storedBytes = compressed
                        canonicalEncoding = compression
                    }
                } catch {
                    storedBytes = content
                    canonicalEncoding = .plain
                }
            }

            let storedChecksum = SHA256Checksum.digest(storedBytes)
            let timestampMsForFrame = timestampsMs?[index] ?? defaultTimestampMs

            let putFrame = PutFrame(
                frameId: frameId,
                timestampMs: timestampMsForFrame,
                options: options[index],
                payloadOffset: 0,
                payloadLength: UInt64(storedBytes.count),
                canonicalEncoding: canonicalEncoding,
                canonicalLength: UInt64(content.count),
                canonicalChecksum: canonicalChecksum,
                storedChecksum: storedChecksum
            )
            let walPayloadSize = try WALEntryCodec.encode(.putFrame(putFrame)).count

            prepared.append(PreparedFrame(
                storedBytes: storedBytes,
                putFrame: putFrame
            ))
            walPayloadSizes.append(walPayloadSize)
            totalPayloadSize += storedBytes.count
        }

        func appendSequentially() async throws -> [UInt64] {
            var frameIds: [UInt64] = []
            frameIds.reserveCapacity(prepared.count)
            let file = self.file
            let wal = self.wal

            for (index, frame) in prepared.enumerated() {
                try await ensureWalCapacityLocked(payloadSize: walPayloadSizes[index])
                var putFrame = frame.putFrame
                putFrame.payloadOffset = allocateDataLocked(length: UInt64(frame.storedBytes.count))
                let entry = WALEntry.putFrame(putFrame)
                let walPayload = try WALEntryCodec.encode(entry)

                let payloadOffset = putFrame.payloadOffset
                let storedBytes = frame.storedBytes
                let seq = try await io.run {
                    try file.writeAll(storedBytes, at: payloadOffset)
                    return try wal.append(payload: walPayload)
                }
                appendPendingMutation(sequence: seq, entry: entry)
                frameIds.append(putFrame.frameId)
            }
            dirty = true
            return frameIds
        }

        // Check WAL capacity for entire batch. If the batch cannot fit as a unit,
        // fall back to per-entry appends (allows mid-batch commits).
        do {
            try await ensureWalCapacityLocked(payloadSizes: walPayloadSizes)
        } catch WaxError.capacityExceeded {
            return try await appendSequentially()
        }

        // Capture values for Sendable closure
        let file = self.file
        let wal = self.wal
        // One contiguous range for the batch, so its payloads go out in one I/O hop.
        let startOffset = allocateDataLocked(length: UInt64(totalPayloadSize))
        let storedBytesArray = prepared.map { $0.storedBytes }

        var walPayloadsArray: [Data] = []
        walPayloadsArray.reserveCapacity(prepared.count)
        var entries: [WALEntry] = []
        entries.reserveCapacity(prepared.count)
        var currentOffset = startOffset

        for frame in prepared {
            var putFrame = frame.putFrame
            putFrame.payloadOffset = currentOffset
            let entry = WALEntry.putFrame(putFrame)
            let walPayload = try WALEntryCodec.encode(entry)
            walPayloadsArray.append(walPayload)
            entries.append(entry)
            currentOffset += UInt64(frame.storedBytes.count)
        }

        // Checked pwrites of each payload at its contiguous offset, in one I/O hop.
        // Writing through an mmap of the file would turn ENOSPC or a concurrent
        // truncation into SIGBUS instead of an error; concatenating first would double
        // peak memory for large batches. These writes complete before `appendBatch`
        // below, so when the WAL needs a durable anchor its first fsync covers them.
        if totalPayloadSize > 0 {
            try await io.run {
                var offset = startOffset
                for storedBytes in storedBytesArray {
                    try file.writeAll(storedBytes, at: offset)
                    offset += UInt64(storedBytes.count)
                }
            }
        }

        // Batch append WAL entries
        let walPayloads = walPayloadsArray
        let sequences = try await io.run {
            try wal.appendBatch(payloads: walPayloads)
        }

        // Update state
        for (index, entry) in entries.enumerated() {
            appendPendingMutation(sequence: sequences[index], entry: entry)
        }
        dirty = true

        return prepared.map { $0.putFrame.frameId }
    }

    /// Batch put multiple frames in a single operation.
    /// This amortizes actor and I/O overhead across all frames.
    /// Returns frame IDs in the same order as the input contents.
    package func putBatch(
        _ contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        guard !contents.isEmpty else { return [] }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count (\(contents.count)) != options.count (\(options.count))")
        }

        return try await withWriteLock {
            try await putBatchLocked(contents, options: options, timestampsMs: nil, compression: compression)
        }
    }

    /// Batch put multiple frames with caller-provided timestamps.
    /// The `timestampsMs` array must match `contents` order and length.
    package func putBatch(
        _ contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain,
        timestampsMs: [Int64]
    ) async throws -> [UInt64] {
        guard !contents.isEmpty else { return [] }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count (\(contents.count)) != options.count (\(options.count))")
        }
        guard contents.count == timestampsMs.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count (\(contents.count)) != timestampsMs.count (\(timestampsMs.count))")
        }

        return try await withWriteLock {
            try await putBatchLocked(contents, options: options, timestampsMs: timestampsMs, compression: compression)
        }
    }

    /// Batch put embeddings for multiple frames in a single operation.
    package func putEmbeddingBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "putEmbeddingBatch: frameIds.count != vectors.count")
        }

        try await withEmbeddingWriteLock {
            // Validate all vectors first
            var dimension: UInt32?
            for vector in vectors {
                guard !vector.isEmpty else {
                    throw WaxError.encodingError(reason: "embedding vector must be non-empty")
                }
                guard vector.count <= Constants.maxEmbeddingDimensions else {
                    throw WaxError.capacityExceeded(
                        limit: UInt64(Constants.maxEmbeddingDimensions),
                        requested: UInt64(vector.count)
                    )
                }
                let dim = UInt32(vector.count)
                if let existing = dimension {
                    guard existing == dim else {
                        throw WaxError.encodingError(reason: "all embeddings in batch must have same dimension")
                    }
                } else {
                    dimension = dim
                }
            }

            guard let dimension else { return }

            // Check dimension consistency with committed/staged indexes
            if let committed = toc.indexes.vec {
                guard committed.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs committed vec index: expected \(committed.dimension), got \(dimension)"
                    )
                }
            }
            if let configured = vectorConfiguration {
                guard configured.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs vec index configuration: expected \(configured.dimension), got \(dimension)"
                    )
                }
            }

            // Pre-encode all WAL entries
            var walPayloads: [Data] = []
            walPayloads.reserveCapacity(frameIds.count)
            var entries: [WALEntry] = []
            entries.reserveCapacity(frameIds.count)
            var walPayloadSizes: [Int] = []
            walPayloadSizes.reserveCapacity(frameIds.count)

            for (frameId, vector) in zip(frameIds, vectors) {
                let entry = WALEntry.putEmbedding(
                    PutEmbedding(frameId: frameId, dimension: dimension, vector: vector)
                )
                let payload = try WALEntryCodec.encode(entry)
                walPayloads.append(payload)
                entries.append(entry)
                walPayloadSizes.append(payload.count)
            }

            try await ensureWalCapacityLocked(payloadSizes: walPayloadSizes)

            // Capture for Sendable closure
            let wal = self.wal
            let walPayloadsArray = walPayloads  // Copy to let binding

            let sequences = try await io.run {
                try wal.appendBatch(payloads: walPayloadsArray)
            }

            // Update state
            for (index, entry) in entries.enumerated() {
                appendPendingMutation(sequence: sequences[index], entry: entry)
            }
            dirty = true
        }
    }

    package func putEmbedding(frameId: UInt64, vector: [Float]) async throws {
        try await withEmbeddingWriteLock {
            guard !vector.isEmpty else {
                throw WaxError.encodingError(reason: "embedding vector must be non-empty")
            }
            guard vector.count <= Constants.maxEmbeddingDimensions else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxEmbeddingDimensions),
                    requested: UInt64(vector.count)
                )
            }
            guard vector.count <= Int(UInt32.max) else {
                throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: UInt64(vector.count))
            }

            let dimension = UInt32(vector.count)

            if let committed = toc.indexes.vec {
                guard committed.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs committed vec index: expected \(committed.dimension), got \(dimension)"
                    )
                }
            }
            if let configured = vectorConfiguration {
                guard configured.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs vec index configuration: expected \(configured.dimension), got \(dimension)"
                    )
                }
            }
            let entry = WALEntry.putEmbedding(
                PutEmbedding(frameId: frameId, dimension: dimension, vector: vector)
            )
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            appendPendingMutation(sequence: seq, entry: entry)
            dirty = true
        }
    }

    package func pendingEmbeddingMutations() async -> [PutEmbedding] {
        let snapshot = await pendingEmbeddingMutations(since: nil)
        return snapshot.embeddings
    }

    /// The pending vector changes with their WAL sequences, in WAL order.
    /// Internal only because of the file split; use only under `opLock`.
    func pendingVectorChangesLocked() -> [(sequence: UInt64, change: PendingVectorChange)] {
        orderedPendingMutationsLocked().compactMap { mutation in
            switch mutation.entry {
            case .putEmbedding(let embedding): (mutation.sequence, .put(embedding))
            case .removeEmbedding(let removal): (mutation.sequence, .remove(removal.frameId))
            case .putFrame, .deleteFrame, .supersedeFrame: nil
            }
        }
    }

    /// The pending vector changes after `sequence` (all of them for `nil`), reduced to each
    /// frame's last change in that window.
    package func pendingEmbeddingMutations(since sequence: UInt64?) async -> PendingEmbeddingSnapshot {
        await withReadLock {
            guard pendingMutationSummary.hasPendingVectorChange else {
                return PendingEmbeddingSnapshot(embeddings: [], latestSequence: nil)
            }
            var changes: [PendingVectorChange] = []
            var latestSequence: UInt64?
            for (changeSequence, change) in pendingVectorChangesLocked() {
                latestSequence = changeSequence
                if let sequence, changeSequence <= sequence { continue }
                changes.append(change)
            }
            let reduced = PendingVectorChange.lastChanges(changes)
            return PendingEmbeddingSnapshot(
                embeddings: reduced.embeddings,
                removedFrameIds: reduced.removedFrameIds.sorted(),
                latestSequence: latestSequence
            )
        }
    }

    /// Removes `frameId`'s vector at the next commit, and any embedding written for it before.
    /// A frame with neither writes nothing.
    package func removeEmbedding(frameId: UInt64) async throws {
        try await withEmbeddingWriteLock {
            try validateKnownFrameForMutationLocked(frameId)
            // Photo and video rebuilds remove every retired frame's vector each time.
            guard try await hasVectorToRemoveLocked(frameId: frameId) else { return }
            // Format 1.0 cannot read this record, so no 1.0 build may open the file after it.
            try await ensureHeaderPagesCurrentLocked()
            let entry = WALEntry.removeEmbedding(RemoveEmbedding(frameId: frameId))
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            appendPendingMutation(sequence: seq, entry: entry)
            dirty = true
        }
    }

    package func delete(frameId: UInt64) async throws {
        try await withWriteLock {
            try validateKnownFrameForMutationLocked(frameId)
            let entry = WALEntry.deleteFrame(DeleteFrame(frameId: frameId))
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            appendPendingMutation(sequence: seq, entry: entry)
            dirty = true
        }
    }

    package func supersede(supersededId: UInt64, supersedingId: UInt64) async throws {
        try await withWriteLock {
            guard supersededId != supersedingId else {
                throw WaxError.invalidToc(reason: "supersedeFrame requires distinct ids")
            }
            try validateKnownFrameForMutationLocked(supersededId)
            try validateKnownFrameForMutationLocked(supersedingId)

            // Check committed state for reverse relationship
            if supersededId < UInt64(toc.frames.count) {
                let supersededMeta = toc.frames[Int(supersededId)]
                if supersededMeta.supersedes == supersedingId {
                    throw WaxError.invalidToc(reason: "supersede cycle detected: frame \(supersededId) already supersedes frame \(supersedingId)")
                }
            }
            if supersedingId < UInt64(toc.frames.count) {
                let supersedingMeta = toc.frames[Int(supersedingId)]
                if supersedingMeta.supersededBy == supersededId {
                    throw WaxError.invalidToc(reason: "supersede cycle detected: frame \(supersedingId) is already superseded by frame \(supersededId)")
                }
            }
            // Check pending mutations for reverse relationship
            for pending in pendingMutations {
                if case .supersedeFrame(let s) = pending.entry,
                   s.supersededId == supersedingId, s.supersedingId == supersededId {
                    throw WaxError.invalidToc(reason: "supersede cycle detected: reverse supersede already pending for frames \(supersededId) and \(supersedingId)")
                }
            }

            let entry = WALEntry.supersedeFrame(
                SupersedeFrame(supersededId: supersededId, supersedingId: supersedingId)
            )
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            appendPendingMutation(sequence: seq, entry: entry)
            dirty = true
        }
    }

    private func validateKnownFrameForMutationLocked(_ frameId: UInt64) throws {
        let committedCount = UInt64(toc.frames.count)
        let maxKnown = committedCount.addingReportingOverflow(pendingMutationSummary.putFrameCount)
        guard !maxKnown.overflow else {
            throw WaxError.invalidToc(reason: "known frame id range overflows")
        }
        guard frameId < maxKnown.partialValue else {
            throw WaxError.invalidToc(
                reason: "mutation references unknown frameId \(frameId) (known < \(maxKnown.partialValue))"
            )
        }
    }

    /// Internal only because of the file split.
    struct PendingMutationSummary {
        var putFrameCount: UInt64 = 0
        var hasPendingEmbedding = false
        /// An embedding or a removal is pending.
        var hasPendingVectorChange = false
        var latestPendingEmbeddingSequence: UInt64?
        var pendingEmbeddingDimension: UInt32?
        var pendingEmbeddingHasMixedDimensions = false
        var isOrderedBySequence = true

        private var lastSequence: UInt64?

        mutating func record(_ mutation: PendingMutation) {
            if let lastSequence, mutation.sequence <= lastSequence {
                isOrderedBySequence = false
            }
            self.lastSequence = mutation.sequence

            switch mutation.entry {
            case .putFrame:
                putFrameCount &+= 1
            case .putEmbedding(let embedding):
                hasPendingEmbedding = true
                hasPendingVectorChange = true
                latestPendingEmbeddingSequence = mutation.sequence
                if let pendingEmbeddingDimension, pendingEmbeddingDimension != embedding.dimension {
                    pendingEmbeddingHasMixedDimensions = true
                } else {
                    pendingEmbeddingDimension = embedding.dimension
                }
            case .removeEmbedding:
                hasPendingVectorChange = true
                latestPendingEmbeddingSequence = mutation.sequence
            case .deleteFrame, .supersedeFrame:
                break
            }
        }

        static func from(_ mutations: [PendingMutation]) -> PendingMutationSummary {
            var summary = PendingMutationSummary()
            summary.putFrameCount = 0
            for mutation in mutations {
                summary.record(mutation)
            }
            return summary
        }
    }
}
