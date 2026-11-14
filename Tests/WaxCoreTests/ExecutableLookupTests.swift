import Foundation
import Testing
@testable import WaxCore

/// `ExecutableLookup` finds a tool on an injected `PATH` in-process, so a
/// lookup works on hosts without `which` (Arch base, distroless, BusyBox
/// images built without it).
@Suite struct ExecutableLookupTests {
    @Test func findsTheFirstExecutableOnPath() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let first = try fixture.makeTool("wax-tool", in: "a")
        _ = try fixture.makeTool("wax-tool", in: "b")

        let found = ExecutableLookup.find("wax-tool", environment: ["PATH": fixture.path("a", "b")])

        #expect(found == first)
    }

    @Test func skipsNonExecutableFilesAndDirectories() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        try fixture.makeFile("wax-tool", in: "a", mode: 0o644)
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("b/wax-tool", isDirectory: true),
            withIntermediateDirectories: true
        )
        let executable = try fixture.makeTool("wax-tool", in: "c")

        let found = ExecutableLookup.find("wax-tool", environment: ["PATH": fixture.path("a", "b", "c")])

        #expect(found == executable)
    }

    /// Empty and relative entries would resolve against the working directory,
    /// so they are skipped rather than letting a checkout shadow a tool.
    @Test func skipsEmptyAndRelativePathEntries() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeTool("wax-tool", in: "a")

        let found = ExecutableLookup.find(
            "wax-tool",
            environment: ["PATH": ":relative/bin::\(fixture.path("a"))"]
        )

        #expect(found == executable)
    }

    @Test func returnsNilWithoutPathOrMatch() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }

        #expect(ExecutableLookup.find("wax-tool", environment: [:]) == nil)
        #expect(ExecutableLookup.find("wax-tool", environment: ["PATH": fixture.path("a")]) == nil)
        #expect(ExecutableLookup.find("", environment: ["PATH": "/usr/bin:/bin"]) == nil)
    }

    @Test func aNameWithASlashIsCheckedAsGiven() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeTool("wax-tool", in: "a")

        #expect(ExecutableLookup.find(executable, environment: [:]) == executable)
        #expect(ExecutableLookup.find(executable + "-missing", environment: [:]) == nil)
    }
}

private struct PathFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-path-lookup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func path(_ directories: String...) -> String {
        directories.map { root.appendingPathComponent($0, isDirectory: true).path }.joined(separator: ":")
    }

    @discardableResult
    func makeFile(_ name: String, in directory: String, mode: Int16) throws -> String {
        let dir = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: file.path)
        return file.path
    }

    func makeTool(_ name: String, in directory: String) throws -> String {
        try makeFile(name, in: directory, mode: 0o755)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
