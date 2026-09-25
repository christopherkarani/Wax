import Foundation
import Testing
@testable import wax_cli

@Suite("MCPInstallHosts")
struct MCPInstallHostsTests {
    @Test func parseSpecAutoAllAndList() throws {
        #expect(try MCPInstallHosts.parseSpec("auto") == .auto)
        #expect(try MCPInstallHosts.parseSpec(" ALL ") == .all)
        #expect(try MCPInstallHosts.parseSpec("claude,muse") == .only([.claude, .muse]))
        #expect(try MCPInstallHosts.parseSpec(" Cursor ") == .only([.cursor]))
    }

    @Test func parseSpecRejectsUnknownAndEmpty() {
        #expect(throws: InstallHostError.unknownHost("vim")) {
            try MCPInstallHosts.parseSpec("claude,vim")
        }
        #expect(throws: InstallHostError.emptySpec) {
            try MCPInstallHosts.parseSpec("  ")
        }
    }

    @Test func detectUsesBinaryOrConfig() {
        let home = URL(fileURLWithPath: "/Users/probe")
        let probe = HostProbe(
            commandExists: { $0 == "claude" || $0 == "codex" },
            fileExists: { $0 == "/Users/probe/.cursor/mcp.json" }
        )
        #expect(MCPInstallHosts.detect(.claude, probe: probe, homeDirectory: home).detected)
        #expect(!MCPInstallHosts.detect(.muse, probe: probe, homeDirectory: home).detected)
        #expect(MCPInstallHosts.detect(.cursor, probe: probe, homeDirectory: home).detected)
        #expect(MCPInstallHosts.detect(.codex, probe: probe, homeDirectory: home).detected)
    }

    @Test func detectGrokAndOpenCodeViaBinaryOrConfig() {
        let home = URL(fileURLWithPath: "/Users/probe")
        let grokConfig = MCPInstallHosts.grokConfigURL(homeDirectory: home).path
        let binaryProbe = HostProbe(
            commandExists: { $0 == "grok" || $0 == "opencode" },
            fileExists: { _ in false }
        )
        #expect(MCPInstallHosts.detect(.grok, probe: binaryProbe, homeDirectory: home).detected)
        #expect(MCPInstallHosts.detect(.opencode, probe: binaryProbe, homeDirectory: home).detected)
        let configProbe = HostProbe(
            commandExists: { _ in false },
            fileExists: { path in
                path == grokConfig
                    || path == "/Users/probe/.config/opencode/opencode.json"
            }
        )
        #expect(MCPInstallHosts.detect(.grok, probe: configProbe, homeDirectory: home).detected)
        #expect(MCPInstallHosts.detect(.opencode, probe: configProbe, homeDirectory: home).detected)
    }

    @Test func detectMuseViaExistingSettings() {
        let home = URL(fileURLWithPath: "/Users/probe")
        let settings = MuseSetup.settingsURL(environment: [:], homeDirectory: home).path
        let probe = HostProbe(commandExists: { _ in false }, fileExists: { $0 == settings })
        let detection = MCPInstallHosts.detect(.muse, probe: probe, environment: [:], homeDirectory: home)
        #expect(detection.detected)
    }

    @Test func codexHomeHonorsCodexHomeEnv() {
        let home = MCPInstallHosts.codexHome(
            environment: ["CODEX_HOME": "/tmp/codex-probe"],
            homeDirectory: URL(fileURLWithPath: "/Users/probe")
        )
        #expect(home.path == "/tmp/codex-probe")
        let config = MCPInstallHosts.codexConfigURL(
            environment: ["CODEX_HOME": "/tmp/codex-probe"],
            homeDirectory: URL(fileURLWithPath: "/Users/probe")
        )
        #expect(config.path == "/tmp/codex-probe/config.toml")
    }

    @Test func resolveAutoSelectsDetectedAndReportsSkipped() throws {
        let home = URL(fileURLWithPath: "/Users/probe")
        let probe = HostProbe(commandExists: { $0 == "claude" }, fileExists: { _ in false })
        let resolved = try MCPInstallHosts.resolve(spec: .auto, skipMuse: false, probe: probe, homeDirectory: home)
        #expect(resolved.selected == [.claude])
        #expect(resolved.skipped.map(\.host) == [.muse, .cursor, .codex, .grok, .opencode])
    }

    @Test func resolveAutoThrowsWhenNothingDetected() {
        let home = URL(fileURLWithPath: "/Users/probe")
        let probe = HostProbe(commandExists: { _ in false }, fileExists: { _ in false })
        #expect(throws: InstallHostError.self) {
            try MCPInstallHosts.resolve(spec: .auto, skipMuse: false, probe: probe, homeDirectory: home)
        }
    }

    @Test func resolveAppliesSkipMuse() throws {
        let home = URL(fileURLWithPath: "/Users/probe")
        let probe = HostProbe(commandExists: { $0 == "claude" || $0 == "muse" }, fileExists: { _ in false })
        let resolved = try MCPInstallHosts.resolve(spec: .auto, skipMuse: true, probe: probe, homeDirectory: home)
        #expect(resolved.selected == [.claude])
    }

    @Test func resolveFlagsConflictingMuseSelection() {
        let home = URL(fileURLWithPath: "/Users/probe")
        let probe = HostProbe(commandExists: { _ in true }, fileExists: { _ in true })
        #expect(throws: InstallHostError.conflictingMuseFlags) {
            try MCPInstallHosts.resolve(spec: .only([.muse]), skipMuse: true, probe: probe, homeDirectory: home)
        }
    }

    @Test func validateServerBinaryChecksVersionExitCode() {
        let seen = ArgsBox()
        #expect(MCPInstallHosts.validateServerBinary(serverPath: "/bin/x") { _, args in
            seen.mutate { $0 = args }
            return CapturedProcessOutput(status: EXIT_SUCCESS, stdout: "wax-mcp 0.1", stderr: "")
        })
        #expect(seen.value == ["--version"])
        #expect(!MCPInstallHosts.validateServerBinary(serverPath: "/bin/x") { _, _ in
            CapturedProcessOutput(status: 1, stdout: "", stderr: "nope")
        })
        struct Blast: Error {}
        #expect(!MCPInstallHosts.validateServerBinary(serverPath: "/bin/x") { _, _ in throw Blast() })
    }

    @Test func resolveAllSelectsEveryHostInOrder() throws {
        let home = URL(fileURLWithPath: "/Users/probe")
        let probe = HostProbe(commandExists: { _ in false }, fileExists: { _ in false })
        let resolved = try MCPInstallHosts.resolve(spec: .all, skipMuse: false, probe: probe, homeDirectory: home)
        #expect(resolved.selected == [.claude, .muse, .cursor, .codex, .grok, .opencode])
        #expect(resolved.skipped.isEmpty)
    }
}

private final class ArgsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var value: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout [String]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}
