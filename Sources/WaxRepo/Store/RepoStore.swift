import Foundation
import Wax
import WaxCore
import WaxVectorSearch

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM)
import CoreML
import WaxVectorSearchMiniLM
#endif

/// A search hit from the commit store, enriched with commit metadata.
struct CommitSearchResult: Sendable {
    let hash: String
    let shortHash: String
    let author: String
    let date: String
    let subject: String
    let score: Float
    let previewText: String
}

/// Lightweight stats about the underlying store.
struct StoreStats: Sendable {
    let frameCount: UInt64
    let storeURL: URL
}

/// Wraps a `MemoryOrchestrator` to provide commit-oriented ingest and search.
actor RepoStore {

    private let memory: MemoryOrchestrator
    private let storeURL: URL

    /// Structured header prefix written into each ingested commit's content.
    /// Parsed back from `previewText` during search to recover commit metadata
    /// without needing cross-module access to internal Wax frame metadata.
    private static let headerPrefix = "COMMIT:"

    /// Creates a `RepoStore` backed by a `.mv2s` file at the given URL.
    ///
    /// Uses MiniLM for embeddings when the `MiniLMEmbeddings` trait is active
    /// and `textOnly` is false. Falls back to text-only search otherwise.
    init(storeURL: URL, textOnly: Bool = false) async throws {
        self.storeURL = storeURL

        let embedder: (any EmbeddingProvider)? = try await {
            guard !textOnly else { return nil }
            #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM)
            // Some CLI executable contexts are unstable with CoreML batch
            // prediction APIs. Keep batch size at 1 so MiniLM runs through
            // the single-prediction path for reliability.
            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = .cpuOnly
            let config = MiniLMEmbedder.Config(batchSize: 1, modelConfiguration: modelConfiguration)
            let e = try MiniLMEmbedder(config: config)
            try await e.prewarm(batchSize: 1)
            return e
            #else
            return nil
            #endif
        }()

        var config = OrchestratorConfig.default
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }

        self.memory = try await MemoryOrchestrator(
            at: storeURL,
            config: config,
            embedder: embedder
        )
    }

    // MARK: - Ingest

    /// Ingests an array of commits into the store.
    ///
    /// Each commit is stored with a structured header that encodes metadata
    /// (hash, author, date) so it can be recovered from search previews.
    ///
    /// - Parameters:
    ///   - commits: Parsed git commits to ingest.
    ///   - repoName: Display name for the repository (stored in metadata).
    ///   - progress: Called after each commit with (completed, total).
    func ingest(
        _ commits: [GitCommit],
        repoName: String,
        progress: @Sendable (Int, Int) -> Void
    ) async throws {
        let total = commits.count
        for (index, commit) in commits.enumerated() {
            let meta = CommitFrameMapper.metadata(for: commit, repoName: repoName)
            let content = Self.formatContent(for: commit)
            try await memory.remember(content, metadata: meta)
            progress(index + 1, total)
        }
        try await memory.flush()
    }

    // MARK: - Search

    /// Searches the commit store and returns enriched results.
    ///
    /// - Parameters:
    ///   - query: Free-text search query.
    ///   - topK: Maximum number of results (default 10).
    /// - Returns: Ranked commit search results with metadata.
    func search(query: String, topK: Int = 10) async throws -> [CommitSearchResult] {
        let hits = try await memory.search(query: query, topK: topK)
        guard !hits.isEmpty else { return [] }

        return hits.compactMap { hit -> CommitSearchResult? in
            guard let preview = hit.previewText else { return nil }
            return Self.parseResult(from: preview, score: hit.score)
        }
    }

    // MARK: - Stats

    /// Returns lightweight statistics about the store.
    func stats() async -> StoreStats {
        let runtimeStats = await memory.runtimeStats()
        return StoreStats(
            frameCount: runtimeStats.frameCount,
            storeURL: storeURL
        )
    }

    // MARK: - Lifecycle

    /// Flushes pending writes and closes the store.
    func close() async throws {
        try await memory.close()
    }

    // MARK: - Content formatting

    /// Formats commit content with a structured header for metadata recovery.
    ///
    /// Header format (one line):
    /// `COMMIT:<hash>|<shortHash>|<author>|<date>|<subject>`
    ///
    /// Followed by the original `ingestContent`.
    private static func formatContent(for commit: GitCommit) -> String {
        let header = "\(headerPrefix)\(commit.hash)|\(commit.shortHash)|\(commit.author)|\(commit.date)|\(commit.subject)"
        return header + "\n" + commit.ingestContent
    }

    /// Parses a `CommitSearchResult` from a preview string containing the structured header.
    ///
    /// Returns `nil` if the preview lacks the structured header or has an invalid format.
    /// Callers use `compactMap` to silently filter out unparseable results rather than
    /// displaying results with empty hash/author/date fields in the TUI.
    private static func parseResult(from preview: String, score: Float) -> CommitSearchResult? {
        guard preview.hasPrefix(headerPrefix) else {
            // No structured header — result cannot be displayed meaningfully.
            return nil
        }

        // Extract header line
        let firstNewline = preview.firstIndex(of: "\n") ?? preview.endIndex
        let headerLine = String(preview[preview.index(preview.startIndex, offsetBy: headerPrefix.count)..<firstNewline])
        let parts = headerLine.components(separatedBy: "|")

        guard parts.count >= 5 else {
            // Malformed header — filter out rather than showing empty fields.
            return nil
        }

        let remainingText = firstNewline < preview.endIndex
            ? String(preview[preview.index(after: firstNewline)...])
            : ""

        return CommitSearchResult(
            hash: parts[0],
            shortHash: parts[1],
            author: parts[2],
            date: parts[3],
            subject: parts[4..<parts.count].joined(separator: "|"),
            score: score,
            previewText: remainingText
        )
    }

    private static func writeStderr(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

}
