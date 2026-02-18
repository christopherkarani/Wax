import Foundation

/// Maps a `GitCommit` into a Wax-compatible metadata dictionary.
enum CommitFrameMapper {

    /// Returns a `[String: String]` metadata dictionary for ingestion into Wax.
    ///
    /// Keys follow the `commit.*` / `repo.*` namespace convention.
    static func metadata(for commit: GitCommit, repoName: String) -> [String: String] {
        var meta: [String: String] = [
            "commit.hash": commit.hash,
            "commit.hash.short": commit.shortHash,
            "commit.author": commit.author,
            "commit.date": commit.date,
            "commit.subject": commit.subject,
            "repo.name": repoName,
        ]

        // Count changed files from the diff (heuristic: lines starting with "diff --git")
        let filesChanged = commit.diff
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("diff --git ") }
            .count
        meta["commit.files_changed"] = "\(filesChanged)"

        return meta
    }
}
