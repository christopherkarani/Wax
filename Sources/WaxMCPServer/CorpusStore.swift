#if MCPServer
import Foundation
import Wax

enum CorpusMetadataKeys {
    static let origin = "wax.corpus.origin"
    static let sourceStorePath = "wax.corpus.source_store_path"
    static let sourceStoreName = "wax.corpus.source_store_name"
    static let sourceFrameID = "wax.corpus.source_frame_id"
    static let sourceTimestampMs = "wax.corpus.source_timestamp_ms"
    static let sourceRole = "wax.corpus.source_role"
    static let sourceKind = "wax.corpus.source_kind"
}

struct CorpusBuildSummary: Equatable, Sendable {
    var storesDiscovered: Int
    var storesIndexed: Int
    var storesSkipped: Int
    var documentsIndexed: Int
    var documentsSkipped: Int
    var targetStorePath: String
}

enum CorpusStoreBuilder {
    static func build(
        sessionsDirectory: URL,
        targetStoreURL: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        recursive: Bool = true
    ) async throws -> CorpusBuildSummary {
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
            return CorpusBuildSummary(
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

        var deferredError: Error?
        var storesIndexed = 0
        var storesSkipped = 0
        var documentsIndexed = 0
        var documentsSkipped = 0

        do {
            try await MCPMemoryFactory.withOpenMemory(
                at: buildURL,
                noEmbedder: noEmbedder,
                embedderChoice: embedderChoice,
                structuredMemoryEnabled: false
            ) { targetMemory in
                for storeURL in storeURLs {
                    let outcome: IngestOutcome
                    do {
                        outcome = try await ingestSourceStore(
                            at: storeURL,
                            into: targetMemory,
                            noEmbedder: noEmbedder
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
                try await targetMemory.flush()
            }
        } catch {
            deferredError = error
        }

        if let deferredError {
            if fileManager.fileExists(atPath: buildURL.path) {
                try? fileManager.removeItem(at: buildURL)
            }
            throw deferredError
        }

        if fileManager.fileExists(atPath: standardizedTarget.path) {
            try fileManager.removeItem(at: standardizedTarget)
        }
        try fileManager.moveItem(at: buildURL, to: standardizedTarget)
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

        return CorpusBuildSummary(
            storesDiscovered: storeURLs.count,
            storesIndexed: storesIndexed,
            storesSkipped: storesSkipped,
            documentsIndexed: documentsIndexed,
            documentsSkipped: documentsSkipped,
            targetStorePath: standardizedTarget.path
        )
    }

    private struct IngestOutcome: Equatable, Sendable {
        var indexedDocuments: Int
        var skippedDocuments: Int
    }

    private static func ingestSourceStore(
        at sourceStoreURL: URL,
        into targetMemory: MemoryOrchestrator,
        noEmbedder: Bool
    ) async throws -> IngestOutcome {
        try await MCPMemoryFactory.withOpenTextOnlyMemory(at: sourceStoreURL) { sourceMemory in
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
    }

    private static func corpusMetadata(
        from document: MemoryOrchestrator.CorpusSourceDocument,
        sourceStoreURL: URL
    ) -> [String: String] {
        var metadata = document.metadata
        metadata[CorpusMetadataKeys.origin] = "session_store"
        metadata[CorpusMetadataKeys.sourceStorePath] = sourceStoreURL.path
        metadata[CorpusMetadataKeys.sourceStoreName] = sourceStoreURL.lastPathComponent
        metadata[CorpusMetadataKeys.sourceFrameID] = String(document.frameId)
        metadata[CorpusMetadataKeys.sourceTimestampMs] = String(document.timestampMs)
        metadata[CorpusMetadataKeys.sourceRole] = roleName(document.role)
        if let kind = document.kind {
            metadata[CorpusMetadataKeys.sourceKind] = kind
        }
        return metadata
    }

    private static func roleName(_ role: FrameRole) -> String {
        switch role {
        case .document:
            "document"
        case .chunk:
            "chunk"
        case .blob:
            "blob"
        case .system:
            "system"
        }
    }

    private static func discoverStoreURLs(
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

    private static func isWaxStore(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("wax") == .orderedSame
    }

    private static func temporaryBuildURL(for targetURL: URL) -> URL {
        let directory = targetURL.deletingLastPathComponent()
        let stem = targetURL.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent("\(stem)-building-\(UUID().uuidString)")
            .appendingPathExtension("wax")
    }

    private static func isSkippableSourceStoreError(_ error: Error) -> Bool {
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
}
#endif
