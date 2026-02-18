import Foundation

/// Parses `git log` output into `GitCommit` values using a line-by-line state machine.
enum GitLogParser {

    /// Maximum diff bytes kept per commit (~8 KB).
    private static let maxDiffBytes = 8192

    /// Sentinel emitted by the custom `--format` to delimit commits.
    private static let commitSentinel = "WAX_COMMIT_START"

    // MARK: - Public API

    /// Runs `git log` in the given repository and returns parsed commits.
    ///
    /// - Parameters:
    ///   - repoPath: Absolute path to the git working tree.
    ///   - maxCount: Maximum number of commits to fetch (0 = unlimited, default 0).
    ///   - since: Optional commit hash for incremental indexing (`<hash>..HEAD`).
    /// - Returns: Array of parsed commits, newest first.
    static func parseLog(
        repoPath: String,
        maxCount: Int = 0,
        since: String? = nil
    ) async throws -> [GitCommit] {
        var args = [
            "git", "-C", repoPath,
            "log",
            "--format=\(commitSentinel)%nHASH:%H%nAUTHOR:%an%nDATE:%aI%nSUBJECT:%s%nBODY_START%n%b%nBODY_END",
            "--no-merges",
            "-p",
            "--diff-filter=ACDMRT",
        ]
        if maxCount > 0 {
            args.append(contentsOf: ["-n", "\(maxCount)"])
        }
        if let since {
            args.append("\(since)..HEAD")
        }

        let output = try await runGit(args)
        return parseOutput(output)
    }

    /// Returns the full diff for a single commit hash.
    static func showCommit(hash: String, repoPath: String) async throws -> String {
        let args = [
            "git", "-C", repoPath,
            "show", "--stat", "--patch", hash,
        ]
        return try await runGit(args)
    }

    // MARK: - Shell execution

    private static func runGit(_ arguments: [String]) async throws -> String {
        // Move blocking I/O off the Swift cooperative thread pool.
        // readDataToEndOfFile() and waitUntilExit() both block their calling thread;
        // running them on a DispatchQueue.global() thread prevents starving async work.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Read ALL stdout before waitUntilExit to avoid pipe buffer deadlock.
                // macOS pipes have a 64 KB buffer; large git log output fills it and
                // blocks the writing process if we wait for exit first.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    let message = String(data: data, encoding: .utf8) ?? "git exited with \(process.terminationStatus)"
                    continuation.resume(throwing: GitLogError.gitFailed(message))
                    return
                }

                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            }
        }
    }

    // MARK: - State machine parser

    private enum ParseState {
        case idle
        case header
        case body
        case diff
    }

    private static func parseOutput(_ output: String) -> [GitCommit] {
        var commits: [GitCommit] = []
        var state: ParseState = .idle

        var hash = ""
        var author = ""
        var date = ""
        var subject = ""
        var bodyLines: [String] = []
        var diffLines: [String] = []
        var diffBytes = 0

        func finalizeCommit() {
            guard !hash.isEmpty else { return }
            let shortHash = String(hash.prefix(7))
            let body = bodyLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let diff = diffLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            commits.append(GitCommit(
                hash: hash,
                shortHash: shortHash,
                author: author,
                date: date,
                subject: subject,
                body: body,
                diff: diff
            ))
            hash = ""
            author = ""
            date = ""
            subject = ""
            bodyLines = []
            diffLines = []
            diffBytes = 0
        }

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            // Commit boundary
            if line == commitSentinel {
                finalizeCommit()
                state = .header
                continue
            }

            switch state {
            case .idle:
                continue

            case .header:
                if line.hasPrefix("HASH:") {
                    hash = String(line.dropFirst(5))
                } else if line.hasPrefix("AUTHOR:") {
                    author = String(line.dropFirst(7))
                } else if line.hasPrefix("DATE:") {
                    date = String(line.dropFirst(5))
                } else if line.hasPrefix("SUBJECT:") {
                    subject = String(line.dropFirst(8))
                } else if line == "BODY_START" {
                    state = .body
                }

            case .body:
                if line == "BODY_END" {
                    state = .diff
                } else {
                    bodyLines.append(line)
                }

            case .diff:
                // diff lines accumulate until next commit sentinel
                guard diffBytes < maxDiffBytes else { continue }
                let lineBytes = line.utf8.count + 1 // +1 for newline
                diffBytes += lineBytes
                if diffBytes <= maxDiffBytes {
                    diffLines.append(line)
                }
            }
        }

        // Finalize last commit
        finalizeCommit()
        return commits
    }
}

/// Errors from git log parsing.
enum GitLogError: Error, Sendable {
    case gitFailed(String)
}
