#if os(Linux)
import Foundation
import Testing
@testable import Wax

/// The broker client finds `wax-cli` on the injected `PATH` without running
/// `which`, which minimal Linux images often lack.
@Test func brokerCLIPathIsFoundOnAPathWithoutWhich() throws {
    let bin = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bin) }
    let cli = bin.appendingPathComponent("wax-cli")
    try "#!/bin/sh\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

    // Only `bin` is on PATH, so neither `which` nor anything else from the host is.
    let resolved = AgentBrokerPathing.resolveBrokerCLIPath(
        currentExecutablePath: "wax-mcp-not-on-path",
        environment: ["PATH": bin.path, "HOME": bin.path]
    )

    #expect(resolved == cli.path)
}
#endif
