import Foundation
import Wax
import WaxCore

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
            guard isCommitHash(since) else {
                throw GitLogError.invalidRevision(since)
            }
            args.append("\(since)..HEAD")
        }
        // Everything before `--` is a revision; nothing after it is an option.
        args.append("--")

        let output = try await runGit(args)
        return parseOutput(output)
    }

    /// Returns the full diff for a single commit hash.
    static func showCommit(hash: String, repoPath: String) async throws -> String {
        guard isCommitHash(hash) else {
            throw GitLogError.invalidRevision(hash)
        }
        let args = [
            "git", "-C", repoPath,
            "show", "--stat", "--patch", hash, "--",
        ]
        return try await runGit(args)
    }

    /// Full or abbreviated hex object name. Anything else (`--output=...`,
    /// `HEAD~1`, ranges) is refused so a stored checkpoint cannot become a
    /// git option.
    static func isCommitHash(_ value: String) -> Bool {
        (4...64).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }

    // MARK: - Shell execution

    private static let exitAfterEOFTimeoutSeconds: TimeInterval = 30

    private static func runGit(_ arguments: [String]) async throws -> String {
        // readDataToEndOfFile() and waitUntilExit() block their thread, so git runs on a
        // private serial queue: off the cooperative pool, and not queued behind other
        // work on a shared global queue.
        try await BlockingWork.run { () throws -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            // Drain stdout and stderr together before waiting: either
            // pipe fills at ~64 KB and blocks git if left unread.
            let captured = ProcessPipeDrain(stdout: stdoutPipe, stderr: stderrPipe).wait()
            // Both pipes are closed, so git is exiting; the bound only
            // stops a wedged wait.
            guard process.waitForExit(timeout: exitAfterEOFTimeoutSeconds) != nil else {
                throw GitLogError.gitFailed("git did not exit after closing its output")
            }
            guard process.terminationStatus == 0 else {
                let stderr = String(data: captured.stderr, encoding: .utf8) ?? ""
                let message = stderr.isEmpty ? "git exited with \(process.terminationStatus)" : stderr
                throw GitLogError.gitFailed(message)
            }

            return String(data: captured.stdout, encoding: .utf8) ?? ""
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
enum GitLogError: LocalizedError, CustomStringConvertible, Sendable {
    case gitFailed(String)
    case invalidRevision(String)

    var description: String { errorDescription ?? "git failed" }

    var errorDescription: String? {
        switch self {
        case .gitFailed(let message):
            return message
        case .invalidRevision(let value):
            return "Refusing non-hex git revision '\(value)'. Re-run with --full to rebuild the index checkpoint."
        }
    }
}
