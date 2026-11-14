import Foundation
import Testing
@testable import wax_cli
import WaxCore

/// `mcp install` and `mcp doctor` recognise a packaged runtime under
/// `dist/<platform>-<arch>`: `darwin-arm64` for Apple, `linux-x64` and
/// `linux-arm64` for Linux. On Linux the resource bundles are SwiftPM's
/// `.resources` directories.
@Suite struct DistRuntimePathingTests {
    @Test(arguments: ["darwin-arm64", "linux-x64", "linux-arm64"])
    func packagedRuntimeDirectoryIsRecognised(platform: String) throws {
        let fixture = try DistFixture(platform: platform)
        defer { fixture.remove() }

        let resolved = Pathing.bundledRuntimeDirectory(forExecutablePath: fixture.cli.path)

        #expect(resolved?.standardizedFileURL.path == fixture.distDir.standardizedFileURL.path)
    }

    @Test(arguments: ["freebsd-x64", "linux", "x64"])
    func otherDirectoriesUnderDistAreNotPackagedRuntimes(platform: String) throws {
        let fixture = try DistFixture(platform: platform)
        defer { fixture.remove() }

        #expect(Pathing.bundledRuntimeDirectory(forExecutablePath: fixture.cli.path) == nil)
    }

    #if os(Linux)
    @Test func linuxPackagedRuntimeStagesIntoItsPlatformDirectoryWithResources() throws {
        let fixture = try DistFixture(platform: "linux-x64")
        defer { fixture.remove() }
        let bundles = [
            "Wax_Wax.resources",
            "Wax_WaxBertTokenizer.resources",
            "Wax_WaxVectorSearch.resources",
            "Wax_WaxVectorSearchMiniLM.resources",
        ]
        for bundle in bundles {
            try FileManager.default.createDirectory(
                at: fixture.distDir.appendingPathComponent(bundle, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let installRoot = fixture.root.appendingPathComponent("install-root", isDirectory: true)

        let runtime = try Pathing.prepareMCPInstallRuntime(
            cliPath: fixture.cli.path,
            serverPath: fixture.server.path,
            dryRun: false,
            environment: ["HOME": fixture.root.path, "WAX_MCP_INSTALL_ROOT": installRoot.path]
        )

        let expectedDir = installRoot.appendingPathComponent("linux-x64", isDirectory: true)
        #expect(runtime.staged)
        #expect(runtime.serverPath == expectedDir.appendingPathComponent("wax-mcp").path)
        for bundle in bundles {
            #expect(FileManager.default.fileExists(atPath: expectedDir.appendingPathComponent(bundle).path))
        }
        let validation = try Pathing.validateMCPRuntime(serverPath: runtime.serverPath, expectVectorRuntime: true)
        #expect(validation.failures.isEmpty)
        #expect(validation.warnings.isEmpty, "unexpected warnings: \(validation.warnings)")
    }
    #endif
}

private struct DistFixture {
    let root: URL
    let distDir: URL

    init(platform: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-dist-pathing-\(UUID().uuidString)", isDirectory: true)
        distDir = root.appendingPathComponent("package/dist/\(platform)", isDirectory: true)
        try FileManager.default.createDirectory(at: distDir, withIntermediateDirectories: true)
        for executable in [cli, server] {
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let digest = SHA256Checksum.digest(try Data(contentsOf: executable)).hexString
            try "\(digest)  \(executable.lastPathComponent)\n".write(
                to: distDir.appendingPathComponent("\(executable.lastPathComponent).sha256"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    var cli: URL { distDir.appendingPathComponent("wax-cli") }
    var server: URL { distDir.appendingPathComponent("wax-mcp") }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
