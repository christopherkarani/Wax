#if WaxRepo
import ArgumentParser
import Darwin
import Dispatch
import Foundation
import Noora
import Wax

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM)
import WaxVectorSearchMiniLM
#endif

struct IndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Index git history for semantic search"
    )

    @Option(name: .customLong("repo-path"), help: "Path to the git repository (default: current directory)")
    var repoPath: String = "."

    @Flag(name: .customLong("full"), help: "Re-index from scratch, ignoring previous progress")
    var full: Bool = false

    @Option(name: .customLong("max-commits"), help: "Maximum number of commits to index (0 = unlimited)")
    var maxCommits: Int = 0

    @Flag(name: .customLong("text-only"), help: "Use text search only (skip MiniLM embeddings)")
    var textOnly: Bool = false

    mutating func run() throws {
        let command = self
        Task(priority: .userInitiated) {
            do {
                try await command.runIndex()
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                writeStderr("Error: \(error)")
                Darwin.exit(EXIT_FAILURE)
            }
        }

        dispatchMain()
    }

    private func runIndex() async throws {
        let repoRoot = try resolveRepoRoot(repoPath)
        let waxDir = URL(fileURLWithPath: repoRoot).appendingPathComponent(".wax-repo")
        let storePath = waxDir.appendingPathComponent("store.mv2s")
        let lastHashFile = waxDir.appendingPathComponent("last-indexed-hash")

        // Create .wax-repo directory
        try FileManager.default.createDirectory(at: waxDir, withIntermediateDirectories: true)

        // Auto-add .wax-repo/ to .gitignore
        ensureGitignore(repoRoot: repoRoot)

        // Determine incremental vs full
        var sinceHash: String? = nil
        if !full, let data = try? Data(contentsOf: lastHashFile),
           let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hash.isEmpty {
            sinceHash = hash
        }

        let modeLabel = sinceHash != nil ? "incremental (since \(sinceHash!.prefix(7)))" : "full"
        print("Indexing \(repoRoot) [\(modeLabel)]...")

        // Parse git log. GitLogParser already applies -n when maxCommits > 0,
        // so the returned array is already bounded to maxCommits elements.
        let commits = try await GitLogParser.parseLog(
            repoPath: repoRoot,
            maxCount: maxCommits,
            since: sinceHash
        )

        guard !commits.isEmpty else {
            print("No new commits to index.")
            return
        }

        print("Found \(commits.count) commit\(commits.count == 1 ? "" : "s") to index.")

        // Open store and ingest
        let store = try await RepoStore(storeURL: storePath, textOnly: textOnly)
        let repoName = URL(fileURLWithPath: repoRoot).lastPathComponent

        let startTime = CFAbsoluteTimeGetCurrent()

        try await store.ingest(commits, repoName: repoName) { indexed, total in
            let pct = Int(Double(indexed) / Double(total) * 100)
            let bar = String(repeating: "=", count: pct / 2) + String(repeating: " ", count: 50 - pct / 2)
            print("\r  [\(bar)] \(indexed)/\(total) (\(pct)%)", terminator: "")
            fflush(stdout)
        }
        print() // newline after progress

        // Write last indexed hash
        if let latestHash = commits.first?.hash {
            try latestHash.write(to: lastHashFile, atomically: true, encoding: .utf8)
        }

        try await store.close()

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("Indexed \(commits.count) commit\(commits.count == 1 ? "" : "s") in \(String(format: "%.1f", elapsed))s")
    }
}

// MARK: - Helpers

private func ensureGitignore(repoRoot: String) {
    let gitignorePath = URL(fileURLWithPath: repoRoot).appendingPathComponent(".gitignore")
    let entry = ".wax-repo/"

    if let contents = try? String(contentsOf: gitignorePath, encoding: .utf8) {
        let lines = contents.components(separatedBy: .newlines)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == entry }) {
            return // already present
        }
        // Append entry
        let separator = contents.hasSuffix("\n") ? "" : "\n"
        let updated = contents + separator + entry + "\n"
        try? updated.write(to: gitignorePath, atomically: true, encoding: .utf8)
    } else {
        // Create new .gitignore
        try? (entry + "\n").write(to: gitignorePath, atomically: true, encoding: .utf8)
    }
}

#endif
