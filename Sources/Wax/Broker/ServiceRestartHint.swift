import Foundation

/// How an operator restarts the shared HTTP server, for error and recovery text.
///
/// On Apple platforms that is the `ai.wax.mcp-http` LaunchAgent. On Linux it is
/// the `wax-mcp-http.service` systemd user unit when one is installed, and
/// otherwise the launcher that `waxmcp install` stages.
package enum ServiceRestartHint {
    /// The systemd user unit shipped at `Resources/systemd/wax-mcp-http.service`.
    package static let systemdUnitName = "wax-mcp-http.service"

    /// "Restart wax-mcp or …", naming this platform's service manager.
    package static func restartClause(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { (path: String) -> Bool in FileManager.default.fileExists(atPath: path) }
    ) -> String {
        #if canImport(Darwin)
        "Restart wax-mcp or `launchctl kickstart -k gui/$(id -u)/ai.wax.mcp-http`"
        #else
        linuxRestartClause(environment: environment, fileExists: fileExists)
        #endif
    }

    /// The Linux restart clause. Pure, so it is tested on every platform.
    package static func linuxRestartClause(
        environment: [String: String],
        fileExists: (String) -> Bool
    ) -> String {
        if fileExists(systemdUserUnitPath(environment: environment)) {
            return "Restart wax-mcp or `systemctl --user restart \(systemdUnitName)`"
        }
        return "Restart wax-mcp, or stop the HTTP server and rerun `\(launcherPath(environment: environment))`"
    }

    /// `$XDG_CONFIG_HOME/systemd/user/wax-mcp-http.service`, where `systemctl --user`
    /// looks for units the user installed. A relative or empty `XDG_CONFIG_HOME` is
    /// invalid under the XDG spec and falls back to `~/.config`.
    package static func systemdUserUnitPath(environment: [String: String]) -> String {
        let configHome: String
        if let raw = environment["XDG_CONFIG_HOME"], raw.hasPrefix("/") {
            configHome = raw
        } else {
            configHome = homeDirectory(environment: environment) + "/.config"
        }
        return URL(fileURLWithPath: configHome, isDirectory: true)
            .appendingPathComponent("systemd/user/\(systemdUnitName)")
            .standardizedFileURL
            .path
    }

    /// `<install root>/bin/start-wax-mcp-http.sh`, the launcher `waxmcp install` stages.
    package static func launcherPath(environment: [String: String]) -> String {
        let root: String
        if let raw = environment["WAX_MCP_INSTALL_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            root = (raw as NSString).expandingTildeInPath
        } else {
            root = homeDirectory(environment: environment) + "/.local/share/waxmcp"
        }
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("bin/start-wax-mcp-http.sh")
            .standardizedFileURL
            .path
    }

    private static func homeDirectory(environment: [String: String]) -> String {
        if let home = environment["HOME"], home.hasPrefix("/") {
            return home
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
