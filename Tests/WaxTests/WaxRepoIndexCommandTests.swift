import Foundation
import Testing

@Test func waxRepoFullReindexUsesTemporaryStoreAndSwapsAfterClose() throws {
    let source = try WaxRepoSource.load("Commands/IndexCommand.swift")

    #expect(source.contains("let fullReindexStorePath = full ? temporaryFullReindexStorePath(in: waxDir) : storePath"))
    #expect(source.contains("let store = try await RepoStore(storeURL: fullReindexStorePath, textOnly: textOnly)"))
    #expect(source.contains("try finalizeFullReindex("))

    let closeRange = try #require(source.range(of: "try await store.close()"))
    let finalizeRange = try #require(source.range(of: "try finalizeFullReindex("))
    #expect(closeRange.lowerBound < finalizeRange.lowerBound)
}

@Test func waxRepoFullReindexKeepsOutputsWhenNoCommitsAreIndexed() throws {
    let source = try WaxRepoSource.load("Commands/IndexCommand.swift")

    // A full reindex that parsed nothing has nothing to swap in, so the
    // empty-history branch must return before touching the existing store.
    let guardRange = try #require(source.range(of: "guard !commits.isEmpty else {"))
    let returnRange = try #require(source.range(of: "return", range: guardRange.upperBound..<source.endIndex))
    let emptyBranch = source[guardRange.upperBound..<returnRange.lowerBound]
    #expect(!emptyBranch.contains("storePath"))
    #expect(!emptyBranch.contains("lastHashFile"))
}

@Test(.disabled(if: !waxRepoExecutableSmokeTestsEnabled,
                "Build with --traits default,WaxRepo on macOS 14+ to run WaxRepo executable smoke tests"))
func waxRepoIndexKeepsCommitWhoseDiffIsNotUTF8() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try await WaxRepoFixture.makeGitRepo(prefix: "wax-repo-non-utf8")
    defer { try? FileManager.default.removeItem(at: repo) }
    // Latin-1 "café" plus a 0xFF byte: valid file content, invalid UTF-8.
    try Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0xFF, 0x0A])
        .write(to: repo.appendingPathComponent("latin1.txt"))
    _ = try await WaxRepoProcess.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["git", "add", "latin1.txt"],
        currentDirectoryURL: repo
    )
    _ = try await WaxRepoProcess.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["git", "commit", "-m", "Latin1 searchable commit"],
        currentDirectoryURL: repo
    )

    let index = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only"],
        timeout: 15
    )
    #expect(index.status == 0, "index failed: \(index.stderr)")
    #expect(index.stdout.contains("Found 1 commit to index."), "index output: \(index.stdout)")

    let stats = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["stats", "--repo-path", repo.path],
        timeout: 10
    )
    #expect(try frameCount(from: stats.stdout) >= 1)
}

@Test(.disabled(if: !waxRepoExecutableSmokeTestsEnabled,
                "Build with --traits default,WaxRepo on macOS 14+ to run WaxRepo executable smoke tests"))
func waxRepoFullReindexWithNoCommitsKeepsExistingStore() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try await WaxRepoFixture.makeGitRepo(prefix: "wax-repo-full-empty")
    defer { try? FileManager.default.removeItem(at: repo) }
    try await WaxRepoFixture.addCommit(
        to: repo,
        fileName: "a.txt",
        contents: "indexed content\n",
        message: "Indexed commit"
    )

    let firstIndex = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only"],
        timeout: 15
    )
    #expect(firstIndex.status == 0, "first index failed: \(firstIndex.stderr)")
    let storePath = repo.appendingPathComponent(".wax-repo/store.wax").path
    let hashPath = repo.appendingPathComponent(".wax-repo/last-indexed-hash").path
    #expect(FileManager.default.fileExists(atPath: storePath))
    #expect(FileManager.default.fileExists(atPath: hashPath))

    // Move HEAD to history that git log -p --diff-filter reports as empty.
    for arguments in [
        ["git", "checkout", "-q", "--orphan", "empty-history"],
        ["git", "rm", "-r", "-q", "--cached", "."],
        ["git", "commit", "-q", "--allow-empty", "-m", "Empty commit"],
    ] {
        let step = try await WaxRepoProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: arguments,
            currentDirectoryURL: repo
        )
        #expect(step.status == 0, "\(arguments) failed: \(step.stderr)")
    }

    let fullIndex = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only", "--full"],
        timeout: 15
    )
    #expect(fullIndex.status == 0, "full index failed: \(fullIndex.stderr)")
    #expect(!fullIndex.stdout.contains("Found"), "full index output: \(fullIndex.stdout)")
    #expect(FileManager.default.fileExists(atPath: storePath), "full reindex with no commits deleted the store")
    #expect(FileManager.default.fileExists(atPath: hashPath), "full reindex with no commits deleted the checkpoint")
}

@Test(.disabled(if: !waxRepoExecutableSmokeTestsEnabled,
                "Build with --traits default,WaxRepo on macOS 14+ to run WaxRepo executable smoke tests"))
func waxRepoFullReindexReplacesExistingStore() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try await WaxRepoFixture.makeGitRepo(prefix: "wax-repo-full")
    try await WaxRepoFixture.addCommit(
        to: repo,
        fileName: "old.txt",
        contents: "old searchable content\n",
        message: "Old searchable commit"
    )
    try await WaxRepoFixture.addCommit(
        to: repo,
        fileName: "new.txt",
        contents: "new searchable content\n",
        message: "New searchable commit"
    )

    let firstIndex = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only", "--max-commits", "2"],
        timeout: 15
    )
    #expect(firstIndex.status == 0, "first index failed: \(firstIndex.stderr)")

    let firstStats = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["stats", "--repo-path", repo.path],
        timeout: 10
    )
    let firstFrames = try frameCount(from: firstStats.stdout)
    #expect(firstFrames >= 2)

    let fullIndex = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only", "--full", "--max-commits", "1"],
        timeout: 15
    )
    #expect(fullIndex.status == 0, "full index failed: \(fullIndex.stderr)")

    let fullStats = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["stats", "--repo-path", repo.path],
        timeout: 10
    )
    let fullFrames = try frameCount(from: fullStats.stdout)
    #expect(fullFrames < firstFrames)
}

@Test(.disabled(if: !waxRepoExecutableSmokeTestsEnabled,
                "Build with --traits default,WaxRepo on macOS 14+ to run WaxRepo executable smoke tests"))
func waxRepoLimitedIndexDoesNotCheckpointPastUnindexedOlderHistory() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try await WaxRepoFixture.makeGitRepo(prefix: "wax-repo-limited-checkpoint")
    try await WaxRepoFixture.addCommit(
        to: repo,
        fileName: "old.txt",
        contents: "old checkpoint searchable content\n",
        message: "Old checkpoint searchable commit"
    )
    try await WaxRepoFixture.addCommit(
        to: repo,
        fileName: "new.txt",
        contents: "new checkpoint searchable content\n",
        message: "New checkpoint searchable commit"
    )

    let limitedIndex = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only", "--max-commits", "1"],
        timeout: 15
    )
    #expect(limitedIndex.status == 0, "limited index failed: \(limitedIndex.stderr)")

    let fullIndex = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only"],
        timeout: 15
    )
    #expect(fullIndex.status == 0, "follow-up index failed: \(fullIndex.stderr)")

    let search = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["search", "old checkpoint searchable", "--repo-path", repo.path, "--text-only"],
        timeout: 10
    )
    #expect(search.status == 0, "search failed: \(search.stderr)")
    #expect(search.stdout.contains("Old checkpoint searchable commit"))
}

@Test(.disabled(if: !waxRepoExecutableSmokeTestsEnabled,
                "Build with --traits default,WaxRepo on macOS 14+ to run WaxRepo executable smoke tests"))
func waxRepoIndexRefusesCheckpointThatIsNotACommitHash() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try await WaxRepoFixture.makeGitRepo(prefix: "wax-repo-since-injection")
    defer { try? FileManager.default.removeItem(at: repo) }
    try await WaxRepoFixture.addCommit(
        to: repo,
        fileName: "a.txt",
        contents: "content\n",
        message: "Only commit"
    )
    // A checked-in or tampered checkpoint must not become a git option.
    let injected = repo.appendingPathComponent("pwned")
    let waxDir = repo.appendingPathComponent(".wax-repo", isDirectory: true)
    try FileManager.default.createDirectory(at: waxDir, withIntermediateDirectories: true)
    try "--output=\(injected.path)".write(
        to: waxDir.appendingPathComponent("last-indexed-hash"),
        atomically: true,
        encoding: .utf8
    )

    let index = try await WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only"],
        timeout: 15
    )
    #expect(index.status != 0)
    #expect(index.stderr.contains("non-hex git revision"))
    #expect(!FileManager.default.fileExists(atPath: injected.path))
    #expect(!FileManager.default.fileExists(atPath: injected.path + "..HEAD"))
}

private func frameCount(from statsOutput: String) throws -> Int {
    for line in statsOutput.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Frames:") else { continue }
        let value = trimmed.dropFirst("Frames:".count).trimmingCharacters(in: .whitespaces)
        if let count = Int(value) {
            return count
        }
    }
    throw WaxRepoTestError("Unable to parse frame count from stats output: \(statsOutput)")
}
