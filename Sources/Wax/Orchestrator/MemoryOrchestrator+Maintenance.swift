import Foundation
import WaxCore

public protocol MaintenableMemory: Sendable {
    func optimizeSurrogates(
        options: MaintenanceOptions,
        generator: some SurrogateGenerator
    ) async throws -> MaintenanceReport

    func compactIndexes(options: MaintenanceOptions) async throws -> MaintenanceReport
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
}
