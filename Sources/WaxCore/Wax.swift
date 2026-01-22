import Foundation

public struct WaxStats: Equatable, Sendable {
    public var frameCount: UInt64
    public var pendingFrames: UInt64
    public var generation: UInt64

    public init(frameCount: UInt64, pendingFrames: UInt64, generation: UInt64) {
        self.frameCount = frameCount
        self.pendingFrames = pendingFrames
        self.generation = generation
    }
}

public struct PendingEmbeddingSnapshot: Equatable, Sendable {
    public let embeddings: [PutEmbedding]
    public let latestSequence: UInt64?

    public init(embeddings: [PutEmbedding], latestSequence: UInt64?) {
        self.embeddings = embeddings
        self.latestSequence = latestSequence
    }
}

/// Primary handle for interacting with a `.mv2s` memory file.
///
/// Holds the file descriptor, lock, header, TOC, and in-memory index state.
/// All mutable state is isolated within this actor for thread safety.
public actor Wax {
    private let url: URL
    private let io: BlockingIOExecutor
    private let opLock = AsyncMutex()
    private var file: FDFile
    private var lock: FileLock

    private var header: MV2SHeaderPage
    private var selectedHeaderPageIndex: Int

    private var toc: MV2STOC
    private var surrogateIndex: [UInt64: UInt64]? = nil
    private var wal: WALRingWriter
    private var pendingMutations: [PendingMutation]
    private var stagedLexIndex: StagedLexIndex?
    private var stagedVecIndex: StagedVecIndex?
    private var stagedLexIndexStamp: UInt64?
    private var stagedVecIndexStamp: UInt64?
    private var stagedLexIndexStampCounter: UInt64
    private var stagedVecIndexStampCounter: UInt64

    private var dataEnd: UInt64
    private var generation: UInt64
    private var dirty: Bool

    private init(
        url: URL,
        io: BlockingIOExecutor,
        file: FDFile,
        lock: FileLock,
        header: MV2SHeaderPage,
        selectedHeaderPageIndex: Int,
        toc: MV2STOC,
        wal: WALRingWriter,
        pendingMutations: [PendingMutation],
        stagedLexIndex: StagedLexIndex?,
        stagedVecIndex: StagedVecIndex?,
        stagedLexIndexStamp: UInt64?,
        stagedVecIndexStamp: UInt64?,
        stagedLexIndexStampCounter: UInt64,
        stagedVecIndexStampCounter: UInt64,
        dataEnd: UInt64,
        generation: UInt64,
        dirty: Bool
    ) {
        self.url = url
        self.io = io
        self.file = file
        self.lock = lock
        self.header = header
        self.selectedHeaderPageIndex = selectedHeaderPageIndex
        self.toc = toc
        self.wal = wal
        self.pendingMutations = pendingMutations
        self.stagedLexIndex = stagedLexIndex
        self.stagedVecIndex = stagedVecIndex
        self.stagedLexIndexStamp = stagedLexIndexStamp
        self.stagedVecIndexStamp = stagedVecIndexStamp
        self.stagedLexIndexStampCounter = stagedLexIndexStampCounter
        self.stagedVecIndexStampCounter = stagedVecIndexStampCounter
        self.dataEnd = dataEnd
        self.generation = generation
        self.dirty = dirty
    }

    private func withOpLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.lock()
        do {
            let value = try await body()
            await opLock.unlock()
            return value
        } catch {
            await opLock.unlock()
            throw error
        }
    }

    private func ensureWalCapacityLocked(payloadSize: Int) async throws {
        if wal.canAppend(payloadSize: payloadSize) {
            return
        }

        let hasPendingEmbedding = pendingMutations.contains { mutation in
            if case .putEmbedding = mutation.entry { return true }
            return false
        }
        if hasPendingEmbedding && stagedVecIndex == nil {
            throw WaxError.io("WAL capacity exceeded before vector index staged; stageForCommit() and commit() earlier or increase wal_size.")
        }

        try await commitLocked()
        guard wal.canAppend(payloadSize: payloadSize) else {
            throw WaxError.capacityExceeded(limit: wal.walSize, requested: UInt64(payloadSize))
        }
    }

    // MARK: - Lifecycle

    /// Create a new, empty `.mv2s` file.
    public static func create(
        at url: URL,
        walSize: UInt64 = Constants.defaultWalSize,
        options: WaxOptions = .init()
    ) async throws -> Wax {
        guard walSize >= Constants.walRecordHeaderSize else {
            throw WaxError.invalidHeader(reason: "wal_size must be >= \(Constants.walRecordHeaderSize)")
        }

        let io = BlockingIOExecutor(label: options.ioQueueLabel, qos: options.ioQueueQos)
        let created = try await io.run { () throws -> (
            file: FDFile,
            lock: FileLock,
            header: MV2SHeaderPage,
            toc: MV2STOC,
            wal: WALRingWriter,
            dataEnd: UInt64
        ) in
            let file = try FDFile.create(at: url)
            let lock: FileLock
            do {
                lock = try FileLock.acquire(at: url, mode: .exclusive)
            } catch {
                try? file.close()
                throw error
            }

            let walOffset = Constants.walOffset
            let dataStart = walOffset + walSize

            var toc = MV2STOC.emptyV1()
            let tocBytes = try toc.encode()
            let tocChecksum = tocBytes.suffix(32)
            toc.tocChecksum = Data(tocChecksum)

            let tocOffset = dataStart
            try file.writeAll(tocBytes, at: tocOffset)
            let footerOffset = tocOffset + UInt64(tocBytes.count)
            let footer = MV2SFooter(
                tocLen: UInt64(tocBytes.count),
                tocHash: Data(tocChecksum),
                generation: 0,
                walCommittedSeq: 0
            )
            try file.writeAll(try footer.encode(), at: footerOffset)
            try file.fsync()

            let headerA = MV2SHeaderPage(
                headerPageGeneration: 1,
                fileGeneration: 0,
                footerOffset: footerOffset,
                walOffset: walOffset,
                walSize: walSize,
                walWritePos: 0,
                walCheckpointPos: 0,
                walCommittedSeq: 0,
                tocChecksum: Data(tocChecksum)
            )
            let pageABytes = try headerA.encodeWithChecksum()
            try file.writeAll(pageABytes, at: 0)
            var headerB = headerA
            headerB.headerPageGeneration = 0
            let pageBBytes = try headerB.encodeWithChecksum()
            try file.writeAll(pageBBytes, at: Constants.headerPageSize)
            try file.fsync()

            let wal = WALRingWriter(
                file: file,
                walOffset: walOffset,
                walSize: walSize,
                fsyncPolicy: options.walFsyncPolicy
            )

            return (
                file: file,
                lock: lock,
                header: headerA,
                toc: toc,
                wal: wal,
                dataEnd: footerOffset + Constants.footerSize
            )
        }

        return Wax(
            url: url,
            io: io,
            file: created.file,
            lock: created.lock,
            header: created.header,
            selectedHeaderPageIndex: 0,
            toc: created.toc,
            wal: created.wal,
            pendingMutations: [],
            stagedLexIndex: nil,
            stagedVecIndex: nil,
            stagedLexIndexStamp: nil,
            stagedVecIndexStamp: nil,
            stagedLexIndexStampCounter: 0,
            stagedVecIndexStampCounter: 0,
            dataEnd: created.dataEnd,
            generation: 0,
            dirty: false
        )
    }

    /// Open an existing `.mv2s` file.
    ///
    /// By default, Wax will repair trailing bytes beyond the last valid footer while preserving any
    /// uncommitted payload bytes referenced by the pending WAL.
    public static func open(at url: URL, options: WaxOptions = .init()) async throws -> Wax {
        try await open(at: url, repair: true, options: options)
    }

    /// Open an existing `.mv2s` file, optionally repairing trailing bytes past the last valid footer.
    ///
    /// If `repair` is true and the file contains bytes beyond the last valid footer, the file is truncated to the
    /// smallest safe end offset:
    /// - `footerOffset + footerSize` (latest committed state), and
    /// - the highest `payloadOffset + payloadLength` referenced by the pending WAL (to preserve uncommitted puts).
    public static func open(at url: URL, repair: Bool, options: WaxOptions = .init()) async throws -> Wax {
        let io = BlockingIOExecutor(label: options.ioQueueLabel, qos: options.ioQueueQos)
        let opened = try await io.run { () throws -> (
            file: FDFile,
            lock: FileLock,
            header: MV2SHeaderPage,
            selectedHeaderPageIndex: Int,
            toc: MV2STOC,
            wal: WALRingWriter,
            pendingMutations: [PendingMutation],
            dataEnd: UInt64,
            generation: UInt64,
            dirty: Bool
        ) in
            let lock = try FileLock.acquire(at: url, mode: .exclusive)
            let file = try FDFile.open(at: url)

            let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
            let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
            guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
                throw WaxError.invalidHeader(reason: "no valid header pages")
            }
            var header = selected.page

            let footerSlice: FooterSlice
            if let fastFooter = try FooterScanner.findFooter(at: header.footerOffset, in: url) {
                footerSlice = fastFooter
            } else {
                guard let scanned = try FooterScanner.findLastValidFooter(in: url) else {
                    throw WaxError.invalidFooter(reason: "no valid footer found within max_footer_scan_bytes")
                }
                footerSlice = scanned
            }

            let toc = try MV2STOC.decode(from: footerSlice.tocBytes)
            let dataStart = header.walOffset + header.walSize
            try Self.validateTocRanges(toc, dataStart: dataStart, dataEnd: footerSlice.footerOffset)
            header.footerOffset = footerSlice.footerOffset
            header.fileGeneration = footerSlice.footer.generation
            header.walCommittedSeq = footerSlice.footer.walCommittedSeq
            header.tocChecksum = footerSlice.footer.tocHash

            let walReader = WALRingReader(file: file, walOffset: header.walOffset, walSize: header.walSize)
            let committedSeq = footerSlice.footer.walCommittedSeq
            let pendingMutations = try walReader.scanPendingMutations(
                from: header.walCheckpointPos,
                committedSeq: committedSeq
            )

            let scanState = try walReader.scanState(from: header.walCheckpointPos)
            let lastSequence = max(committedSeq, scanState.lastSequence)
            let effectiveCheckpointPos: UInt64
            let effectivePendingBytes: UInt64
            if scanState.lastSequence <= committedSeq {
                effectiveCheckpointPos = scanState.writePos
                effectivePendingBytes = 0
            } else {
                effectiveCheckpointPos = header.walCheckpointPos
                effectivePendingBytes = scanState.pendingBytes
            }
            let wal = WALRingWriter(
                file: file,
                walOffset: header.walOffset,
                walSize: header.walSize,
                writePos: scanState.writePos,
                checkpointPos: effectiveCheckpointPos,
                pendingBytes: effectivePendingBytes,
                lastSequence: lastSequence,
                fsyncPolicy: options.walFsyncPolicy
            )

            let expectedEnd = footerSlice.footerOffset + Constants.footerSize
            var requiredEnd = expectedEnd
            for mutation in pendingMutations {
                guard case .putFrame(let put) = mutation.entry else { continue }
                guard put.payloadOffset <= UInt64.max - put.payloadLength else {
                    throw WaxError.invalidToc(reason: "pending frame \(put.frameId) payload range overflows")
                }
                let end = put.payloadOffset + put.payloadLength
                if end > requiredEnd { requiredEnd = end }
            }

            var fileSize = try file.size()
            guard requiredEnd <= fileSize else {
                throw WaxError.invalidToc(reason: "pending WAL references bytes beyond file size")
            }
            if repair, fileSize > requiredEnd {
                try file.truncate(to: requiredEnd)
                fileSize = requiredEnd
            }
            let dataEnd = max(fileSize, requiredEnd)

            return (
                file: file,
                lock: lock,
                header: header,
                selectedHeaderPageIndex: selected.pageIndex,
                toc: toc,
                wal: wal,
                pendingMutations: pendingMutations,
                dataEnd: dataEnd,
                generation: footerSlice.footer.generation,
                dirty: !pendingMutations.isEmpty
            )
        }

        return Wax(
            url: url,
            io: io,
            file: opened.file,
            lock: opened.lock,
            header: opened.header,
            selectedHeaderPageIndex: opened.selectedHeaderPageIndex,
            toc: opened.toc,
            wal: opened.wal,
            pendingMutations: opened.pendingMutations,
            stagedLexIndex: nil,
            stagedVecIndex: nil,
            stagedLexIndexStamp: nil,
            stagedVecIndexStamp: nil,
            stagedLexIndexStampCounter: 0,
            stagedVecIndexStampCounter: 0,
            dataEnd: opened.dataEnd,
            generation: opened.generation,
            dirty: opened.dirty
        )
    }

    // MARK: - Mutations

    public func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain
    ) async throws -> UInt64 {
        try await withOpLock {
            let committedCount = UInt64(toc.frames.count)
            let pendingPutCount = pendingMutations.reduce(0) { count, mutation in
                if case .putFrame = mutation.entry { return count + 1 }
                return count
            }
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
                    timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
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
            pendingMutations.append(PendingMutation(sequence: seq, entry: entry))
            dirty = true
            return frameId
        }
    }

    /// Batch put multiple frames in a single operation.
    /// This amortizes actor and I/O overhead across all frames.
    /// Returns frame IDs in the same order as the input contents.
    public func putBatch(
        _ contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        guard !contents.isEmpty else { return [] }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count (\(contents.count)) != options.count (\(options.count))")
        }

        return try await withOpLock {
            let committedCount = UInt64(toc.frames.count)
            let pendingPutCount = pendingMutations.reduce(0) { count, mutation in
                if case .putFrame = mutation.entry { return count + 1 }
                return count
            }
            let baseFrameId = committedCount + UInt64(pendingPutCount)
            let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

            // Pre-compute all frame data outside I/O
            struct PreparedFrame {
                let frameId: UInt64
                let storedBytes: Data
                let entry: WALEntry
                let walPayload: Data
            }

            var prepared: [PreparedFrame] = []
            prepared.reserveCapacity(contents.count)
            var totalPayloadSize = 0
            var totalWalSize = 0
            var currentOffset = dataEnd

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
                let payloadOffset = currentOffset

                let entry = WALEntry.putFrame(
                    PutFrame(
                        frameId: frameId,
                        timestampMs: timestampMs,
                        options: options[index],
                        payloadOffset: payloadOffset,
                        payloadLength: UInt64(storedBytes.count),
                        canonicalEncoding: canonicalEncoding,
                        canonicalLength: UInt64(content.count),
                        canonicalChecksum: canonicalChecksum,
                        storedChecksum: storedChecksum
                    )
                )
                let walPayload = try WALEntryCodec.encode(entry)

                prepared.append(PreparedFrame(
                    frameId: frameId,
                    storedBytes: storedBytes,
                    entry: entry,
                    walPayload: walPayload
                ))

                totalPayloadSize += storedBytes.count
                totalWalSize += walPayload.count
                currentOffset += UInt64(storedBytes.count)
            }

            // Check WAL capacity for entire batch
            try await ensureWalCapacityLocked(payloadSize: totalWalSize)

            // Capture values for Sendable closure
            let file = self.file
            let wal = self.wal
            let startOffset = dataEnd
            let storedBytesArray = prepared.map { $0.storedBytes }
            let walPayloadsArray = prepared.map { $0.walPayload }

            // Single mapped write for payloads
            let payloadLength = totalPayloadSize
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

            // Batch append WAL entries
            let sequences = try await io.run {
                try wal.appendBatch(payloads: walPayloadsArray)
            }

            // Update state
            dataEnd = currentOffset
            for (index, frame) in prepared.enumerated() {
                pendingMutations.append(PendingMutation(sequence: sequences[index], entry: frame.entry))
            }
            dirty = true

            return prepared.map { $0.frameId }
        }
    }

    /// Batch put embeddings for multiple frames in a single operation.
    public func putEmbeddingBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "putEmbeddingBatch: frameIds.count != vectors.count")
        }

        try await withOpLock {
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
            var totalWalSize = 0

            for (frameId, vector) in zip(frameIds, vectors) {
                let entry = WALEntry.putEmbedding(
                    PutEmbedding(frameId: frameId, dimension: dimension, vector: vector)
                )
                let payload = try WALEntryCodec.encode(entry)
                walPayloads.append(payload)
                entries.append(entry)
                totalWalSize += payload.count
            }

            try await ensureWalCapacityLocked(payloadSize: totalWalSize)

            // Capture for Sendable closure
            let wal = self.wal
            let walPayloadsArray = walPayloads  // Copy to let binding

            let sequences = try await io.run {
                try wal.appendBatch(payloads: walPayloadsArray)
            }

            // Update state
            for (index, entry) in entries.enumerated() {
                pendingMutations.append(PendingMutation(sequence: sequences[index], entry: entry))
            }
            dirty = true
        }
    }

    public func putEmbedding(frameId: UInt64, vector: [Float]) async throws {
        try await withOpLock {
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
            pendingMutations.append(PendingMutation(sequence: seq, entry: entry))
            dirty = true
        }
    }

    public func pendingEmbeddingMutations() async -> [PutEmbedding] {
        let snapshot = await pendingEmbeddingMutations(since: nil)
        return snapshot.embeddings
    }

    public func pendingEmbeddingMutations(since sequence: UInt64?) async -> PendingEmbeddingSnapshot {
        await withOpLock {
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

    public func delete(frameId: UInt64) async throws {
        try await withOpLock {
            let entry = WALEntry.deleteFrame(DeleteFrame(frameId: frameId))
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            pendingMutations.append(PendingMutation(sequence: seq, entry: entry))
            dirty = true
        }
    }

    public func supersede(supersededId: UInt64, supersedingId: UInt64) async throws {
        try await withOpLock {
            let entry = WALEntry.supersedeFrame(
                SupersedeFrame(supersededId: supersededId, supersedingId: supersedingId)
            )
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            pendingMutations.append(PendingMutation(sequence: seq, entry: entry))
            dirty = true
        }
    }

    public func pendingFrameMeta(frameId: UInt64) async -> FrameMeta? {
        await withOpLock {
            var last: PutFrame?
            for mutation in pendingMutations {
                guard case .putFrame(let put) = mutation.entry else { continue }
                guard put.frameId == frameId else { continue }
                last = put
            }
            guard let last else { return nil }
            return try? FrameMeta.fromPut(last)
        }
    }

    public func stageLexIndexForNextCommit(bytes: Data, docCount: UInt64, version: UInt32 = 1) async throws {
        try await withOpLock {
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
            stagedLexIndex = StagedLexIndex(bytes: bytes, docCount: docCount, version: version)
            stagedLexIndexStampCounter &+= 1
            stagedLexIndexStamp = stagedLexIndexStampCounter
            dirty = true
        }
    }

    public func stageVecIndexForNextCommit(
        bytes: Data,
        vectorCount: UInt64,
        dimension: UInt32,
        similarity: VecSimilarity
    ) async throws {
        try await withOpLock {
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

            let ordered = pendingMutations.sorted { $0.sequence < $1.sequence }
            for mutation in ordered {
                guard case .putEmbedding(let embedding) = mutation.entry else { continue }
                guard embedding.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "pending embedding dimension mismatch vs staged vec index: expected \(dimension), got \(embedding.dimension)"
                    )
                }
            }

            stagedVecIndex = StagedVecIndex(
                bytes: bytes,
                vectorCount: vectorCount,
                dimension: dimension,
                similarity: similarity
            )
            stagedVecIndexStampCounter &+= 1
            stagedVecIndexStamp = stagedVecIndexStampCounter
            dirty = true
        }
    }

    public func commit() async throws {
        try await withOpLock {
            try await commitLocked()
        }
    }

    private func commitLocked() async throws {
        guard dirty || stagedLexIndex != nil || stagedVecIndex != nil else { return }

        if stagedVecIndex == nil {
            let hasPendingEmbedding = pendingMutations.contains { mutation in
                if case .putEmbedding = mutation.entry { return true }
                return false
            }
            if hasPendingEmbedding {
                throw WaxError.io("vector index must be staged before committing embeddings")
            }
        }

        let appliedWalSeq = try applyPendingMutationsIntoTOC()

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

            let checksum = SHA256Checksum.digest(staged.bytes)
            toc.indexes.lex = LexIndexManifest(
                docCount: staged.docCount,
                bytesOffset: lexOffset,
                bytesLength: lexLength,
                checksum: checksum,
                version: staged.version
            )
            let segmentId = nextSegmentId()
            let entry = SegmentCatalogEntry(
                segmentId: segmentId,
                bytesOffset: lexOffset,
                bytesLength: lexLength,
                checksum: checksum,
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

            let checksum = SHA256Checksum.digest(staged.bytes)
            toc.indexes.vec = VecIndexManifest(
                vectorCount: staged.vectorCount,
                dimension: staged.dimension,
                bytesOffset: vecOffset,
                bytesLength: vecLength,
                checksum: checksum,
                similarity: staged.similarity
            )
            let segmentId = nextSegmentId()
            let entry = SegmentCatalogEntry(
                segmentId: segmentId,
                bytesOffset: vecOffset,
                bytesLength: vecLength,
                checksum: checksum,
                compression: .none,
                kind: .vec
            )
            toc.segmentCatalog.entries.append(entry)
        }

        let tocBytes = try toc.encode()
        let tocChecksum = tocBytes.suffix(32)
        toc.tocChecksum = Data(tocChecksum)

        let tocOffset = dataEnd
        let footerOffset = tocOffset + UInt64(tocBytes.count)
        let footer = MV2SFooter(
            tocLen: UInt64(tocBytes.count),
            tocHash: Data(tocChecksum),
            generation: generation &+ 1,
            walCommittedSeq: appliedWalSeq
        )
        try await io.run {
            try file.writeAll(tocBytes, at: tocOffset)
            try file.writeAll(try footer.encode(), at: footerOffset)
            try file.fsync()
        }

        header.footerOffset = footerOffset
        header.fileGeneration = footer.generation
        header.tocChecksum = Data(tocChecksum)
        header.walCommittedSeq = appliedWalSeq
        let wal = self.wal
        let walWritePos = try await io.run { wal.writePos }
        header.walCheckpointPos = walWritePos
        header.walWritePos = walWritePos
        header.headerPageGeneration &+= 1

        try await writeHeaderPage(header)
        try await io.run {
            try file.fsync()
            wal.recordCheckpoint()
        }

        pendingMutations.removeAll()
        stagedLexIndex = nil
        stagedVecIndex = nil
        stagedLexIndexStamp = nil
        stagedVecIndexStamp = nil
        surrogateIndex = nil
        dirty = false
        generation = footer.generation
        dataEnd = footerOffset + Constants.footerSize
    }

    // MARK: - Reads

    public func frameMetas() async -> [FrameMeta] {
        await withOpLock {
            toc.frames
        }
    }

    public func frameMetas(frameIds: [UInt64]) async -> [UInt64: FrameMeta] {
        await withOpLock {
            var metas: [UInt64: FrameMeta] = [:]
            metas.reserveCapacity(frameIds.count)
            let maxId = UInt64(toc.frames.count)
            for frameId in frameIds where frameId < maxId {
                metas[frameId] = toc.frames[Int(frameId)]
            }
            return metas
        }
    }

    public func frameMetasIncludingPending(frameIds: [UInt64]) async -> [UInt64: FrameMeta] {
        await withOpLock {
            var metas: [UInt64: FrameMeta] = [:]
            metas.reserveCapacity(frameIds.count)

            let maxId = UInt64(toc.frames.count)
            var missing: Set<UInt64> = []
            missing.reserveCapacity(frameIds.count)

            for frameId in frameIds {
                if frameId < maxId {
                    metas[frameId] = toc.frames[Int(frameId)]
                } else {
                    missing.insert(frameId)
                }
            }

            guard !missing.isEmpty else { return metas }

            var pendingById: [UInt64: PutFrame] = [:]
            pendingById.reserveCapacity(missing.count)
            for mutation in pendingMutations {
                guard case .putFrame(let put) = mutation.entry else { continue }
                guard missing.contains(put.frameId) else { continue }
                pendingById[put.frameId] = put
            }

            for (frameId, put) in pendingById {
                if let meta = try? FrameMeta.fromPut(put) {
                    metas[frameId] = meta
                }
            }

            return metas
        }
    }

    public func surrogateFrameId(sourceFrameId: UInt64) async -> UInt64? {
        await withOpLock {
            if surrogateIndex == nil {
                surrogateIndex = buildSurrogateIndexUnlocked()
            }
            return surrogateIndex?[sourceFrameId]
        }
    }

    public func frameMeta(frameId: UInt64) async throws -> FrameMeta {
        try await withOpLock {
            try frameMetaUnlocked(frameId: frameId)
        }
    }

    public func frameMetaIncludingPending(frameId: UInt64) async throws -> FrameMeta {
        do {
            return try await frameMeta(frameId: frameId)
        } catch let error as WaxError {
            if case .frameNotFound = error,
               let pending = await pendingFrameMeta(frameId: frameId) {
                return pending
            }
            throw error
        }
    }

    public func frameContent(frameId: UInt64) async throws -> Data {
        try await withOpLock {
            try await frameContentUnlocked(frameId: frameId)
        }
    }

    public func frameContentIncludingPending(frameId: UInt64) async throws -> Data {
        do {
            return try await frameContent(frameId: frameId)
        } catch let error as WaxError {
            if case .frameNotFound = error {
                guard let meta = await pendingFrameMeta(frameId: frameId) else { throw error }
                return try await withOpLock { try await frameContentFromMetaUnlocked(meta) }
            }
            throw error
        }
    }

    public func framePreview(frameId: UInt64, maxBytes: Int) async throws -> Data {
        try await withOpLock {
            let clampedMax = max(0, maxBytes)
            if clampedMax == 0 { return Data() }

            let frame = try frameMetaUnlocked(frameId: frameId)
            if frame.payloadLength == 0 { return Data() }

            if frame.canonicalEncoding == .plain {
                let available = min(frame.payloadLength, UInt64(clampedMax))
                guard available <= UInt64(Int.max) else {
                    throw WaxError.io("payload preview too large: \(available)")
                }
                let file = self.file
                return try await io.run {
                    try file.readExactly(length: Int(available), at: frame.payloadOffset)
                }
            }

            let canonical = try await frameContentUnlocked(frameId: frameId)
            return Data(canonical.prefix(clampedMax))
        }
    }

    public func framePreviews(frameIds: [UInt64], maxBytes: Int) async throws -> [UInt64: Data] {
        try await withOpLock {
            let clampedMax = max(0, maxBytes)
            guard clampedMax > 0 else { return [:] }

            var previews: [UInt64: Data] = [:]
            previews.reserveCapacity(frameIds.count)
            let maxId = UInt64(toc.frames.count)

            for frameId in frameIds where frameId < maxId {
                let frame = toc.frames[Int(frameId)]
                if frame.payloadLength == 0 {
                    previews[frameId] = Data()
                    continue
                }

                if frame.canonicalEncoding == .plain {
                    let available = min(frame.payloadLength, UInt64(clampedMax))
                    guard available <= UInt64(Int.max) else {
                        throw WaxError.io("payload preview too large: \(available)")
                    }
                    let file = self.file
                    let bytes = try await io.run {
                        try file.readExactly(length: Int(available), at: frame.payloadOffset)
                    }
                    previews[frameId] = bytes
                    continue
                }

                let canonical = try await frameContentFromMetaUnlocked(frame)
                previews[frameId] = Data(canonical.prefix(clampedMax))
            }

            return previews
        }
    }

    public func frameStoredContent(frameId: UInt64) async throws -> Data {
        try await withOpLock {
            try await frameStoredContentUnlocked(frameId: frameId)
        }
    }

    public func frameStoredPreview(frameId: UInt64, maxBytes: Int) async throws -> Data {
        try await withOpLock {
            let frame = try frameMetaUnlocked(frameId: frameId)
            if frame.payloadLength == 0 { return Data() }
            let clampedMax = max(0, maxBytes)
            if clampedMax == 0 { return Data() }
            let available = min(frame.payloadLength, UInt64(clampedMax))
            guard available <= UInt64(Int.max) else {
                throw WaxError.io("payload preview too large: \(available)")
            }
            let file = self.file
            return try await io.run {
                try file.readExactly(length: Int(available), at: frame.payloadOffset)
            }
        }
    }

    private func frameStoredContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        if frame.payloadLength == 0 { return Data() }
        guard frame.payloadLength <= UInt64(Int.max) else {
            throw WaxError.io("payload too large: \(frame.payloadLength)")
        }
        let file = self.file
        return try await io.run {
            try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
        }
    }

    private func frameContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        let stored = try await frameStoredContentUnlocked(frameId: frameId)
        guard frame.canonicalEncoding != .plain else { return stored }

        guard let canonicalLength = frame.canonicalLength else {
            throw WaxError.invalidToc(reason: "missing canonical_length for frame \(frameId)")
        }
        guard canonicalLength <= UInt64(Int.max) else {
            throw WaxError.io("canonical payload too large: \(canonicalLength)")
        }
        return try PayloadCompressor.decompress(
            stored,
            algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
            uncompressedLength: Int(canonicalLength)
        )
    }

    private func frameContentFromMetaUnlocked(_ frame: FrameMeta) async throws -> Data {
        if frame.payloadLength == 0 { return Data() }
        guard frame.payloadLength <= UInt64(Int.max) else {
            throw WaxError.io("payload too large: \(frame.payloadLength)")
        }
        let file = self.file
        let stored = try await io.run {
            try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
        }
        guard frame.canonicalEncoding != .plain else { return stored }

        guard let canonicalLength = frame.canonicalLength else {
            throw WaxError.invalidToc(reason: "missing canonical_length for frame \(frame.id)")
        }
        guard canonicalLength <= UInt64(Int.max) else {
            throw WaxError.io("canonical payload too large: \(canonicalLength)")
        }
        return try PayloadCompressor.decompress(
            stored,
            algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
            uncompressedLength: Int(canonicalLength)
        )
    }

    private func frameMetaUnlocked(frameId: UInt64) throws -> FrameMeta {
        guard frameId < UInt64(toc.frames.count) else {
            throw WaxError.frameNotFound(frameId: frameId)
        }
        return toc.frames[Int(frameId)]
    }

    public func readCommittedLexIndexBytes() async throws -> Data? {
        try await withOpLock {
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

    private func buildSurrogateIndexUnlocked() -> [UInt64: UInt64] {
        var index: [UInt64: UInt64] = [:]
        for frame in toc.frames {
            guard frame.status == .active else { continue }
            guard frame.supersededBy == nil else { continue }
            guard frame.kind == "surrogate" else { continue }
            guard let source = frame.metadata?.entries["source_frame_id"],
                  let sourceFrameId = UInt64(source) else {
                continue
            }
            guard sourceFrameId < UInt64(toc.frames.count) else { continue }
            let sourceMeta = toc.frames[Int(sourceFrameId)]
            guard sourceMeta.status == .active else { continue }
            guard sourceMeta.supersededBy == nil else { continue }
            guard sourceMeta.kind != "surrogate" else { continue }
            index[sourceFrameId] = frame.id
        }
        return index
    }

    public func committedLexIndexManifest() async -> LexIndexManifest? {
        await withOpLock {
            toc.indexes.lex
        }
    }

    public func readStagedLexIndexBytes() async -> Data? {
        await withOpLock {
            stagedLexIndex?.bytes
        }
    }

    public func stagedLexIndexStamp() async -> UInt64? {
        await withOpLock {
            stagedLexIndexStamp
        }
    }

    public func readCommittedVecIndexBytes() async throws -> Data? {
        try await withOpLock {
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

    public func readStagedVecIndexBytes() async -> (bytes: Data, dimension: UInt32, similarity: VecSimilarity)? {
        await withOpLock {
            guard let staged = stagedVecIndex else { return nil }
            return (bytes: staged.bytes, dimension: staged.dimension, similarity: staged.similarity)
        }
    }

    public func stagedVecIndexStamp() async -> UInt64? {
        await withOpLock {
            stagedVecIndexStamp
        }
    }

    public func committedVecIndexManifest() async -> VecIndexManifest? {
        await withOpLock {
            toc.indexes.vec
        }
    }

    // MARK: - Introspection

    public func stats() async -> WaxStats {
        await withOpLock {
            let pending = pendingMutations.reduce(0) { count, mutation in
                if case .putFrame = mutation.entry { return count + 1 }
                return count
            }
            return WaxStats(
                frameCount: UInt64(toc.frames.count),
                pendingFrames: UInt64(pending),
                generation: generation
            )
        }
    }

    public func timeline(_ query: TimelineQuery) async -> [FrameMeta] {
        await withOpLock {
            TimelineQuery.filter(frames: toc.frames, query: query)
        }
    }

    // MARK: - Verification hook

    /// Verify the file on disk.
    ///
    /// This is equivalent to `verify(deep: true)`. Use `verify(deep: false)` for a structural-only check.
    public func verify() async throws {
        try await verify(deep: true)
    }

    public func verify(deep: Bool) async throws {
        try await withOpLock {
            let file = self.file
            let pageA = try await io.run {
                try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
            }
            let pageB = try await io.run {
                try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
            }
            guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
                throw WaxError.invalidHeader(reason: "no valid header pages")
            }
            let header = selected.page
            let url = self.url

            let footerSlice: FooterSlice
            if let fastFooter = try await io.run({
                try FooterScanner.findFooter(at: header.footerOffset, in: url)
            }) {
                footerSlice = fastFooter
            } else {
                guard let scanned = try await io.run({
                    try FooterScanner.findLastValidFooter(in: url)
                }) else {
                    throw WaxError.invalidFooter(reason: "no valid footer found within max_footer_scan_bytes")
                }
                footerSlice = scanned
            }
            let toc = try MV2STOC.decode(from: footerSlice.tocBytes)

            let dataStart = header.walOffset + header.walSize
            try Self.validateTocRanges(toc, dataStart: dataStart, dataEnd: footerSlice.footerOffset)

            guard deep else { return }

            var frameIndex = 0
            for frame in toc.frames {
                guard frame.payloadLength > 0 else {
                    frameIndex += 1
                    continue
                }
                guard let storedChecksum = frame.storedChecksum else {
                    throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
                }
                let stored = try await sha256(
                    file: file,
                    offset: frame.payloadOffset,
                    length: frame.payloadLength
                )
                guard stored == storedChecksum else {
                    throw WaxError.checksumMismatch("frame \(frame.id) stored_checksum mismatch")
                }
                if frame.canonicalEncoding == .plain {
                    guard stored == frame.checksum else {
                        throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
                    }
                } else {
                    guard let canonicalLength = frame.canonicalLength else {
                        throw WaxError.invalidToc(reason: "frame \(frame.id) missing canonical_length")
                    }
                    guard canonicalLength <= UInt64(Int.max) else {
                        throw WaxError.io("canonical payload too large: \(canonicalLength)")
                    }
                    guard frame.payloadLength <= UInt64(Int.max) else {
                        throw WaxError.io("payload too large: \(frame.payloadLength)")
                    }
                    let storedBytes = try await io.run {
                        try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
                    }
                    let canonicalBytes = try PayloadCompressor.decompress(
                        storedBytes,
                        algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
                        uncompressedLength: Int(canonicalLength)
                    )
                    let canonicalChecksum = SHA256Checksum.digest(canonicalBytes)
                    guard canonicalChecksum == frame.checksum else {
                        throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
                    }
                }

                frameIndex += 1
                if frameIndex % 32 == 0 {
                    await Task.yield()
                }
            }

            var segmentIndex = 0
            for entry in toc.segmentCatalog.entries {
                guard entry.bytesLength > 0 else {
                    segmentIndex += 1
                    continue
                }
                let computed = try await sha256(
                    file: file,
                    offset: entry.bytesOffset,
                    length: entry.bytesLength
                )
                guard computed == entry.checksum else {
                    throw WaxError.checksumMismatch("segment \(entry.segmentId) checksum mismatch")
                }

                segmentIndex += 1
                if segmentIndex % 16 == 0 {
                    await Task.yield()
                }
            }
        }
    }

    public func close() async throws {
        try await withOpLock {
            let file = self.file
            let lock = self.lock
            try await io.run {
                try file.close()
                try lock.release()
            }
        }
    }

    // MARK: - Internal helpers

    private func writeHeaderPage(_ page: MV2SHeaderPage) async throws {
        let nextIndex = selectedHeaderPageIndex == 0 ? 1 : 0
        let offset = UInt64(nextIndex) * Constants.headerPageSize
        let file = self.file
        try await io.run {
            try file.writeAll(try page.encodeWithChecksum(), at: offset)
        }
        selectedHeaderPageIndex = nextIndex
    }

    private func applyPendingMutationsIntoTOC() throws -> UInt64 {
        let committedSeq = header.walCommittedSeq
        var maxSeq = committedSeq

        let stagedVecDimension = stagedVecIndex?.dimension
        let ordered = pendingMutations.sorted { $0.sequence < $1.sequence }
        var newFrames: [FrameMeta] = []

        func withFrame(_ frameId: UInt64, _ update: (inout FrameMeta) throws -> Void) throws {
            let committedCount = toc.frames.count
            let maxKnown = committedCount + newFrames.count
            guard frameId < UInt64(maxKnown) else {
                throw WaxError.invalidToc(reason: "mutation references unknown frameId \(frameId) (known < \(maxKnown))")
            }
            if frameId < UInt64(committedCount) {
                try update(&toc.frames[Int(frameId)])
            } else {
                let index = Int(frameId - UInt64(committedCount))
                try update(&newFrames[index])
            }
        }

        for mutation in ordered {
            guard mutation.sequence > committedSeq else {
                throw WaxError.invalidToc(reason: "mutation sequence \(mutation.sequence) not > committed \(committedSeq)")
            }
            if mutation.sequence > maxSeq { maxSeq = mutation.sequence }

            switch mutation.entry {
            case .putFrame(let put):
                let expectedId = UInt64(toc.frames.count + newFrames.count)
                guard put.frameId == expectedId else {
                    throw WaxError.invalidToc(reason: "non-dense frame id \(put.frameId), expected \(expectedId)")
                }
                let frame = try FrameMeta.fromPut(put)
                newFrames.append(frame)
            case .deleteFrame(let delete):
                try withFrame(delete.frameId) { frame in
                    frame.status = .deleted
                }
            case .supersedeFrame(let supersede):
                guard supersede.supersededId != supersede.supersedingId else {
                    throw WaxError.invalidToc(reason: "supersedeFrame requires distinct ids")
                }
                try withFrame(supersede.supersededId) { frame in
                    if let existing = frame.supersededBy, existing != supersede.supersedingId {
                        throw WaxError.invalidToc(
                            reason: "frame \(supersede.supersededId) already superseded by \(existing)"
                        )
                    }
                    frame.supersededBy = supersede.supersedingId
                }
                try withFrame(supersede.supersedingId) { frame in
                    if let existing = frame.supersedes, existing != supersede.supersededId {
                        throw WaxError.invalidToc(
                            reason: "frame \(supersede.supersedingId) already supersedes \(existing)"
                        )
                    }
                    frame.supersedes = supersede.supersededId
                }
            case .putEmbedding(let embedding):
                guard let stagedVecDimension else {
                    throw WaxError.invalidToc(reason: "putEmbedding pending without staged vec index")
                }
                guard embedding.dimension == stagedVecDimension else {
                    throw WaxError.invalidToc(
                        reason: "putEmbedding dimension \(embedding.dimension) != staged vec dimension \(stagedVecDimension)"
                    )
                }

                let maxKnownFrameIdExclusive = UInt64(toc.frames.count + newFrames.count)
                guard embedding.frameId < maxKnownFrameIdExclusive else {
                    throw WaxError.invalidToc(
                        reason: "putEmbedding references unknown frameId \(embedding.frameId) (known < \(maxKnownFrameIdExclusive))"
                    )
                }
                continue
            }
        }

        if !newFrames.isEmpty {
            var all = toc.frames
            all.append(contentsOf: newFrames)
            let dataStart = header.walOffset + header.walSize
            var candidate = toc
            candidate.frames = all
            try Self.validateTocRanges(candidate, dataStart: dataStart, dataEnd: dataEnd)
            toc.frames.append(contentsOf: newFrames)
        }

        return maxSeq
    }

    private struct DataRange {
        var start: UInt64
        var end: UInt64
        var label: String
    }

    private struct StagedLexIndex {
        var bytes: Data
        var docCount: UInt64
        var version: UInt32
    }

    private struct StagedVecIndex {
        var bytes: Data
        var vectorCount: UInt64
        var dimension: UInt32
        var similarity: VecSimilarity
    }

    private func nextSegmentId() -> UInt64 {
        if let maxId = toc.segmentCatalog.entries.map({ $0.segmentId }).max() {
            return maxId &+ 1
        }
        return 0
    }

    private static func validateTocRanges(_ toc: MV2STOC, dataStart: UInt64, dataEnd: UInt64) throws {
        let frameRanges = try collectFramePayloadRanges(toc.frames, dataStart: dataStart, dataEnd: dataEnd)
        let segmentRanges = try collectSegmentRanges(toc.segmentCatalog.entries, dataStart: dataStart, dataEnd: dataEnd)

        try validateNoOverlap(frameRanges + segmentRanges)
        try validateSegmentCatalogMatchesManifests(
            segmentCatalog: toc.segmentCatalog,
            indexes: toc.indexes,
            timeIndex: toc.timeIndex
        )
    }

    private static func collectFramePayloadRanges(
        _ frames: [FrameMeta],
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> [DataRange] {
        guard dataEnd >= dataStart else {
            throw WaxError.invalidToc(reason: "data region invalid: start \(dataStart), end \(dataEnd)")
        }

        var ranges: [DataRange] = []
        ranges.reserveCapacity(frames.count)

        for (index, frame) in frames.enumerated() {
            guard frame.id == UInt64(index) else {
                throw WaxError.invalidToc(reason: "frame id not dense: found \(frame.id), expected \(index)")
            }
            if frame.checksum.count != 32 {
                throw WaxError.invalidToc(reason: "frame \(frame.id) checksum must be 32 bytes")
            }
            if frame.canonicalEncoding != .plain && frame.canonicalLength == nil {
                throw WaxError.invalidToc(reason: "frame \(frame.id) missing canonical_length")
            }
            if frame.payloadLength > 0 && frame.storedChecksum == nil {
                throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
            }
            if frame.payloadLength == 0 { continue }
            guard frame.payloadOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload below data region")
            }
            guard frame.payloadOffset <= UInt64.max - frame.payloadLength else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload range overflows")
            }
            let end = frame.payloadOffset + frame.payloadLength
            guard end <= dataEnd else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload exceeds data end")
            }
            ranges.append(DataRange(start: frame.payloadOffset, end: end, label: "frame \(frame.id)"))
        }

        return ranges
    }

    private static func collectSegmentRanges(
        _ entries: [SegmentCatalogEntry],
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> [DataRange] {
        var ranges: [DataRange] = []
        ranges.reserveCapacity(entries.count)

        for entry in entries {
            if entry.bytesLength == 0 { continue }
            guard entry.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) below data region")
            }
            guard entry.bytesOffset <= UInt64.max - entry.bytesLength else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) range overflows")
            }
            let end = entry.bytesOffset + entry.bytesLength
            guard end <= dataEnd else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) exceeds data end")
            }
            ranges.append(DataRange(start: entry.bytesOffset, end: end, label: "segment \(entry.segmentId)"))
        }

        return ranges
    }

    private static func validateNoOverlap(_ ranges: [DataRange]) throws {
        let sorted = ranges.sorted { $0.start < $1.start }
        for idx in sorted.indices.dropFirst() {
            let prev = sorted[idx - 1]
            let next = sorted[idx]
            if prev.end > next.start {
                throw WaxError.invalidToc(reason: "data overlap between \(prev.label) and \(next.label)")
            }
        }
    }

    private static func validateSegmentCatalogMatchesManifests(
        segmentCatalog: SegmentCatalog,
        indexes: IndexManifests,
        timeIndex: TimeIndexManifest?
    ) throws {
        if let lex = indexes.lex {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .lex
                    && entry.bytesOffset == lex.bytesOffset
                    && entry.bytesLength == lex.bytesLength
                    && entry.checksum == lex.checksum
            }) else {
                throw WaxError.invalidToc(reason: "lex index manifest missing matching segment catalog entry")
            }
        }
        if let vec = indexes.vec {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .vec
                    && entry.bytesOffset == vec.bytesOffset
                    && entry.bytesLength == vec.bytesLength
                    && entry.checksum == vec.checksum
            }) else {
                throw WaxError.invalidToc(reason: "vec index manifest missing matching segment catalog entry")
            }
        }
        if let timeIndex {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .time
                    && entry.bytesOffset == timeIndex.bytesOffset
                    && entry.bytesLength == timeIndex.bytesLength
                    && entry.checksum == timeIndex.checksum
            }) else {
                throw WaxError.invalidToc(reason: "time index manifest missing matching segment catalog entry")
            }
        }
    }

    private func sha256(file: FDFile, offset: UInt64, length: UInt64) async throws -> Data {
        guard length > 0 else { return SHA256Checksum.digest(Data()) }
        var hasher = SHA256Checksum()
        let chunkSize: UInt64 = 1 * 1024 * 1024

        var cursor: UInt64 = 0
	        var chunkIndex = 0
	        while cursor < length {
	            let remaining = length - cursor
	            let thisChunkLen64 = min(chunkSize, remaining)
	            guard thisChunkLen64 <= UInt64(Int.max) else {
	                throw WaxError.io("verify chunk exceeds Int.max: \(thisChunkLen64)")
	            }
	            let readOffset = offset + cursor
	            let bytes = try await io.run {
	                try file.readExactly(length: Int(thisChunkLen64), at: readOffset)
	            }
	            bytes.withUnsafeBytes { raw in
	                hasher.update(raw)
	            }
            cursor += thisChunkLen64
            chunkIndex += 1
            if chunkIndex % 8 == 0 {
                await Task.yield()
            }
        }

        return hasher.finalize()
    }
}
