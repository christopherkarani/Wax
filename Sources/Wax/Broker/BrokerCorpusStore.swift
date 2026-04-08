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
    package var documentsIndexed: Int
    package var documentsSkipped: Int
    package var targetStorePath: String
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

        let buildURL = temporaryBuildURL(for: standardizedTarget)
        if fileManager.fileExists(atPath: buildURL.path) {
            try fileManager.removeItem(at: buildURL)
        }

        var storesIndexed = 0
        var documentsIndexed = 0
        var documentsSkipped = 0

        let memory = try await openMemory(
            at: buildURL,
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            embedderTuning: embedderTuning,
            structuredMemoryEnabled: false
        )

        do {
            for storeURL in storeURLs {
                let outcome = try await ingestSourceStore(
                    at: storeURL,
                    into: memory,
                    embedderChoice: embedderChoice,
                    embedderTuning: embedderTuning
                )
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

        if fileManager.fileExists(atPath: standardizedTarget.path) {
            try fileManager.removeItem(at: standardizedTarget)
        }
        try fileManager.moveItem(at: buildURL, to: standardizedTarget)

        return BrokerCorpusBuildSummary(
            storesDiscovered: storeURLs.count,
            storesIndexed: storesIndexed,
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
        var indexedDocuments = 0

        for document in sourceDocuments {
            try await targetMemory.remember(
                document.text,
                metadata: corpusMetadata(from: document, sourceStoreURL: sourceStoreURL)
            )
            indexedDocuments += 1
        }

        return IngestOutcome(
            indexedDocuments: indexedDocuments,
            skippedDocuments: 0
        )
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

    static func openMemory(
        at url: URL,
        noEmbedder: Bool,
        embedderChoice: String,
        embedderTuning: CommandLineEmbedderRuntimeTuning,
        structuredMemoryEnabled: Bool
    ) async throws -> MemoryOrchestrator {
        let embedder = try await CommandLineEmbedderFactory.buildEmbedder(
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            tuning: embedderTuning
        )
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = structuredMemoryEnabled
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        return try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder,
            waxOptions: CommandLineEmbedderFactory.waxOptions()
        )
    }
}
