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

@Test func waxRepoFullReindexClearsOutputsWhenNoCommitsAreIndexed() throws {
    let source = try WaxRepoSource.load("Commands/IndexCommand.swift")

    let resetRange = try #require(source.range(of: "try resetFullReindexOutputsIfNeeded("))
    let noCommitsRange = try #require(source.range(of: "print(\"No new commits to index.\")"))
    #expect(resetRange.lowerBound < noCommitsRange.lowerBound)
}

@Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14))
func waxRepoFullReindexReplacesExistingStore() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try WaxRepoFixture.makeGitRepo(prefix: "wax-repo-full")
    try WaxRepoFixture.addCommit(
        to: repo,
        fileName: "old.txt",
        contents: "old searchable content\n",
        message: "Old searchable commit"
    )
    try WaxRepoFixture.addCommit(
        to: repo,
        fileName: "new.txt",
        contents: "new searchable content\n",
        message: "New searchable commit"
    )

    let firstIndex = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only", "--max-commits", "2"],
        timeout: 15
    )
    #expect(firstIndex.status == 0, "first index failed: \(firstIndex.stderr)")

    let firstStats = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["stats", "--repo-path", repo.path],
        timeout: 10
    )
    let firstFrames = try frameCount(from: firstStats.stdout)
    #expect(firstFrames >= 2)

    let fullIndex = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only", "--full", "--max-commits", "1"],
        timeout: 15
    )
    #expect(fullIndex.status == 0, "full index failed: \(fullIndex.stderr)")

    let fullStats = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["stats", "--repo-path", repo.path],
        timeout: 10
    )
    let fullFrames = try frameCount(from: fullStats.stdout)
    #expect(fullFrames < firstFrames)
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
