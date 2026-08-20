import Foundation
import Testing
@testable import Wax

struct MemorySemanticsScopeContextTests {
    @Test(arguments: ["", ".", "./"])
    func inferScopeContextReturnsQuicklyWhenStartAndProcessPathsAreMissing(path: String) throws {
        let result = try completingWithin(
            milliseconds: 1_000,
            description: "inferScopeContext(currentDirectoryPath: \(path.debugDescription), processDirectoryPath: \"\")"
        ) {
            MemorySemantics.inferScopeContext(currentDirectoryPath: path, processDirectoryPath: "")
        }
        #expect(result.elapsed < .milliseconds(1_000))
        #expect(result.value.repoName == nil)
        #expect(result.value.projectName == nil)
        #expect(result.value.repoRootPath == nil)
    }

    @Test
    func emptyClientCwdDoesNotInheritProcessWorkingDirectory() throws {
        let processCWD = FileManager.default.currentDirectoryPath
        #expect(processCWD.hasPrefix("/"))

        let result = MemorySemantics.inferScopeContext(
            currentDirectoryPath: "",
            processDirectoryPath: processCWD
        )
        #expect(result.cwdPath == nil)
        #expect(result.repoName == nil)
        #expect(result.projectName == nil)
        #expect(result.repoRootPath == nil)
    }

    @Test
    func inferScopeContextReturnsQuicklyForDeletedDirectoryPath() throws {
        let doomed = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-deleted-infer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        let doomedPath = doomed.path
        try FileManager.default.removeItem(at: doomed)

        let result = try completingWithin(
            milliseconds: 1_000,
            description: "inferScopeContext on deleted directory"
        ) {
            MemorySemantics.inferScopeContext(currentDirectoryPath: doomedPath)
        }
        #expect(result.elapsed < .milliseconds(1_000))
        #expect(result.value.repoName == nil)
        #expect(result.value.projectName == nil)
        #expect(result.value.repoRootPath == nil)
    }

    @Test
    func inferScopeContextUsesGitRepoLastPathComponent() throws {
        let repoName = "wax-scope-repo-\(UUID().uuidString.prefix(8))"
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(repoName, isDirectory: true)
        let nestedURL = repoURL.appendingPathComponent("src/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }
        try FileManager.default.createDirectory(
            at: repoURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let result = try completingWithin(
            milliseconds: 1_000,
            description: "inferScopeContext on nested git workdir"
        ) {
            MemorySemantics.inferScopeContext(currentDirectoryPath: nestedURL.path)
        }
        #expect(result.elapsed < .milliseconds(1_000))
        #expect(result.value.repoName == repoName)
        #expect(result.value.projectName == repoName)
        #expect(result.value.repoRootPath == repoURL.standardizedFileURL.path)
    }

    @Test
    func inferScopeContextUsesMainRepoNameForLinkedWorktree() throws {
        let repoName = "wax-main-repo-\(UUID().uuidString.prefix(8))"
        let worktreeFolder = "worktree-rapid-river-\(UUID().uuidString.prefix(6))"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-worktree-infer-\(UUID().uuidString)", isDirectory: true)
        let repoURL = root.appendingPathComponent(repoName, isDirectory: true)
        let worktreeURL = root.appendingPathComponent(worktreeFolder, isDirectory: true)
        let worktreeGitDir = repoURL
            .appendingPathComponent(".git/worktrees/\(worktreeFolder)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        let gitFile = worktreeURL.appendingPathComponent(".git")
        try "gitdir: \(worktreeGitDir.path)\n".write(to: gitFile, atomically: true, encoding: .utf8)

        let result = try completingWithin(
            milliseconds: 1_000,
            description: "inferScopeContext on linked worktree cwd"
        ) {
            MemorySemantics.inferScopeContext(currentDirectoryPath: worktreeURL.path)
        }
        #expect(result.elapsed < .milliseconds(1_000))
        #expect(result.value.repoName == repoName)
        #expect(result.value.projectName == repoName)
        #expect(result.value.repoRootPath == repoURL.standardizedFileURL.path)
        #expect(result.value.repoName != worktreeFolder)
    }
}

private struct TimedValue<T> {
    var value: T
    var elapsed: Duration
}

private final class TimedBox<T>: @unchecked Sendable {
    var value: T?
}

private func completingWithin<T>(
    milliseconds: Int,
    description: String,
    work: @escaping @Sendable () -> T
) throws -> TimedValue<T> {
    let box = TimedBox<T>()
    let started = ContinuousClock.now
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        box.value = work()
        done.signal()
    }
    let wait = done.wait(timeout: .now() + .milliseconds(milliseconds))
    #expect(wait == .success, "\(description) did not return within \(milliseconds)ms")
    let value = try #require(box.value, "\(description) produced no value")
    return TimedValue(value: value, elapsed: ContinuousClock.now - started)
}
