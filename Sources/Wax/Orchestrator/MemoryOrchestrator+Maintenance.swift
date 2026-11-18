import Foundation
import WaxCore

package protocol MaintenableMemory: Sendable {
    func optimizeSurrogates(
        options: MaintenanceOptions,
        generator: some SurrogateGenerator
    ) async throws -> MaintenanceReport

    func compactIndexes(options: MaintenanceOptions) async throws -> MaintenanceReport
    func rewriteLiveSet(to destinationURL: URL, options: LiveSetRewriteOptions) async throws -> LiveSetRewriteReport
    func runScheduledLiveSetMaintenanceNow() async throws -> ScheduledLiveSetMaintenanceReport
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
    static let kind = FrameKind.surrogate.storageValue
    static let version: UInt32 = 1
    static let hierarchicalFormat = "hierarchical_v1"
}

package extension MemoryOrchestrator {
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

        let frames = await wax.activeSurrogateSourceFrames()
        var report = MaintenanceReport()
        report.scannedFrames = Int((await wax.stats()).frameCount)

        for frame in frames {
            if let deadline, ContinuousClock.now >= deadline {
                report.didTimeout = true
                break
            }

            if let maxFrames = clampedMaxFrames, report.eligibleFrames >= maxFrames {
                break
            }

            report.eligibleFrames += 1

            let sourceHash = SHA256Checksum.digest(Data(frame.searchText.utf8)).hexString
            let existingId = await wax.surrogateFrameId(sourceFrameId: frame.id)
            let isUpToDate: Bool = if let existingId {
                (try? await isUpToDateSurrogate(
                    surrogateFrameId: existingId,
                    sourceFrameId: frame.id,
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
                    sourceText: frame.searchText,
                    config: options.tierConfig
                )
                guard !tiers.full.isEmpty else { continue }
                surrogatePayload = try JSONEncoder().encode(tiers)
                isHierarchical = true
            } else {
                // Fallback: single-tier legacy format
                let surrogateText = try await generator.generateSurrogate(
                    sourceText: frame.searchText,
                    maxTokens: surrogateMaxTokens
                )
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

        return report
    }

    func compactIndexes(options: MaintenanceOptions = .init()) async throws -> MaintenanceReport {
        var report = MaintenanceReport()
        report.scannedFrames = Int((await wax.stats()).frameCount)

        try await session.commit(compact: true)

        return report
    }

    private func isUpToDateSurrogate(
        surrogateFrameId: UInt64,
        sourceFrameId: UInt64,
        sourceHash: String,
        algorithmID: String,
        surrogateMaxTokens: Int
    ) async throws -> Bool {
        let surrogate = try await wax.frameMeta(frameId: surrogateFrameId)
        guard FrameKind(rawKind: surrogate.kind) == .surrogate else { return false }
        guard surrogate.status == .active else { return false }
        guard surrogate.supersededBy == nil else { return false }
        guard let entries = surrogate.metadata?.entries else { return false }
        guard entries[SurrogateMetadataKeys.sourceFrameId] == String(sourceFrameId) else { return false }
        guard entries[SurrogateMetadataKeys.algorithm] == algorithmID else { return false }
        guard entries[SurrogateMetadataKeys.version] == String(SurrogateDefaults.version) else { return false }
        guard entries[SurrogateMetadataKeys.sourceContentHash] == sourceHash else { return false }
        guard entries[SurrogateMetadataKeys.maxTokens] == String(surrogateMaxTokens) else { return false }
        return true
    }

    private func commitSurrogateBatchIfNeeded() async throws {
        try await session.commit()
    }
}
