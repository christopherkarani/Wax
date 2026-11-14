import Foundation
import Testing
@testable import wax_cli

/// `wax-cli` resolves tools and checksums in-process: no `which`, no `shasum`.
@Suite struct ToolLookupTests {
    #if os(Linux)
    @Test func resolveToolPathUsesTheInjectedPathWithoutWhich() throws {
        let bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-tool-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bin) }
        let tool = bin.appendingPathComponent("wax-lookup-probe")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        #expect(try resolveToolPath("wax-lookup-probe", environment: ["PATH": bin.path]) == tool.path)
        #expect(throws: CLIError.self) {
            try resolveToolPath("wax-lookup-probe-missing", environment: ["PATH": bin.path])
        }
    }
    #endif

    /// FIPS 180-2 test vectors.
    @Test func runtimeChecksumIsComputedInProcess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-sha256-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let small = root.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: small)
        #expect(try Pathing.sha256Hex(for: small) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        // 1,000,000 x "a": the FIPS 180-2 long-message vector.
        let large = root.appendingPathComponent("million-a")
        try Data(repeating: UInt8(ascii: "a"), count: 1_000_000).write(to: large)
        #expect(try Pathing.sha256Hex(for: large) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
