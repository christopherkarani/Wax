import Foundation

/// Claude Code registration helpers for `mcp install`.
///
/// `claude mcp add` refuses a name that is already registered, so install
/// removes the old entry first. The `claude` CLI has no machine-readable
/// `get`, so the old entry is read from the file Claude Code keeps for the
/// scope and, if the add fails, put back with `claude mcp add-json`, which
/// takes the same JSON shape.
enum ClaudeSetup {
    /// The registered server `name` in `scope` as a JSON object string, or
    /// nil when there is none or its config cannot be read.
    static func registrationJSON(
        name: String,
        scope: WaxCLI.MCPScope,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) -> String? {
        let servers: Any?
        switch scope {
        case .user:
            servers = readJSONObject(globalConfigURL(environment: environment))?["mcpServers"]
        case .local:
            let projects = readJSONObject(globalConfigURL(environment: environment))?["projects"]
            servers = ((projects as? [String: Any])?[currentDirectory] as? [String: Any])?["mcpServers"]
        case .project:
            let projectFile = URL(fileURLWithPath: currentDirectory).appendingPathComponent(".mcp.json")
            servers = readJSONObject(projectFile)?["mcpServers"]
        }
        guard let entry = (servers as? [String: Any])?[name] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Re-add a registration captured by `registrationJSON` after a failed
    /// `claude mcp add`. Reports the outcome on stderr; never throws.
    static func restore(
        name: String,
        scope: WaxCLI.MCPScope,
        registrationJSON: String,
        claudePath: String
    ) {
        let status = try? ProcessRunner.run(
            command: claudePath,
            arguments: ["mcp", "add-json", "-s", scope.rawValue, name, registrationJSON],
            passthrough: false,
            allowNonZeroExit: true
        )
        if status == EXIT_SUCCESS {
            writeStderr("Restored the previous Claude Code registration for '\(name)'.")
        } else {
            writeStderr(
                "warning: could not restore the previous Claude Code registration for '\(name)'; " +
                "re-register it with 'claude mcp add'."
            )
        }
    }

    /// `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json`, where
    /// Claude Code keeps user- and local-scope servers.
    static func globalConfigURL(environment: [String: String]) -> URL {
        let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
