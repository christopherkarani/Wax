import Foundation
import Testing
@testable import Wax

/// Restart advice for the shared HTTP server names the service manager the
/// host actually uses: a systemd user unit on Linux when one is installed,
/// otherwise the staged launcher.
@Suite struct ServiceRestartHintTests {
    private static let home = "/home/ada"

    @Test func linuxClauseNamesSystemctlWhenTheUserUnitIsInstalled() {
        let unit = "/home/ada/.config/systemd/user/wax-mcp-http.service"
        let clause = ServiceRestartHint.linuxRestartClause(
            environment: ["HOME": Self.home],
            fileExists: { (path: String) -> Bool in path == unit }
        )
        #expect(clause == "Restart wax-mcp or `systemctl --user restart wax-mcp-http.service`")
        #expect(!clause.contains("launchctl"))
    }

    @Test func linuxClauseNamesTheLauncherWithoutAUserUnit() {
        let clause = ServiceRestartHint.linuxRestartClause(
            environment: ["HOME": Self.home],
            fileExists: { (_: String) -> Bool in false }
        )
        #expect(clause == "Restart wax-mcp, or stop the HTTP server and rerun `/home/ada/.local/share/waxmcp/bin/start-wax-mcp-http.sh`")
        #expect(!clause.contains("launchctl"))
        #expect(!clause.contains("systemctl"))
    }

    @Test func linuxClauseHonoursTheInstallRootAndXDGConfigHome() {
        let unit = "/xdg/config/systemd/user/wax-mcp-http.service"
        let withUnit = ServiceRestartHint.linuxRestartClause(
            environment: ["HOME": Self.home, "XDG_CONFIG_HOME": "/xdg/config"],
            fileExists: { (path: String) -> Bool in path == unit }
        )
        #expect(withUnit.contains("systemctl --user restart wax-mcp-http.service"))

        let launcher = ServiceRestartHint.linuxRestartClause(
            environment: ["HOME": Self.home, "WAX_MCP_INSTALL_ROOT": "/opt/waxmcp"],
            fileExists: { (_: String) -> Bool in false }
        )
        #expect(launcher.hasSuffix("`/opt/waxmcp/bin/start-wax-mcp-http.sh`"))
    }

    /// The XDG spec says a relative `XDG_CONFIG_HOME` is invalid and must be ignored.
    @Test func systemdUnitPathIgnoresARelativeXDGConfigHome() {
        #expect(
            ServiceRestartHint.systemdUserUnitPath(environment: ["HOME": Self.home, "XDG_CONFIG_HOME": "relative"])
                == "/home/ada/.config/systemd/user/wax-mcp-http.service"
        )
        #expect(
            ServiceRestartHint.systemdUserUnitPath(environment: ["HOME": Self.home, "XDG_CONFIG_HOME": ""])
                == "/home/ada/.config/systemd/user/wax-mcp-http.service"
        )
    }

    #if os(Linux)
    @Test func linuxBrokerAndToolHintsNeverNameLaunchctl() {
        let clause = ServiceRestartHint.restartClause(
            environment: ["HOME": Self.home],
            fileExists: { (_: String) -> Bool in false }
        )
        #expect(clause.hasPrefix("Restart wax-mcp"))
        #expect(!clause.contains("launchctl"))
        let message = AgentBrokerClient.muteBrokerMessage(
            socketPath: "/tmp/broker.sock",
            restartClause: clause
        )
        #expect(!message.contains("launchctl"))
        #expect(message.contains("Not starting a second daemon"))
        #expect(message.contains("committed=false"))
        #expect(message.contains("conversation_id"))
    }
    #endif

    #if canImport(Darwin)
    @Test func darwinClauseKeepsTheLaunchAgentRestart() {
        let clause = ServiceRestartHint.restartClause(environment: [:], fileExists: { (_: String) -> Bool in false })
        #expect(clause == "Restart wax-mcp or `launchctl kickstart -k gui/$(id -u)/ai.wax.mcp-http`")
    }
    #endif
}

/// The shipped systemd user unit mirrors the documented LaunchAgent: run at
/// login, restart whenever it exits, the long broker start timeout, and a stop
/// timeout that covers the broker daemon's shutdown.
@Suite struct SystemdUserUnitResourceTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func unitText() throws -> String {
        try String(
            contentsOf: packageRoot.appendingPathComponent("Resources/systemd/\(ServiceRestartHint.systemdUnitName)"),
            encoding: .utf8
        )
    }

    private static func directives(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("["),
                  let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            values[key] = values[key].map { "\($0)\n\(value)" } ?? value
        }
        return values
    }

    @Test func unitRunsTheStagedLauncherAndRestartsLikeKeepAlive() throws {
        let values = Self.directives(try Self.unitText())
        #expect(values["ExecStart"] == "%h/.local/share/waxmcp/bin/start-wax-mcp-http.sh")
        #expect(values["Restart"] == "always")
        #expect(values["WantedBy"] == "default.target")
        #expect(values["KillSignal"] == "SIGTERM")
        #expect(values["KillMode"] == "control-group")
    }

    @Test func unitKeepsTheLongBrokerStartTimeout() throws {
        let values = Self.directives(try Self.unitText())
        let environment = values["Environment"] ?? ""
        let timeout = environment
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("WAX_BROKER_START_TIMEOUT_SECS=") }
            .flatMap { Double($0.split(separator: "=").last ?? "") }
        #expect(timeout == 60)
    }

    /// The daemon must exit within the client's 2 s SIGTERM grace and drains
    /// admitted requests for at most 1 s. The stop timeout leaves room for both
    /// and for the HTTP server's own teardown, and is still bounded.
    @Test func unitStopTimeoutCoversTheDaemonShutdownGrace() throws {
        let values = Self.directives(try Self.unitText())
        let stop = try #require(values["TimeoutStopSec"].flatMap(Double.init))
        #expect(stop >= 2 + 1)
        #expect(stop <= 10)
    }

    @Test func hostsDocCarriesTheShippedUnitVerbatim() throws {
        let hosts = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Resources/docs/wax-mcp-hosts.md"),
            encoding: .utf8
        )
        for line in try Self.unitText().split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            #expect(hosts.contains(String(line)), "wax-mcp-hosts.md is missing unit line: \(line)")
        }
        #expect(hosts.contains("systemctl --user enable --now wax-mcp-http.service"))
        #expect(hosts.contains("systemctl --user restart wax-mcp-http.service"))
        #expect(hosts.contains("~/.config/systemd/user/wax-mcp-http.service"))
    }
}
