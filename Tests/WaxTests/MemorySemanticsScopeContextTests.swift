import Foundation
import Testing
@testable import Wax

@Suite(.serialized)
struct MemorySemanticsScopeContextTests {
    @Test(arguments: ["", ".", "./"])
    func inferScopeContextReturnsWithin100msForEmptyOrDotPath(path: String) throws {
        try withDeletedCurrentDirectory {
            let result = try completingWithin(
                milliseconds: 100,
                description: "inferScopeContext(currentDirectoryPath: \(path.debugDescription))"
            ) {
                MemorySemantics.inferScopeContext(currentDirectoryPath: path)
            }
            #expect(result.elapsed < .milliseconds(100))
            #expect(result.value.repoName == nil)
            #expect(result.value.projectName == nil)
            #expect(result.value.repoRootPath == nil)
        }
    }

    @Test
    func inferScopeContextReturnsWithin100msForDeletedDirectoryPath() throws {
        let doomed = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-deleted-infer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        let doomedPath = doomed.path
        try FileManager.default.removeItem(at: doomed)

        let result = try completingWithin(
            milliseconds: 100,
            description: "inferScopeContext on deleted directory"
        ) {
            MemorySemantics.inferScopeContext(currentDirectoryPath: doomedPath)
        }
        #expect(result.elapsed < .milliseconds(100))
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
            milliseconds: 100,
            description: "inferScopeContext on nested git workdir"
        ) {
            MemorySemantics.inferScopeContext(currentDirectoryPath: nestedURL.path)
        }
        #expect(result.elapsed < .milliseconds(100))
        #expect(result.value.repoName == repoName)
        #expect(result.value.projectName == repoName)
        #expect(result.value.repoRootPath == repoURL.standardizedFileURL.path)
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

private func withDeletedCurrentDirectory(_ body: () throws -> Void) throws {
    let fileManager = FileManager.default
    let original = fileManager.currentDirectoryPath
    let doomed = fileManager.temporaryDirectory
        .appendingPathComponent("wax-deleted-cwd-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: doomed, withIntermediateDirectories: true)
    guard fileManager.changeCurrentDirectoryPath(doomed.path) else {
        Issue.record("failed to enter temporary directory \(doomed.path)")
        return
    }
    try fileManager.removeItem(at: doomed)
    defer {
        if !original.isEmpty {
            _ = fileManager.changeCurrentDirectoryPath(original)
        }
    }
    try body()
}
