import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Wax {
    // MARK: - Mutations

    private func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func appendPendingMutation(sequence: UInt64, entry: WALEntry) {
        let mutation = PendingMutation(sequence: sequence, entry: entry)
        pendingMutations.append(mutation)
        pendingMutationSummary.record(mutation)
    }

    private func clearPendingMutations() {
        pendingMutations.removeAll(keepingCapacity: true)
        pendingMutationSummary = PendingMutationSummary()
    }

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

        let payloadOffset = dataEnd
        let entry = WALEntry.putFrame(
            PutFrame(
                frameId: frameId,
                timestampMs: timestampMs ?? currentTimestampMs(),
                options: options,
                payloadOffset: payloadOffset,
                payloadLength: UInt64(storedBytes.count),
                canonicalEncoding: canonicalEncoding,
                canonicalLength: UInt64(content.count),
                canonicalChecksum: canonicalChecksum,
                storedChecksum: storedChecksum
            )
        )
        let payload = try WALEntryCodec.encode(entry)
        try await ensureWalCapacityLocked(payloadSize: payload.count)
        let file = self.file
        let wal = self.wal
        let bytesToStore = storedBytes
        let seq = try await io.run {
            try file.writeAll(bytesToStore, at: payloadOffset)
            return try wal.append(payload: payload)
        }

        dataEnd += UInt64(storedBytes.count)
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
                putFrame.payloadOffset = dataEnd
                let entry = WALEntry.putFrame(putFrame)
                let walPayload = try WALEntryCodec.encode(entry)

                let payloadOffset = putFrame.payloadOffset
                let storedBytes = frame.storedBytes
                let seq = try await io.run {
                    try file.writeAll(storedBytes, at: payloadOffset)
                    return try wal.append(payload: walPayload)
                }
                dataEnd += UInt64(frame.storedBytes.count)
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
        let startOffset = dataEnd
        let storedBytesArray = prepared.map { $0.storedBytes }

        var walPayloadsArray: [Data] = []
        walPayloadsArray.reserveCapacity(prepared.count)
        var entries: [WALEntry] = []
        entries.reserveCapacity(prepared.count)
        var currentOffset = dataEnd

        for frame in prepared {
            var putFrame = frame.putFrame
            putFrame.payloadOffset = currentOffset
            let entry = WALEntry.putFrame(putFrame)
            let walPayload = try WALEntryCodec.encode(entry)
            walPayloadsArray.append(walPayload)
            entries.append(entry)
            currentOffset += UInt64(frame.storedBytes.count)
        }

        // Single mapped write for payloads
        let payloadLength = totalPayloadSize
        if payloadLength > 0 {
            try await io.run {
                try file.ensureSize(atLeast: startOffset + UInt64(payloadLength))
                let region = try file.mapWritable(length: payloadLength, at: startOffset)
                defer { region.close() }

                var cursor = 0
                guard let base = region.buffer.baseAddress else {
                    throw WaxError.io("mapped region baseAddress is nil")
                }
                for storedBytes in storedBytesArray {
                    storedBytes.withUnsafeBytes { src in
                        guard let srcBase = src.baseAddress else { return }
                        base.advanced(by: cursor).copyMemory(from: srcBase, byteCount: storedBytes.count)
                    }
                    cursor += storedBytes.count
                }
            }
        }

        // Batch append WAL entries
        let walPayloads = walPayloadsArray
        let sequences = try await io.run {
            try wal.appendBatch(payloads: walPayloads)
        }

        // Update state
        dataEnd = currentOffset
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

        try await withWriteLock {
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
            if let staged = stagedVecIndex {
                guard staged.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs staged vec index: expected \(staged.dimension), got \(dimension)"
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
        try await withWriteLock {
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
            if let staged = stagedVecIndex {
                guard staged.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs staged vec index: expected \(staged.dimension), got \(dimension)"
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

    package func pendingEmbeddingMutations(since sequence: UInt64?) async -> PendingEmbeddingSnapshot {
        await withReadLock {
            guard pendingMutationSummary.hasPendingEmbedding else {
                return PendingEmbeddingSnapshot(embeddings: [], latestSequence: nil)
            }
            var embeddings: [PutEmbedding] = []
            embeddings.reserveCapacity(pendingMutations.count)
            var latestSequence: UInt64?
            for mutation in pendingMutations {
                guard case .putEmbedding(let embedding) = mutation.entry else { continue }
                latestSequence = mutation.sequence
                if let sequence, mutation.sequence <= sequence { continue }
                embeddings.append(embedding)
            }
            return PendingEmbeddingSnapshot(embeddings: embeddings, latestSequence: latestSequence)
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

    package func pendingFrameMeta(frameId: UInt64) async -> FrameMeta? {
        await withReadLock {
            let maxCommittedId = UInt64(toc.frames.count)
            guard frameId >= maxCommittedId else { return nil }
            return frameMetasIncludingPendingUnlocked(frameIds: [frameId])[frameId]
        }
    }

    package func stageLexIndexForNextCommit(bytes: Data, docCount: UInt64, version: UInt32 = 1) async throws {
        try await withWriteLock {
            guard version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported lex index version \(version)")
            }
            guard !bytes.isEmpty else {
                throw WaxError.io("lex index bytes must be non-empty (expected sqlite3_serialize output)")
            }
            let byteCount = bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }

            let checksum = SHA256Checksum.digest(bytes)
            let bytesLength = UInt64(byteCount)

            if let stagedLexIndex {
                if stagedLexIndex.docCount == docCount,
                   stagedLexIndex.version == version,
                   UInt64(stagedLexIndex.bytes.count) == bytesLength,
                   stagedLexIndex.checksum == checksum {
                    return
                }
            }

            if let committed = toc.indexes.lex,
               committed.docCount == docCount,
               committed.version == version,
               committed.bytesLength == bytesLength,
               committed.checksum == checksum {
                stagedLexIndex = nil
                stagedLexIndexStamp = nil
                return
            }

            stagedLexIndex = StagedLexIndex(
                bytes: bytes,
                docCount: docCount,
                version: version,
                checksum: checksum
            )
            stagedLexIndexStampCounter &+= 1
            stagedLexIndexStamp = stagedLexIndexStampCounter
            dirty = true
        }
    }

    package func stageVecIndexForNextCommit(
        bytes: Data,
        vectorCount: UInt64,
        dimension: UInt32,
        similarity: VecSimilarity
    ) async throws {
        try await withWriteLock {
            guard !bytes.isEmpty else {
                throw WaxError.io("vec index bytes must be non-empty")
            }
            let byteCount = bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }
            guard dimension > 0 else {
                throw WaxError.io("vec index dimension must be > 0")
            }
            guard dimension <= UInt32(Constants.maxEmbeddingDimensions) else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxEmbeddingDimensions),
                    requested: UInt64(dimension)
                )
            }
            try Self.validateVecIndexSegment(
                bytes,
                vectorCount: vectorCount,
                dimension: dimension,
                similarity: similarity
            )

            if let committed = toc.indexes.vec {
                guard committed.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "staged vec dimension mismatch vs committed vec index: expected \(committed.dimension), got \(dimension)"
                    )
                }
                guard committed.similarity == similarity else {
                    throw WaxError.invalidToc(
                        reason: "staged vec similarity mismatch vs committed vec index: expected \(committed.similarity), got \(similarity)"
                    )
                }
            }

            let pendingEmbeddingMaxSequence = pendingMutationSummary.latestPendingEmbeddingSequence
            if pendingMutationSummary.hasPendingEmbedding {
                let matchesDimension = !pendingMutationSummary.pendingEmbeddingHasMixedDimensions
                    && pendingMutationSummary.pendingEmbeddingDimension == dimension
                guard matchesDimension else {
                    let actualDimension: String
                    if pendingMutationSummary.pendingEmbeddingHasMixedDimensions {
                        actualDimension = "mixed"
                    } else if let pendingDimension = pendingMutationSummary.pendingEmbeddingDimension {
                        actualDimension = String(pendingDimension)
                    } else {
                        actualDimension = "none"
                    }
                    throw WaxError.invalidToc(
                        reason: "pending embedding dimension mismatch vs staged vec index: expected \(dimension), got \(actualDimension)"
                    )
                }
            }

            let checksum = SHA256Checksum.digest(bytes)
            let bytesLength = UInt64(byteCount)

            if let stagedVecIndex {
                if stagedVecIndex.vectorCount == vectorCount,
                   stagedVecIndex.dimension == dimension,
                   stagedVecIndex.similarity == similarity,
                   stagedVecIndex.pendingEmbeddingMaxSequence == pendingEmbeddingMaxSequence,
                   UInt64(stagedVecIndex.bytes.count) == bytesLength,
                   stagedVecIndex.checksum == checksum {
                    return
                }
            }

            if pendingEmbeddingMaxSequence == nil,
               let committed = toc.indexes.vec,
               committed.vectorCount == vectorCount,
               committed.dimension == dimension,
               committed.similarity == similarity,
               committed.bytesLength == bytesLength,
               committed.checksum == checksum {
                stagedVecIndex = nil
                stagedVecIndexStamp = nil
                return
            }

            stagedVecIndex = StagedVecIndex(
                bytes: bytes,
                vectorCount: vectorCount,
                dimension: dimension,
                similarity: similarity,
                pendingEmbeddingMaxSequence: pendingEmbeddingMaxSequence,
                checksum: checksum
            )
            stagedVecIndexStampCounter &+= 1
            stagedVecIndexStamp = stagedVecIndexStampCounter
            dirty = true
        }
    }

    private static func validateVecIndexSegment(
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

    package func commit() async throws {
        try await withWriteLock {
            try await commitLocked()
        }
    }

    func commitLocked() async throws {
        guard dirty || stagedLexIndex != nil || stagedVecIndex != nil else { return }

        if stagedVecIndex == nil {
            if pendingMutationSummary.hasPendingEmbedding {
                throw WaxError.io("vector index must be staged before committing embeddings")
            }
        } else if let stagedVecIndex {
            let latestPendingEmbeddingSequence = pendingMutationSummary.latestPendingEmbeddingSequence
            if latestPendingEmbeddingSequence != stagedVecIndex.pendingEmbeddingMaxSequence {
                throw WaxError.io(
                    "vector index is stale relative to pending embeddings; restage vector index before commit"
                )
            }
        }

        let rollbackState = CommitRollbackState.capture(from: self)
        var commitSucceeded = false
        defer {
            if !commitSucceeded {
                rollbackState.restore(into: self)
            }
        }

        let applied = try applyPendingMutationsIntoTOC()
        let appliedWalSeq = applied.maxSequence
        let cachedFramesPayload = try encodedCommittedFramePayloadForCommit(
            appendedFrames: applied.appendedFrames,
            invalidated: applied.modifiedCommittedFrames
        )

        let file = self.file
        if let staged = stagedLexIndex {
            let byteCount = staged.bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }
            let lexOffset = dataEnd
            try await io.run {
                try file.writeAll(staged.bytes, at: lexOffset)
            }
            let lexLength = UInt64(byteCount)
            dataEnd += lexLength

            toc.indexes.lex = LexIndexManifest(
                docCount: staged.docCount,
                bytesOffset: lexOffset,
                bytesLength: lexLength,
                checksum: staged.checksum,
                version: staged.version
            )
            let segmentId = nextSegmentId()
            let entry = SegmentCatalogEntry(
                segmentId: segmentId,
                bytesOffset: lexOffset,
                bytesLength: lexLength,
                checksum: staged.checksum,
                compression: .none,
                kind: .lex
            )
            toc.segmentCatalog.entries.append(entry)
        }

        if let staged = stagedVecIndex {
            let byteCount = staged.bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }

            let vecOffset = dataEnd
            try await io.run {
                try file.writeAll(staged.bytes, at: vecOffset)
            }
            let vecLength = UInt64(byteCount)
            dataEnd += vecLength

            toc.indexes.vec = VecIndexManifest(
                vectorCount: staged.vectorCount,
                dimension: staged.dimension,
                bytesOffset: vecOffset,
                bytesLength: vecLength,
                checksum: staged.checksum,
                similarity: staged.similarity
            )
            let segmentId = nextSegmentId()
            let entry = SegmentCatalogEntry(
                segmentId: segmentId,
                bytesOffset: vecOffset,
                bytesLength: vecLength,
                checksum: staged.checksum,
                compression: .none,
                kind: .vec
            )
            toc.segmentCatalog.entries.append(entry)
        }

        let tocBytes = try toc.encode(cachedFramesPayload: cachedFramesPayload)
        let tocChecksum = tocBytes.suffix(32)
        toc.tocChecksum = Data(tocChecksum)

        let tocOffset = dataEnd
        let footerOffset = tocOffset + UInt64(tocBytes.count)
        let footer = WaxFooter(
            tocLen: UInt64(tocBytes.count),
            tocHash: Data(tocChecksum),
            generation: generation &+ 1,
            walCommittedSeq: appliedWalSeq
        )
        let wal = self.wal
        let walState = await io.run {
            (
                writePos: wal.writePos,
                lastSequence: wal.lastSequence
            )
        }
        let replaySnapshot = WaxHeaderPage.WALReplaySnapshot(
            fileGeneration: footer.generation,
            walCommittedSeq: appliedWalSeq,
            footerOffset: footerOffset,
            walWritePos: walState.writePos,
            walCheckpointPos: walState.writePos,
            walPendingBytes: 0,
            walLastSequence: max(appliedWalSeq, walState.lastSequence)
        )

        if walReplayStateSnapshotEnabled {
            try await persistReplaySnapshotOnSelectedHeaderPage(replaySnapshot)
        }

        try await io.run {
            try file.writeAll(tocBytes, at: tocOffset)
        }
        Self.maybeCrashAfterCheckpoint(.afterTocWriteBeforeFooter)

        try await io.run {
            try file.writeAll(try footer.encode(), at: footerOffset)
        }
        Self.maybeCrashAfterCheckpoint(.afterFooterWriteBeforeFsync)

        try await io.run {
            try file.fsync()
        }
        Self.maybeCrashAfterCheckpoint(.afterFooterFsyncBeforeHeader)

        header.footerOffset = footerOffset
        header.fileGeneration = footer.generation
        header.tocChecksum = Data(tocChecksum)
        header.walCommittedSeq = appliedWalSeq
        header.walReplaySnapshot = replaySnapshot
        header.walCheckpointPos = walState.writePos
        header.walWritePos = walState.writePos
        header.headerPageGeneration &+= 1

        try await writeHeaderPage(header)
        Self.maybeCrashAfterCheckpoint(.afterHeaderWriteBeforeFinalFsync)
        try await io.run {
            try file.fsync()
            wal.recordCheckpoint()
        }

        clearPendingMutations()
        stagedLexIndex = nil
        stagedVecIndex = nil
        stagedLexIndexStamp = nil
        stagedVecIndexStamp = nil
        surrogateIndex = nil
        dirty = false
        generation = footer.generation
        dataEnd = footerOffset + Constants.footerSize
        commitSucceeded = true
    }

    private struct CommitRollbackState {
        var header: WaxHeaderPage
        var selectedHeaderPageIndex: Int
        var toc: WaxTOC
        var surrogateIndex: [UInt64: UInt64]?
        var pendingMutations: [PendingMutation]
        var pendingMutationSummary: PendingMutationSummary
        var encodedCommittedFramePayloadCache: Data?
        var stagedLexIndex: StagedLexIndex?
        var stagedVecIndex: StagedVecIndex?
        var stagedLexIndexStamp: UInt64?
        var stagedVecIndexStamp: UInt64?
        var stagedLexIndexStampCounter: UInt64
        var stagedVecIndexStampCounter: UInt64
        var dataEnd: UInt64
        var generation: UInt64
        var dirty: Bool

        static func capture(from wax: isolated Wax) -> CommitRollbackState {
            CommitRollbackState(
                header: wax.header,
                selectedHeaderPageIndex: wax.selectedHeaderPageIndex,
                toc: wax.toc,
                surrogateIndex: wax.surrogateIndex,
                pendingMutations: wax.pendingMutations,
                pendingMutationSummary: wax.pendingMutationSummary,
                encodedCommittedFramePayloadCache: wax.encodedCommittedFramePayloadCache,
                stagedLexIndex: wax.stagedLexIndex,
                stagedVecIndex: wax.stagedVecIndex,
                stagedLexIndexStamp: wax.stagedLexIndexStamp,
                stagedVecIndexStamp: wax.stagedVecIndexStamp,
                stagedLexIndexStampCounter: wax.stagedLexIndexStampCounter,
                stagedVecIndexStampCounter: wax.stagedVecIndexStampCounter,
                dataEnd: wax.dataEnd,
                generation: wax.generation,
                dirty: wax.dirty
            )
        }

        func restore(into wax: isolated Wax) {
            wax.header = header
            wax.selectedHeaderPageIndex = selectedHeaderPageIndex
            wax.toc = toc
            wax.surrogateIndex = surrogateIndex
            wax.pendingMutations = pendingMutations
            wax.pendingMutationSummary = pendingMutationSummary
            wax.encodedCommittedFramePayloadCache = encodedCommittedFramePayloadCache
            wax.stagedLexIndex = stagedLexIndex
            wax.stagedVecIndex = stagedVecIndex
            wax.stagedLexIndexStamp = stagedLexIndexStamp
            wax.stagedVecIndexStamp = stagedVecIndexStamp
            wax.stagedLexIndexStampCounter = stagedLexIndexStampCounter
            wax.stagedVecIndexStampCounter = stagedVecIndexStampCounter
            wax.dataEnd = dataEnd
            wax.generation = generation
            wax.dirty = dirty
        }
    }

}
