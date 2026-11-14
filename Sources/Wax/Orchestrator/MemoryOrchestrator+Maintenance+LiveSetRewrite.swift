import Foundation
import WaxCore

package extension MemoryOrchestrator {
    /// Rewrite the current committed store into a new `.wax` file.
    ///
    /// This is an offline-style deep compaction path that copies committed frame state and
    /// carries forward committed index bytes. The source file is left unchanged for rollback safety.
    func rewriteLiveSet(
        to destinationURL: URL,
        options: LiveSetRewriteOptions = .init()
    ) async throws -> LiveSetRewriteReport {
        let clock = ContinuousClock()
        let started = clock.now

        let sourceInputURL = (await wax.fileURL()).standardizedFileURL
        let destinationInputURL = destinationURL.standardizedFileURL
        guard !Self.isSymbolicLink(at: sourceInputURL),
              !Self.isSymbolicLink(at: destinationInputURL)
        else {
            throw WaxError.io("rewriteLiveSet refuses symlink source or destination")
        }

        let sourceURL = sourceInputURL.resolvingSymlinksInPath().standardizedFileURL
        let destinationURL = destinationInputURL.resolvingSymlinksInPath().standardizedFileURL
        guard sourceURL != destinationURL else {
            throw WaxError.io("rewriteLiveSet destination must differ from source")
        }
        guard !Self.sameFileIdentity(sourceURL, destinationURL) else {
            throw WaxError.io("rewriteLiveSet destination aliases source")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular
            else {
                throw WaxError.io("rewriteLiveSet destination must be a regular file")
            }
            guard options.overwriteDestination else {
                throw WaxError.io("rewriteLiveSet destination already exists")
            }
            guard try StoreLockProbe.tryExclusiveAccess(at: destinationURL) else {
                throw WaxError.lockUnavailable(
                    "rewriteLiveSet destination is locked by another process: \(destinationURL.path)"
                )
            }
        }

        try await session.commit()

        // Build beside the requested destination. Creating directly at an
        // overwrite path would truncate the previous output before the new
        // store has passed verification, and it leaves a promotion race if a
        // destination is created after preflight.
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stagingURL = Self.rewriteStagingURL(for: destinationURL)
        guard !fileManager.fileExists(atPath: stagingURL.path) else {
            throw WaxError.io("rewriteLiveSet staging path already exists")
        }
        defer { try? fileManager.removeItem(at: stagingURL) }

        let sourceSizes = try Self.fileSizes(at: sourceURL)
        let sourceFrames = await wax.frameMetas()
        let sourceWalSize = (await wax.walStats()).walSize
        let payloadLiveness = await wax.committedPayloadLivenessBytes()
        let livePayloadBytes = payloadLiveness.totalPayloadBytes &- payloadLiveness.deadPayloadBytes
        let payloadBytes = options.dropNonLivePayloads
            ? livePayloadBytes
            : payloadLiveness.totalPayloadBytes
        let frameWalBytes = try Self.rewriteFrameWalBytes(
            frames: sourceFrames,
            dropNonLivePayloads: options.dropNonLivePayloads
        )
        let destinationWalSize = Self.walSizeForLiveSetRewrite(
            sourceWalSize: sourceWalSize,
            payloadBytes: payloadBytes,
            largestFrameWalBytes: frameWalBytes.largest,
            totalFrameWalBytes: frameWalBytes.total
        )
        guard frameWalBytes.largest <= destinationWalSize else {
            throw WaxError.capacityExceeded(
                limit: destinationWalSize,
                requested: frameWalBytes.largest
            )
        }
        let committedLexManifest = await wax.committedLexIndexManifest()
        let committedLexBytes = try await wax.readCommittedLexIndexBytes()
        let committedVectors = try await wax.readCommittedVectors()
        let sourceMemoryBinding = await wax.memoryBinding()

        let rewritten = try await Wax.create(at: stagingURL, walSize: destinationWalSize)
        if let sourceMemoryBinding {
            try await rewritten.setMemoryBindingIfMissing(sourceMemoryBinding)
        }
        var droppedPayloadFrames = 0
        let shouldBatchFrameWrites = frameWalBytes.total > destinationWalSize
        let batchCommitThreshold = max(
            UInt64(Constants.walRecordHeaderSize),
            destinationWalSize / 2
        )
        do {
            for (index, frame) in sourceFrames.enumerated() {
                if shouldBatchFrameWrites {
                    let pendingBytes = (await rewritten.walStats()).pendingBytes
                    let nextPayloadSize = frameWalBytes.payloadSizes[index]
                    if pendingBytes > 0,
                       !(await rewritten.canAppendWALPayload(payloadSize: nextPayloadSize)) {
                        // Preflight the complete WAL record (including wrap
                        // padding) before appending it. A post-write
                        // threshold check is too late for a large metadata
                        // record that follows a partially full batch.
                        try await rewritten.commit()
                    }
                }

                let isLiveFrame = frame.status == .active && frame.supersededBy == nil
                let content: Data
                let compression: CanonicalEncoding
                if options.dropNonLivePayloads && !isLiveFrame {
                    content = Data()
                    compression = .plain
                    droppedPayloadFrames += 1
                } else {
                    content = try await wax.frameContent(frameId: frame.id)
                    compression = frame.canonicalEncoding
                }
                let subset = Self.subsetForRewrite(from: frame)
                let rewrittenId = try await rewritten.put(
                    content,
                    options: subset,
                    compression: compression,
                    timestampMs: frame.timestamp
                )
                guard rewrittenId == frame.id else {
                    throw WaxError.invalidToc(
                        reason: "rewriteLiveSet frame id mismatch: expected \(frame.id), got \(rewrittenId)"
                    )
                }

                // Metadata-rich frames can make the aggregate rewrite larger
                // than one WAL ring. Commit bounded batches before staging
                // index manifests; the final commit then only publishes the
                // index manifests and any small tail batch.
                if shouldBatchFrameWrites,
                   (await rewritten.walStats()).pendingBytes >= batchCommitThreshold {
                    try await rewritten.commit()
                }
            }

            if let manifest = committedLexManifest,
               let bytes = committedLexBytes {
                try await rewritten.stageLexIndexForNextCommit(
                    bytes: bytes,
                    docCount: manifest.docCount,
                    version: manifest.version
                )
            }

            if let committedVectors {
                // One run holding the merged vectors: the rewrite drops the source's runs history.
                try await rewritten.stageVectorImportForNextCommit(committedVectors)
            }

            try await rewritten.commit()
            try await rewritten.verify(deep: options.verifyDeep)
            try await rewritten.close()
        } catch {
            try? await rewritten.close()
            throw error
        }

        var promotion: RewritePromotion?
        do {
            promotion = try Self.promoteRewriteOutput(
                from: stagingURL,
                to: destinationURL,
                source: sourceURL,
                overwrite: options.overwriteDestination
            )
            try await Self.verifyRewriteOutput(at: destinationURL, deep: options.verifyDeep)
            if let promotion {
                try Self.finalizeRewritePromotion(promotion)
            }
        } catch {
            if let promotion {
                try? Self.rollbackRewritePromotion(promotion)
            }
            throw error
        }

        let destinationSizes = try Self.fileSizes(at: destinationURL)
        let frameCount = sourceFrames.count
        let activeFrameCount = sourceFrames.filter { $0.status == .active && $0.supersededBy == nil }.count
        let deletedFrameCount = sourceFrames.filter { $0.status == .deleted }.count
        let supersededFrameCount = sourceFrames.filter { $0.supersededBy != nil }.count
        let durationMs = Self.durationMs(clock.now - started)

        return LiveSetRewriteReport(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            frameCount: frameCount,
            activeFrameCount: activeFrameCount,
            droppedPayloadFrames: droppedPayloadFrames,
            deletedFrameCount: deletedFrameCount,
            supersededFrameCount: supersededFrameCount,
            copiedLexIndex: committedLexManifest != nil && committedLexBytes != nil,
            copiedVecIndex: committedVectors != nil,
            logicalBytesBefore: sourceSizes.logical,
            logicalBytesAfter: destinationSizes.logical,
            allocatedBytesBefore: sourceSizes.allocated,
            allocatedBytesAfter: destinationSizes.allocated,
            durationMs: durationMs
        )
    }

    private static func subsetForRewrite(from frame: FrameMeta) -> FrameMetaSubset {
        FrameMetaSubset(
            uri: frame.uri,
            title: frame.title,
            kind: frame.kind,
            track: frame.track,
            tags: frame.tags,
            labels: frame.labels,
            contentDates: frame.contentDates,
            role: frame.role,
            parentId: frame.parentId,
            chunkIndex: frame.chunkIndex,
            chunkCount: frame.chunkCount,
            chunkManifest: frame.chunkManifest,
            status: frame.status,
            supersedes: frame.supersedes,
            supersededBy: frame.supersededBy,
            searchText: frame.searchText,
            metadata: frame.metadata
        )
    }

    /// Destination WAL is payload- and frame-metadata-derived: never clone a
    /// large empty source ring, never go below `Constants.sessionWalSize` when
    /// the source ring allows it, and never exceed the source ring.
    static func walSizeForLiveSetRewrite(
        sourceWalSize: UInt64,
        payloadBytes: UInt64,
        largestFrameWalBytes: UInt64 = 0,
        totalFrameWalBytes: UInt64 = 0
    ) -> UInt64 {
        let floor = Constants.sessionWalSize
        let cap = sourceWalSize
        let boundedFloor = min(floor, cap)
        let needed = max(
            boundedFloor,
            max(payloadBytes, max(largestFrameWalBytes, totalFrameWalBytes))
        )
        return min(cap, needed)
    }

    /// A put-frame WAL entry contains the complete frame metadata, not only
    /// the payload bytes stored outside the ring. Estimate both the largest
    /// entry (the hard per-entry capacity requirement) and aggregate entries
    /// (the useful one-commit capacity requirement) before creating the
    /// destination. The aggregate includes one conservative wrap/header unit
    /// per frame; if it exceeds the source ring, Wax commits in batches.
    private static func rewriteFrameWalBytes(
        frames: [FrameMeta],
        dropNonLivePayloads: Bool
    ) throws -> (largest: UInt64, total: UInt64, payloadSizes: [Int]) {
        let zeroChecksum = Data(repeating: 0, count: 32)
        var largest: UInt64 = 0
        var total: UInt64 = 0
        var payloadSizes: [Int] = []
        payloadSizes.reserveCapacity(frames.count)

        for frame in frames {
            let isLiveFrame = frame.status == .active && frame.supersededBy == nil
            let payloadLength = dropNonLivePayloads && !isLiveFrame ? 0 : frame.payloadLength
            let canonicalEncoding = dropNonLivePayloads && !isLiveFrame
                ? CanonicalEncoding.plain
                : frame.canonicalEncoding
            let canonicalLength = dropNonLivePayloads && !isLiveFrame
                ? 0
                : (frame.canonicalLength ?? frame.payloadLength)
            let put = PutFrame(
                frameId: frame.id,
                timestampMs: frame.timestamp,
                options: subsetForRewrite(from: frame),
                payloadOffset: 0,
                payloadLength: payloadLength,
                canonicalEncoding: canonicalEncoding,
                canonicalLength: canonicalLength,
                canonicalChecksum: zeroChecksum,
                storedChecksum: zeroChecksum
            )
            let recordBytes = try WALSizing.putFrameRecordBytes(put)
            let walHeaderSize = UInt64(Constants.walRecordHeaderSize)
            guard recordBytes >= walHeaderSize,
                  recordBytes - walHeaderSize <= UInt64(Int.max) else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Int.max),
                    requested: recordBytes
                )
            }
            payloadSizes.append(Int(recordBytes - walHeaderSize))
            largest = max(largest, recordBytes)
            let (nextTotal, overflowed) = total.addingReportingOverflow(recordBytes)
            total = overflowed ? UInt64.max : nextTotal
        }

        let perFrameOverhead = UInt64(frames.count)
            .multipliedReportingOverflow(by: Constants.walRecordHeaderSize)
        let (conservativeTotal, overflowed) = total.addingReportingOverflow(perFrameOverhead.partialValue)
        return (
            largest: largest,
            total: overflowed || perFrameOverhead.overflow ? UInt64.max : conservativeTotal,
            payloadSizes: payloadSizes
        )
    }

    private struct RewritePromotion {
        let destinationURL: URL
        let backupURL: URL?
        let publishedIdentity: FileIdentity?
        let backupIdentity: FileIdentity?
    }

    private static func rewriteStagingURL(for destinationURL: URL) -> URL {
        let baseName = destinationURL.deletingPathExtension().lastPathComponent
        let extensionName = destinationURL.pathExtension.isEmpty ? "wax" : destinationURL.pathExtension
        return destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(baseName)-rewrite-\(UUID().uuidString)")
            .appendingPathExtension(extensionName)
    }

    private static func promoteRewriteOutput(
        from stagingURL: URL,
        to destinationURL: URL,
        source sourceURL: URL,
        overwrite: Bool
    ) throws -> RewritePromotion {
        let fileManager = FileManager.default
        guard !isSymbolicLink(at: stagingURL), !isSymbolicLink(at: destinationURL) else {
            throw WaxError.io("rewriteLiveSet refuses symlink staging or destination")
        }
        guard let stagingAttributes = try? fileManager.attributesOfItem(atPath: stagingURL.path),
              let stagingType = stagingAttributes[.type] as? FileAttributeType,
              stagingType == .typeRegular
        else {
            throw WaxError.io("rewriteLiveSet staging output must be a regular file")
        }
        guard fileManager.fileExists(atPath: stagingURL.path) else {
            throw WaxError.io("rewriteLiveSet staging output is missing")
        }
        guard !sameFileIdentity(sourceURL, destinationURL) else {
            throw WaxError.io("rewriteLiveSet destination aliases source")
        }
        guard isRegularFile(at: stagingURL), !isSymbolicLink(at: stagingURL) else {
            throw WaxError.io("rewriteLiveSet staging output changed before promotion")
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path),
                  let type = attributes[.type] as? FileAttributeType,
                  type == .typeRegular
            else {
                throw WaxError.io("rewriteLiveSet destination must be a regular file")
            }
            guard overwrite else {
                throw WaxError.io("rewriteLiveSet destination appeared during rewrite")
            }
            guard try StoreLockProbe.tryExclusiveAccess(at: destinationURL) else {
                throw WaxError.lockUnavailable(
                    "rewriteLiveSet destination is locked by another process: \(destinationURL.path)"
                )
            }
            guard isRegularFile(at: destinationURL),
                  !isSymbolicLink(at: destinationURL) else {
                throw WaxError.io("rewriteLiveSet destination changed before promotion")
            }
            let backupName = ".\(destinationURL.lastPathComponent)-previous-\(UUID().uuidString)"
            _ = try AtomicFileReplacement.replaceItem(
                at: destinationURL,
                withItemAt: stagingURL,
                backupItemName: backupName,
                // Retain the prior live set until finalization has verified
                // the published inode; rollback relies on this copy.
                options: [.withoutDeletingBackupItem]
            )
            // Persist the rename itself; fsync of the store file does not cover its name.
            // Best effort: the rename already happened, so throwing here would send the
            // caller down the not-promoted path with the files already swapped.
            try? FDFile.fsyncParentDirectory(of: destinationURL)
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(backupName)
            return RewritePromotion(
                destinationURL: destinationURL,
                backupURL: backupURL,
                publishedIdentity: fileIdentity(at: destinationURL),
                backupIdentity: fileIdentity(at: backupURL)
            )
        }

        try fileManager.moveItem(at: stagingURL, to: destinationURL)
        try? FDFile.fsyncParentDirectory(of: destinationURL) // best effort, see above
        return RewritePromotion(
            destinationURL: destinationURL,
            backupURL: nil,
            publishedIdentity: fileIdentity(at: destinationURL),
            backupIdentity: nil
        )
    }

    private static func rollbackRewritePromotion(_ promotion: RewritePromotion) throws {
        // The advisory lock probe used before replace cannot prevent an
        // unrelated process from swapping this pathname afterward. Never
        // recursively remove a changed directory or symlink; leave it and
        // surface the rollback failure for operator recovery instead.
        let fileManager = FileManager.default
        if let backupURL = promotion.backupURL {
            // Validate and pin the rollback source before touching the
            // published destination. If it disappeared or changed, retain the
            // published output for operator recovery.
            guard fileManager.fileExists(atPath: backupURL.path),
                  !isSymbolicLink(at: backupURL),
                  isRegularFile(at: backupURL),
                  let expected = promotion.backupIdentity,
                  fileIdentity(at: backupURL) == expected else {
                throw WaxError.io(
                    "rewriteLiveSet rollback retained published output because the backup changed or disappeared"
                )
            }

            if fileManager.fileExists(atPath: promotion.destinationURL.path) {
                guard !isSymbolicLink(at: promotion.destinationURL),
                      let expected = promotion.publishedIdentity,
                      fileIdentity(at: promotion.destinationURL) == expected else {
                    throw WaxError.io(
                        "rewriteLiveSet rollback refused to remove a destination path changed after promotion"
                    )
                }
            }

            let quarantine = promotion.destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(promotion.destinationURL.lastPathComponent)-rollback-\(UUID().uuidString)")
            guard !fileManager.fileExists(atPath: quarantine.path) else {
                throw WaxError.io("rewriteLiveSet rollback quarantine path already exists")
            }
            do {
                if fileManager.fileExists(atPath: promotion.destinationURL.path) {
                    try fileManager.moveItem(at: promotion.destinationURL, to: quarantine)
                }
                guard fileManager.fileExists(atPath: backupURL.path),
                      !isSymbolicLink(at: backupURL),
                      isRegularFile(at: backupURL),
                      fileIdentity(at: backupURL) == expected else {
                    throw WaxError.io(
                        "rewriteLiveSet rollback retained published output because the backup changed during restore"
                    )
                }
                try fileManager.moveItem(at: backupURL, to: promotion.destinationURL)
                try? fileManager.removeItem(at: quarantine)
            } catch {
                // Restore the published inode when the backup race is
                // detected after quarantine. Never overwrite a path another
                // process recreated while rollback was in flight.
                if fileManager.fileExists(atPath: quarantine.path),
                   !fileManager.fileExists(atPath: promotion.destinationURL.path) {
                    try? fileManager.moveItem(at: quarantine, to: promotion.destinationURL)
                }
                throw error
            }
        } else if fileManager.fileExists(atPath: promotion.destinationURL.path) {
            guard !isSymbolicLink(at: promotion.destinationURL),
                  let expected = promotion.publishedIdentity,
                  fileIdentity(at: promotion.destinationURL) == expected else {
                throw WaxError.io(
                    "rewriteLiveSet rollback refused to remove a destination path changed after promotion"
                )
            }
            try fileManager.removeItem(at: promotion.destinationURL)
        }
    }

    private static func finalizeRewritePromotion(_ promotion: RewritePromotion) throws {
        guard let backupURL = promotion.backupURL else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw WaxError.io(
                "rewriteLiveSet promotion backup disappeared; published output was retained"
            )
        }

        // Keep the rollback copy until the published destination is still the
        // inode that passed verification. If another writer replaced the
        // pathname after promotion, fail closed and retain the backup for
        // operator recovery.
        guard isRegularFile(at: promotion.destinationURL),
              let expected = promotion.publishedIdentity,
              fileIdentity(at: promotion.destinationURL) == expected else {
            throw WaxError.io(
                "rewriteLiveSet promotion destination changed before backup cleanup"
            )
        }
        guard isRegularFile(at: backupURL),
              let expected = promotion.backupIdentity,
              fileIdentity(at: backupURL) == expected else {
            throw WaxError.io(
                "rewriteLiveSet promotion backup changed before cleanup; published output was retained"
            )
        }
        try fileManager.removeItem(at: backupURL)
    }

    private static func verifyRewriteOutput(at url: URL, deep: Bool) async throws {
        let store = try await Wax.open(at: url)
        do {
            try await store.verify(deep: deep)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
    }

    private static func fileSizes(at url: URL) throws -> (logical: UInt64, allocated: UInt64) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        let logical = UInt64(max(0, values.fileSize ?? 0))
        let allocatedValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        let allocated = UInt64(max(0, allocatedValue))
        return (logical: logical, allocated: allocated)
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func isRegularFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              !isSymbolicLink(at: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else {
            return false
        }
        return type == .typeRegular
    }

    private struct FileIdentity: Equatable {
        let device: UInt64?
        let inode: UInt64?
    }

    private static func fileIdentity(at url: URL) -> FileIdentity? {
        guard isRegularFile(at: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else {
            return nil
        }
        return FileIdentity(
            device: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    private static func sameFileIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let right = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let leftInode = (left[.systemFileNumber] as? NSNumber)?.uint64Value,
              let rightInode = (right[.systemFileNumber] as? NSNumber)?.uint64Value,
              leftInode == rightInode
        else {
            return false
        }
        guard let leftDevice = (left[.systemNumber] as? NSNumber)?.uint64Value,
              let rightDevice = (right[.systemNumber] as? NSNumber)?.uint64Value
        else {
            return true
        }
        return leftDevice == rightDevice
    }

    static func promoteValidatedLiveSetCandidateIfNeeded(
        _ report: ScheduledLiveSetMaintenanceReport,
        sourceURL: URL
    ) throws {
        guard report.outcome == .rewriteSucceeded else { return }
        guard let candidateURL = report.candidateURL?.standardizedFileURL else { return }

        let sourceURL = sourceURL.standardizedFileURL
        guard candidateURL != sourceURL else { return }
        guard FileManager.default.fileExists(atPath: candidateURL.path) else { return }
        guard !isSymbolicLink(at: sourceURL), !isSymbolicLink(at: candidateURL) else {
            throw WaxError.io("live-set promotion refuses symlink source or candidate")
        }
        let fileManager = FileManager.default
        guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: sourceURL.path),
              let sourceType = sourceAttributes[.type] as? FileAttributeType,
              sourceType == .typeRegular,
              let candidateAttributes = try? fileManager.attributesOfItem(atPath: candidateURL.path),
              let candidateType = candidateAttributes[.type] as? FileAttributeType,
              candidateType == .typeRegular
        else {
            throw WaxError.io("live-set promotion requires regular source and candidate files")
        }
        guard try StoreLockProbe.tryExclusiveAccess(at: sourceURL) else {
            throw WaxError.lockUnavailable(
                "live-set promotion source is locked by another process: \(sourceURL.path)"
            )
        }
        guard try StoreLockProbe.tryExclusiveAccess(at: candidateURL) else {
            throw WaxError.lockUnavailable(
                "live-set promotion candidate is locked by another process: \(candidateURL.path)"
            )
        }

        let backupName = "\(sourceURL.lastPathComponent).pre-liveset-\(UUID().uuidString)"
        _ = try AtomicFileReplacement.replaceItem(
            at: sourceURL,
            withItemAt: candidateURL,
            backupItemName: backupName,
            // Keep the prior live store until finalization verifies the
            // published candidate; rollback relies on this copy.
            options: [.withoutDeletingBackupItem]
        )

        let backupURL = sourceURL.deletingLastPathComponent().appendingPathComponent(backupName)
        let promotion = RewritePromotion(
            destinationURL: sourceURL,
            backupURL: backupURL,
            publishedIdentity: fileIdentity(at: sourceURL),
            backupIdentity: fileIdentity(at: backupURL)
        )
        do {
            try Self.finalizeRewritePromotion(promotion)
        } catch {
            try? Self.rollbackRewritePromotion(promotion)
            throw error
        }

        if let footerSlice = try FooterScanner.findLastValidFooter(in: sourceURL) {
            let repairedEnd = footerSlice.footerOffset + Constants.footerSize
            let file = try FDFile.open(at: sourceURL)
            defer { try? file.close() }
            try file.truncate(to: repairedEnd)
            try file.fsync()
        }
    }

    private static func durationMs(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
