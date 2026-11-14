import Foundation
import Testing
@testable import WaxTextSearch
import WaxCore

/// A file-backed FTS5 index lives in a temp directory named for its owner's pid, so a later
/// process removes copies whose owner exited before its engine's deinit could.
@Suite struct FTS5BackingDirectoryTests {
    @Test func directoriesNameTheirOwningProcess() throws {
        try withParent { parent in
            let directory = try FTS5BackingDirectory.make(under: parent)
            #expect(directory.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
            #expect(FTS5BackingDirectory.ownerPID(of: directory.lastPathComponent) == getpid())
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test func removesOnlyDirectoriesWhoseOwnerHasExited() throws {
        try withParent { parent in
            let exited = try exitedProcessID()
            let orphan = parent.appendingPathComponent("\(exited)-\(UUID().uuidString)", isDirectory: true)
            let mine = try FTS5BackingDirectory.make(under: parent)
            let unrelated = parent.appendingPathComponent("not-a-wax-dir", isDirectory: true)
            for directory in [orphan, unrelated] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            FileManager.default.createFile(
                atPath: orphan.appendingPathComponent("fts.sqlite").path,
                contents: Data(repeating: 1, count: 4096)
            )

            let removed = FTS5BackingDirectory.removeOrphans(in: parent)

            #expect(removed == [orphan.lastPathComponent])
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(FileManager.default.fileExists(atPath: mine.path))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
        }
    }

    @Test func deserializedEngineKeepsItsDatabaseUnderTheSharedParent() async throws {
        let image = try await FTS5SearchEngine.inMemory().serialize()
        let engine = try FTS5SearchEngine.deserialize(from: image)
        let url = try #require(await engine.databaseURL)
        let owner = url.deletingLastPathComponent()
        #expect(owner.deletingLastPathComponent().lastPathComponent == FTS5BackingDirectory.parentName)
        #expect(FTS5BackingDirectory.ownerPID(of: owner.lastPathComponent) == getpid())
    }

    private func withParent(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-fts5-dir-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent)
    }

    /// The pid of a child that has exited and been reaped.
    private func exitedProcessID() throws -> pid_t {
        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 0"]
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
