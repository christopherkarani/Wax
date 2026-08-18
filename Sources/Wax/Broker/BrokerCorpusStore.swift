import Foundation
import WaxCore

package enum BrokerCorpusMetadataKeys {
    package static let origin = "wax.corpus.origin"
    package static let sourceStorePath = "wax.corpus.source_store_path"
    package static let sourceStoreName = "wax.corpus.source_store_name"
    package static let sourceFrameID = "wax.corpus.source_frame_id"
    package static let sourceTimestampMs = "wax.corpus.source_timestamp_ms"
    package static let sourceRole = "wax.corpus.source_role"
    package static let sourceKind = "wax.corpus.source_kind"
}

package struct BrokerCorpusBuildSummary: Equatable, Sendable {
    package var storesDiscovered: Int
    package var storesIndexed: Int
    package var storesSkipped: Int
    package var documentsIndexed: Int
    package var documentsSkipped: Int
    package var targetStorePath: String
}

/// Ranked hit from disk corpus search or a live active-session search, ready for merge.
package struct BrokerCorpusMergeHit: Sendable, Equatable {
    package var frameId: UInt64
    package var score: Float
    package var sources: [String]
    package var preview: String
    package var metadata: [String: String]
    package var dedupeKey: String

    package init(
        frameId: UInt64,
        score: Float,
        sources: [String],
        preview: String,
        metadata: [String: String],
        dedupeKey: String
    ) {
        self.frameId = frameId
        self.score = score
        self.sources = sources
        self.preview = preview
        self.metadata = metadata
        self.dedupeKey = dedupeKey
    }

    /// Stable identity for cross-source corpus merge (path + frame + preview text).
    package static func makeDedupeKey(sourcePath: String, frameId: UInt64, preview: String) -> String {
        "\(sourcePath)#\(frameId)#\(preview)"
    }
}

/// Pure merge of disk-corpus hits with active-session hit groups (dedupe + score sort + topK).
package enum BrokerCorpusHitMerge {
    /// Merge corpus disk hits with ordered active-session hit batches.
    ///
    /// - Parameters:
    ///   - corpusHits: Hits from the built/on-disk corpus store (first, so they win ties on dedupe).
    ///   - activeSessionHitGroups: One group per active session, in deterministic caller order.
    ///   - topK: Maximum results after score sort (must be >= 0; 0 yields empty).
    /// - Returns: Deduped, score-sorted (desc), frameId-asc tie-break, truncated hits.
    ///
    /// First occurrence of each `dedupeKey` wins (O(n) via `Set`). Active-session groups are
    /// appended after corpus hits so a live hit already present from disk is dropped.
    package static func merge(
        corpusHits: [BrokerCorpusMergeHit],
        activeSessionHitGroups: [[BrokerCorpusMergeHit]],
        topK: Int
    ) -> [BrokerCorpusMergeHit] {
        guard topK > 0 else { return [] }

        var merged: [BrokerCorpusMergeHit] = []
        let estimated =
            corpusHits.count + activeSessionHitGroups.reduce(0) { $0 + $1.count }
        merged.reserveCapacity(min(estimated, max(topK, estimated)))
        var seenKeys = Set<String>()
        seenKeys.reserveCapacity(estimated)

        func appendIfNew(_ hit: BrokerCorpusMergeHit) {
            guard seenKeys.insert(hit.dedupeKey).inserted else { return }
            merged.append(hit)
        }

        for hit in corpusHits {
            appendIfNew(hit)
        }
        for group in activeSessionHitGroups {
            for hit in group {
                appendIfNew(hit)
            }
        }

        merged.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.frameId < rhs.frameId
        }
        if merged.count > topK {
            merged = Array(merged.prefix(topK))
        }
        return merged
    }

    /// Enrich raw search-hit metadata for a live active session before merge.
    package static func annotateActiveSessionMetadata(
        base: [String: String],
        storePath: String,
        storeName: String,
        frameId: UInt64,
        sessionID: String
    ) -> [String: String] {
        var metadata = base
        metadata[BrokerCorpusMetadataKeys.origin] = "active_session"
        metadata[BrokerCorpusMetadataKeys.sourceStorePath] = storePath
        metadata[BrokerCorpusMetadataKeys.sourceStoreName] = storeName
        metadata[BrokerCorpusMetadataKeys.sourceFrameID] = String(frameId)
        metadata["session_id"] = sessionID
        return metadata
    }
}

package enum BrokerCorpusStoreBuilder {
    package static func build(
        sessionsDirectory: URL,
        targetStoreURL: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        embedderTuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment(),
        recursive: Bool = true
    ) async throws -> BrokerCorpusBuildSummary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let standardizedTarget = targetStoreURL.standardizedFileURL
        let targetDirectory = standardizedTarget.deletingLastPathComponent()
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let storeURLs = try discoverStoreURLs(
            in: sessionsDirectory,
            recursive: recursive,
            excluding: [standardizedTarget.path]
        )
        let buildConfiguration = CorpusBuildManifest.BuildConfiguration(
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            recursive: recursive
        )
        let sourceFingerprints = try CorpusBuildManifestStore.fingerprints(for: storeURLs)
        if fileManager.fileExists(atPath: standardizedTarget.path),
           let manifest = try CorpusBuildManifestStore.load(for: standardizedTarget),
           manifest.version == CorpusBuildManifest.currentVersion,
           manifest.configuration == buildConfiguration,
           manifest.sources == sourceFingerprints {
            return BrokerCorpusBuildSummary(
                storesDiscovered: storeURLs.count,
                storesIndexed: 0,
                storesSkipped: 0,
                documentsIndexed: 0,
                documentsSkipped: 0,
                targetStorePath: standardizedTarget.path
            )
        }

        let buildURL = temporaryBuildURL(for: standardizedTarget)
        if fileManager.fileExists(atPath: buildURL.path) {
            try fileManager.removeItem(at: buildURL)
        }

        var storesIndexed = 0
        var storesSkipped = 0
        var documentsIndexed = 0
        var documentsSkipped = 0

        let memory = try await openMemory(
            at: buildURL,
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            embedderTuning: embedderTuning,
            structuredMemoryEnabled: false
        )
        try await memory.waitUntilReadyForRemember()

        do {
            for storeURL in storeURLs {
                let outcome: IngestOutcome
                do {
                    outcome = try await ingestSourceStore(
                        at: storeURL,
                        into: memory,
                        noEmbedder: noEmbedder,
                        embedderChoice: embedderChoice,
                        embedderTuning: embedderTuning
                    )
                } catch {
                    guard isSkippableSourceStoreError(error) else {
                        throw error
                    }
                    storesSkipped += 1
                    continue
                }
                if outcome.indexedDocuments > 0 {
                    storesIndexed += 1
                }
                documentsIndexed += outcome.indexedDocuments
                documentsSkipped += outcome.skippedDocuments
            }
            try await memory.flush()
            try await memory.close()
        } catch {
            try? await memory.close()
            throw error
        }

        try replaceExistingCorpusStore(at: standardizedTarget, with: buildURL)
        if storesSkipped == 0 {
            try CorpusBuildManifestStore.save(
                CorpusBuildManifest(
                    configuration: buildConfiguration,
                    sources: sourceFingerprints,
                    generatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
                ),
                for: standardizedTarget
            )
        } else {
            try? CorpusBuildManifestStore.delete(for: standardizedTarget)
        }

        return BrokerCorpusBuildSummary(
            storesDiscovered: storeURLs.count,
            storesIndexed: storesIndexed,
            storesSkipped: storesSkipped,
            documentsIndexed: documentsIndexed,
            documentsSkipped: documentsSkipped,
            targetStorePath: standardizedTarget.path
        )
    }
}

private extension BrokerCorpusStoreBuilder {
    struct IngestOutcome: Equatable, Sendable {
        var indexedDocuments: Int
        var skippedDocuments: Int
    }

    static func ingestSourceStore(
        at sourceStoreURL: URL,
        into targetMemory: MemoryOrchestrator,
        noEmbedder: Bool,
        embedderChoice: String,
        embedderTuning: CommandLineEmbedderRuntimeTuning
    ) async throws -> IngestOutcome {
        let sourceMemory = try await openMemory(
            at: sourceStoreURL,
            noEmbedder: true,
            embedderChoice: embedderChoice,
            embedderTuning: embedderTuning,
            structuredMemoryEnabled: false
        )
        defer {
            Task {
                try? await sourceMemory.close()
            }
        }
        let sourceDocuments = try await sourceMemory.corpusSourceDocuments()
        if noEmbedder {
            try await targetMemory.ingestCorpusDocumentsTextOnly(
                sourceDocuments.map { document in
                    MemoryOrchestrator.CorpusTargetDocument(
                        timestampMs: document.timestampMs,
                        text: document.text,
                        metadata: corpusMetadata(from: document, sourceStoreURL: sourceStoreURL)
                    )
                }
            )
            return IngestOutcome(
                indexedDocuments: sourceDocuments.count,
                skippedDocuments: 0
            )
        }

        var indexedDocuments = 0
        for document in sourceDocuments {
            try await targetMemory.remember(
                document.text,
                metadata: corpusMetadata(from: document, sourceStoreURL: sourceStoreURL)
            )
            indexedDocuments += 1
        }

        return IngestOutcome(indexedDocuments: indexedDocuments, skippedDocuments: 0)
    }

    static func corpusMetadata(
        from document: MemoryOrchestrator.CorpusSourceDocument,
        sourceStoreURL: URL
    ) -> [String: String] {
        var metadata = document.metadata
        metadata[BrokerCorpusMetadataKeys.origin] = "session_store"
        metadata[BrokerCorpusMetadataKeys.sourceStorePath] = sourceStoreURL.path
        metadata[BrokerCorpusMetadataKeys.sourceStoreName] = sourceStoreURL.lastPathComponent
        metadata[BrokerCorpusMetadataKeys.sourceFrameID] = String(document.frameId)
        metadata[BrokerCorpusMetadataKeys.sourceTimestampMs] = String(document.timestampMs)
        metadata[BrokerCorpusMetadataKeys.sourceRole] = roleName(document.role)
        if let kind = document.kind {
            metadata[BrokerCorpusMetadataKeys.sourceKind] = kind
        }
        return metadata
    }

    static func roleName(_ role: FrameRole) -> String {
        switch role {
        case .document:
            return "document"
        case .chunk:
            return "chunk"
        case .blob:
            return "blob"
        case .system:
            return "system"
        }
    }

    static func discoverStoreURLs(
        in root: URL,
        recursive: Bool,
        excluding excludedPaths: Set<String>
    ) throws -> [URL] {
        let fileManager = FileManager.default
        let standardizedRoot = root.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedRoot.path) else {
            return []
        }

        if !recursive {
            let items = try fileManager.contentsOfDirectory(
                at: standardizedRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            return items
                .map(\.standardizedFileURL)
                .filter { isWaxStore($0) && !excludedPaths.contains($0.path) }
                .sorted { $0.path < $1.path }
        }

        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let candidate as URL in enumerator {
            let standardized = candidate.standardizedFileURL
            guard isWaxStore(standardized), !excludedPaths.contains(standardized.path) else {
                continue
            }
            results.append(standardized)
        }
        results.sort { $0.path < $1.path }
        return results
    }

    static func isWaxStore(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("wax") == .orderedSame
    }

    static func temporaryBuildURL(for targetURL: URL) -> URL {
        let directory = targetURL.deletingLastPathComponent()
        let stem = targetURL.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent("\(stem)-building-\(UUID().uuidString)")
            .appendingPathExtension("wax")
    }

    static func replaceExistingCorpusStore(at targetURL: URL, with buildURL: URL) throws {
        let fileManager = FileManager.default
        let backupURL = temporaryBackupURL(for: targetURL)
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }

        var movedExistingStore = false

        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.moveItem(at: targetURL, to: backupURL)
                movedExistingStore = true
            }

            try fileManager.moveItem(at: buildURL, to: targetURL)

            if movedExistingStore {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            if movedExistingStore, !fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.moveItem(at: backupURL, to: targetURL)
            }
            throw error
        }
    }

    static func temporaryBackupURL(for targetURL: URL) -> URL {
        let directory = targetURL.deletingLastPathComponent()
        let stem = targetURL.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent("\(stem)-backup-\(UUID().uuidString)")
            .appendingPathExtension("wax")
    }

    static func isSkippableSourceStoreError(_ error: Error) -> Bool {
        if let waxError = error as? WaxError {
            switch waxError {
            case .lockUnavailable:
                return true
            case .io(let details):
                return details.localizedCaseInsensitiveContains("no such file")
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == ENOENT {
            return true
        }
        return false
    }

    static func openMemory(
        at url: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        embedderTuning: CommandLineEmbedderRuntimeTuning,
        structuredMemoryEnabled: Bool
    ) async throws -> MemoryOrchestrator {
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = structuredMemoryEnabled
        let request = try HostEmbeddingReadiness.request(
            noEmbedder: noEmbedder,
            requireVector: false,
            embedderChoice: embedderChoice,
            options: BuiltInEmbeddingProviderOptions(tuning: embedderTuning)
        )
        return try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: request,
            waxOptions: CommandLineEmbedderFactory.waxOptions()
        )
    }
}
