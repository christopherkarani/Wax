import Foundation
import Testing
@testable import wax_cli
import WaxCore

/// `mcp doctor` on Linux reports the host facts Wax depends on there: glibc,
/// the built-in embedders, the broker socket directory and the systemd user
/// session. Only conditions that break or slow Wax are warnings or failures.
@Suite struct LinuxRuntimeDoctorTests {
    private static func probes(
        glibc: String? = "2.39",
        embedders: [String] = ["e5", "minilm"],
        socketWritable: Bool = true,
        systemd: Bool = true,
        unitInstalled: Bool = false
    ) -> LinuxRuntimeDoctor.Probes {
        LinuxRuntimeDoctor.Probes(
            glibcVersion: glibc,
            builtInEmbedders: embedders,
            socketDirectory: "/home/ada/.local/share/waxmcp/broker",
            socketDirectoryWritable: socketWritable,
            systemdUserSession: systemd,
            systemdUnitPath: "/home/ada/.config/systemd/user/wax-mcp-http.service",
            systemdUnitInstalled: unitInstalled
        )
    }

    @Test func aHealthyHostHasNoWarningsOrFailures() {
        let report = LinuxRuntimeDoctor.report(Self.probes(), expectVectorRuntime: true)
        #expect(report.warnings.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(report.lines == [
            "glibc: 2.39",
            "embedders: e5, minilm",
            "broker socket directory: /home/ada/.local/share/waxmcp/broker (writable)",
            "systemd user session: running",
            "wax-mcp-http.service: not installed (see Resources/docs/wax-mcp-hosts.md)",
        ])
    }

    @Test(arguments: ["2.33", "2.31", "2.29"])
    func glibcBefore234WarnsAboutTheSlowerDescriptorClosingPath(version: String) {
        let report = LinuxRuntimeDoctor.report(Self.probes(glibc: version), expectVectorRuntime: true)
        #expect(report.failures.isEmpty)
        #expect(report.warnings.count == 1)
        #expect(report.warnings.first?.contains("glibc \(version) is older than 2.34") == true)
        #expect(report.warnings.first?.contains("/proc/self/fd") == true)
    }

    @Test func glibcBefore229WarnsThatChildrenCannotChangeDirectory() {
        let report = LinuxRuntimeDoctor.report(Self.probes(glibc: "2.28"), expectVectorRuntime: true)
        #expect(report.failures.isEmpty)
        #expect(report.warnings.contains { $0.contains("glibc 2.28 is older than 2.29") && $0.contains("working directory") })
    }

    @Test func anUnknownLibcIsReportedWithoutAWarning() {
        let report = LinuxRuntimeDoctor.report(Self.probes(glibc: nil), expectVectorRuntime: true)
        #expect(report.lines.first == "glibc: not detected")
        #expect(report.warnings.isEmpty)
    }

    @Test func aBuildWithoutMiniLMWarnsOnlyWhenVectorsAreExpected() {
        let expected = LinuxRuntimeDoctor.report(Self.probes(embedders: []), expectVectorRuntime: true)
        #expect(expected.lines.contains("embedders: none built in"))
        #expect(expected.warnings.contains { $0.contains("MiniLMEmbeddings") })

        let textOnly = LinuxRuntimeDoctor.report(Self.probes(embedders: []), expectVectorRuntime: false)
        #expect(textOnly.warnings.isEmpty)
    }

    @Test func anUnwritableSocketDirectoryFails() {
        let report = LinuxRuntimeDoctor.report(Self.probes(socketWritable: false), expectVectorRuntime: true)
        #expect(report.lines.contains("broker socket directory: /home/ada/.local/share/waxmcp/broker (not writable)"))
        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("WAX_BROKER_DIR") == true)
    }

    @Test func systemdIsInformational() {
        let report = LinuxRuntimeDoctor.report(
            Self.probes(systemd: false, unitInstalled: true),
            expectVectorRuntime: true
        )
        #expect(report.warnings.isEmpty)
        #expect(report.lines.contains("systemd user session: not detected"))
        #expect(report.lines.contains("wax-mcp-http.service: installed (/home/ada/.config/systemd/user/wax-mcp-http.service)"))
    }

    @Test(arguments: [("glibc 2.39", "2.39"), ("glibc 2.17", "2.17"), ("musl", nil), ("", nil), ("glibc 2", nil)])
    func glibcVersionIsParsedFromConfstr(raw: String, version: String?) {
        #expect(LinuxRuntimeDoctor.glibcVersion(fromConfstr: raw) == version)
    }

    #if os(Linux)
    @Test func liveProbesReadThisHost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-linux-doctor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingSocketDir = root.appendingPathComponent("a/b/broker", isDirectory: true)

        let probes = LinuxRuntimeDoctor.liveProbes(environment: [
            "HOME": root.path,
            "WAX_BROKER_DIR": missingSocketDir.path,
            "XDG_RUNTIME_DIR": root.appendingPathComponent("runtime").path,
        ])

        #expect(probes.glibcVersion.map { $0.hasPrefix("2.") } == true)
        #expect(probes.builtInEmbedders.contains("minilm"))
        // A missing directory is creatable when its nearest existing parent is writable.
        #expect(probes.socketDirectory == missingSocketDir.path)
        #expect(probes.socketDirectoryWritable)
        #expect(!probes.systemdUserSession)
        #expect(probes.systemdUnitPath == root.appendingPathComponent(".config/systemd/user/wax-mcp-http.service").path)
        #expect(!probes.systemdUnitInstalled)
        #expect(!FileManager.default.fileExists(atPath: missingSocketDir.path), "doctor must not create the directory")
    }

    /// The real command prints the section, and nothing macOS-specific.
    @Test(.timeLimit(.minutes(2)))
    func mcpDoctorPrintsTheLinuxRuntimeSection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-linux-doctor-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("wax-cli")

        let process = ChildProcess()
        process.executableURL = cli
        process.arguments = [
            "mcp", "doctor",
            "--server-path", root.appendingPathComponent("missing-wax-mcp").path,
            "--store-path", root.appendingPathComponent("store.wax").path,
        ]
        process.environment = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin",
            "WAX_BROKER_DIR": root.appendingPathComponent("broker").path,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = await BlockingWork.run { () -> String in
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        _ = await BlockingWork.run { () -> Int32? in process.waitForExit(timeout: 60) }

        #expect(output.contains("## Linux runtime"))
        #expect(output.contains("glibc: 2."))
        #expect(output.contains("embedders: "))
        #expect(output.contains("broker socket directory: \(root.appendingPathComponent("broker").path) (writable)"))
        #expect(output.contains("systemd user session: "))
        #expect(!output.contains("LaunchAgent"))
        #expect(!output.contains("launchctl"))
    }
    #endif
}
