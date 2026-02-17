import Foundation
import WaxCore

public protocol MaintenableMemory: Sendable {
    func optimizeSurrogates(
        options: MaintenanceOptions,
        generator: some SurrogateGenerator
    ) async throws -> MaintenanceReport

    func compactIndexes(options: MaintenanceOptions) async throws -> MaintenanceReport
    func rewriteLiveSet(to destinationURL: URL, options: LiveSetRewriteOptions) async throws -> LiveSetRewriteReport
}

extension MemoryOrchestrator: MaintenableMemory {}

private enum SurrogateMetadataKeys {
    static let sourceFrameId = "source_frame_id"
    static let algorithm = "surrogate_algo"
    static let version = "surrogate_version"
    static let sourceContentHash = "source_content_hash"
    static let maxTokens = "surrogate_max_tokens"
    static let format = "surrogate_format"
}

private enum SurrogateDefaults {
    static let kind = "surrogate"
    static let version: UInt32 = 1
    static let hierarchicalFormat = "hierarchical_v1"
}

public extension MemoryOrchestrator {
    func optimizeSurrogates(
        options: MaintenanceOptions = .init(),
        generator: (any SurrogateGenerator)? = nil
    ) async throws -> MaintenanceReport {
        let effectiveGenerator = generator ?? ExtractiveSurrogateGenerator()
        return try await optimizeSurrogates(options: options, generator: effectiveGenerator)
    }

    func optimizeSurrogates(
        options: MaintenanceOptions,
        generator: some SurrogateGenerator
    ) async throws -> MaintenanceReport {
        let start = ContinuousClock.now

        // Ensure newly ingested, unflushed frames are visible to maintenance scans.
        // Avoid staging/committing when there are no pending puts to prevent unnecessary index rewrites.
        let pendingFrames = (await wax.stats()).pendingFrames
        if pendingFrames > 0 {
            try await session.commit()
        }

        let clampedMaxFrames: Int? = options.maxFrames.map { max(0, $0) }
        let deadline: ContinuousClock.Instant? = options.maxWallTimeMs.map { ms in
            start.advanced(by: .milliseconds(max(0, ms)))
        }

        let surrogateMaxTokens = max(0, options.surrogateMaxTokens)

        let frames = await wax.frameMetas()
        var report = MaintenanceReport()
        report.scannedFrames = frames.count

        for frame in frames {
            if let deadline, ContinuousClock.now >= deadline {
                report.didTimeout = true
                break
            }

            if let maxFrames = clampedMaxFrames, report.eligibleFrames >= maxFrames {
                break
            }

            guard frame.status == .active else { continue }
            guard frame.supersededBy == nil else { continue }
            guard frame.role == .chunk else { continue }
            guard frame.kind != SurrogateDefaults.kind else { continue }
            guard let sourceText = frame.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sourceText.isEmpty else {
                continue
            }

            report.eligibleFrames += 1

            let sourceHash = SHA256Checksum.digest(Data(sourceText.utf8)).hexString
            let existingId = await wax.surrogateFrameId(sourceFrameId: frame.id)
            let isUpToDate: Bool = if let existingId {
                (try? await isUpToDateSurrogate(
                    surrogateFrameId: existingId,
                    sourceFrame: frame,
                    sourceHash: sourceHash,
                    algorithmID: generator.algorithmID,
                    surrogateMaxTokens: surrogateMaxTokens
                )) ?? false
            } else {
                false
            }

            if isUpToDate, !options.overwriteExisting {
                report.skippedUpToDate += 1
                continue
            }

            let surrogatePayload: Data
            var isHierarchical = false
            
            // Use hierarchical generation if enabled and generator supports it
            if options.enableHierarchicalSurrogates,
               let hierarchicalGen = generator as? HierarchicalSurrogateGenerator {
                let tiers = try await hierarchicalGen.generateTiers(
                    sourceText: sourceText,
                    config: options.tierConfig
                )
                guard !tiers.full.isEmpty else { continue }
                surrogatePayload = try JSONEncoder().encode(tiers)
                isHierarchical = true
            } else {
                // Fallback: single-tier legacy format
                let surrogateText = try await generator.generateSurrogate(sourceText: sourceText, maxTokens: surrogateMaxTokens)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !surrogateText.isEmpty else { continue }
                surrogatePayload = Data(surrogateText.utf8)
            }

            var meta = Metadata()
            meta.entries[SurrogateMetadataKeys.sourceFrameId] = String(frame.id)
            meta.entries[SurrogateMetadataKeys.algorithm] = generator.algorithmID
            meta.entries[SurrogateMetadataKeys.version] = String(SurrogateDefaults.version)
            meta.entries[SurrogateMetadataKeys.sourceContentHash] = sourceHash
            meta.entries[SurrogateMetadataKeys.maxTokens] = String(surrogateMaxTokens)
            if isHierarchical {
                meta.entries[SurrogateMetadataKeys.format] = SurrogateDefaults.hierarchicalFormat
            }

            var subset = FrameMetaSubset()
            subset.kind = SurrogateDefaults.kind
            subset.role = .system
            subset.metadata = meta

            let surrogateFrameId = try await wax.put(surrogatePayload, options: subset)
            report.generatedSurrogates += 1

            if let existingId {
                try await wax.supersede(supersededId: existingId, supersedingId: surrogateFrameId)
                report.supersededSurrogates += 1
            }

            if report.generatedSurrogates.isMultiple(of: 64) {
                try await commitSurrogateBatchIfNeeded()
            }
        }

        try await commitSurrogateBatchIfNeeded()

        let _ = start.duration(to: ContinuousClock.now)
        return report
    }

    func compactIndexes(options: MaintenanceOptions = .init()) async throws -> MaintenanceReport {
        let start = ContinuousClock.now

        var report = MaintenanceReport()
        report.scannedFrames = Int((await wax.stats()).frameCount)

        try await session.commit(compact: true)

        let _ = start.duration(to: ContinuousClock.now)
        return report
    }

    /// Rewrite the current committed store into a new `.mv2s` file.
    ///
    /// This is an offline-style deep compaction path that copies committed frame state and
    /// carries forward committed index bytes. The source file is left unchanged for rollback safety.
    func rewriteLiveSet(
        to destinationURL: URL,
        options: LiveSetRewriteOptions = .init()
    ) async throws -> LiveSetRewriteReport {
        let clock = ContinuousClock()
        let started = clock.now

        try await session.commit()

        let sourceURL = (await wax.fileURL()).standardizedFileURL
        let destinationURL = destinationURL.standardizedFileURL
        guard sourceURL != destinationURL else {
            throw WaxError.io("rewriteLiveSet destination must differ from source")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard options.overwriteDestination else {
                throw WaxError.io("rewriteLiveSet destination already exists")
            }
            try fileManager.removeItem(at: destinationURL)
        }

        let sourceSizes = try Self.fileSizes(at: sourceURL)
        let sourceFrames = await wax.frameMetas()
        let sourceWalSize = (await wax.walStats()).walSize
        let committedLexManifest = await wax.committedLexIndexManifest()
        let committedVecManifest = await wax.committedVecIndexManifest()
        let committedLexBytes = try await wax.readCommittedLexIndexBytes()
        let committedVecBytes = try await wax.readCommittedVecIndexBytes()

        let rewritten = try await Wax.create(at: destinationURL, walSize: sourceWalSize)
        var droppedPayloadFrames = 0
        do {
            for frame in sourceFrames {
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
            }

            if let manifest = committedLexManifest,
               let bytes = committedLexBytes {
                try await rewritten.stageLexIndexForNextCommit(
                    bytes: bytes,
                    docCount: manifest.docCount,
                    version: manifest.version
                )
            }

            if let manifest = committedVecManifest,
               let bytes = committedVecBytes {
                try await rewritten.stageVecIndexForNextCommit(
                    bytes: bytes,
                    vectorCount: manifest.vectorCount,
                    dimension: manifest.dimension,
                    similarity: manifest.similarity
                )
            }

            try await rewritten.commit()
            try await rewritten.verify(deep: options.verifyDeep)
            try await rewritten.close()
        } catch {
            try? await rewritten.close()
            try? fileManager.removeItem(at: destinationURL)
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
            copiedVecIndex: committedVecManifest != nil && committedVecBytes != nil,
            logicalBytesBefore: sourceSizes.logical,
            logicalBytesAfter: destinationSizes.logical,
            allocatedBytesBefore: sourceSizes.allocated,
            allocatedBytesAfter: destinationSizes.allocated,
            durationMs: durationMs
        )
    }

    private func isUpToDateSurrogate(
        surrogateFrameId: UInt64,
        sourceFrame: FrameMeta,
        sourceHash: String,
        algorithmID: String,
        surrogateMaxTokens: Int
    ) async throws -> Bool {
        let surrogate = try await wax.frameMeta(frameId: surrogateFrameId)
        guard surrogate.kind == SurrogateDefaults.kind else { return false }
        guard surrogate.status == .active else { return false }
        guard surrogate.supersededBy == nil else { return false }
        guard let entries = surrogate.metadata?.entries else { return false }
        guard entries[SurrogateMetadataKeys.sourceFrameId] == String(sourceFrame.id) else { return false }
        guard entries[SurrogateMetadataKeys.algorithm] == algorithmID else { return false }
        guard entries[SurrogateMetadataKeys.version] == String(SurrogateDefaults.version) else { return false }
        guard entries[SurrogateMetadataKeys.sourceContentHash] == sourceHash else { return false }
        guard entries[SurrogateMetadataKeys.maxTokens] == String(surrogateMaxTokens) else { return false }
        return true
    }

    private func commitSurrogateBatchIfNeeded() async throws {
        try await session.commit()
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

    private static func fileSizes(at url: URL) throws -> (logical: UInt64, allocated: UInt64) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey])
        let logical = UInt64(max(0, values.fileSize ?? 0))
        let allocatedValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        let allocated = UInt64(max(0, allocatedValue))
        return (logical: logical, allocated: allocated)
    }

    private static func durationMs(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
