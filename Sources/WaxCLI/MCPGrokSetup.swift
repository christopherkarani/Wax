import Foundation

/// Grok CLI (`~/.grok/config.toml`, or `$GROK_HOME/config.toml`)
/// registration for `mcp install`.
///
/// Same TOML discipline as Codex: config is append-only behind an explicit
/// flag and fails closed whenever an existing `[mcp_servers.<name>]` block
/// differs from the rendered one. Grok renders env as an inline table and
/// honors an `enabled` flag.
enum GrokSetup {
    /// Render the config block for `entry`. The output is the unit of
    /// comparison for up-to-date checks.
    static func snippet(for entry: MuseSetup.ServerEntry) -> String {
        var lines = [
            "[mcp_servers.\(entry.name)]",
            "command = \(TOMLServerBlock.string(entry.command))",
            "args = [\(entry.args.map(TOMLServerBlock.string).joined(separator: ", "))]",
        ]
        if !entry.env.isEmpty {
            let pairs = entry.env.map { "\(TOMLServerBlock.key($0.0)) = \(TOMLServerBlock.string($0.1))" }
            lines.append("env = { \(pairs.joined(separator: ", ")) }")
        }
        lines.append("enabled = true")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Append the entry block to the Grok config, creating the file when it
    /// is missing. Never edits an existing block: identical blocks are a
    /// no-op and differing blocks throw `differs`.
    static func write(
        entry: MuseSetup.ServerEntry,
        at configFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MuseSetup.MergeResult {
        do {
            return try TOMLServerBlock.write(
                name: entry.name,
                block: snippet(for: entry),
                at: configFile,
                writer: writer
            )
        } catch TOMLServerBlock.Failure.notUTF8 {
            throw GrokSetupError.notUTF8
        } catch TOMLServerBlock.Failure.differs {
            throw GrokSetupError.differs(configFile.path)
        }
    }

    /// True when the Grok config contains an `[mcp_servers.<name>]` table.
    /// Missing files read as false; non-UTF8 files throw.
    static func hasEntry(name: String, at configFile: URL) throws -> Bool {
        do {
            return try TOMLServerBlock.hasEntry(name: name, at: configFile)
        } catch TOMLServerBlock.Failure.notUTF8 {
            throw GrokSetupError.notUTF8
        }
    }
}

enum GrokSetupError: Error, Equatable, LocalizedError {
    case notUTF8
    case differs(String)

    var errorDescription: String? {
        switch self {
        case .notUTF8:
            return "Grok config.toml is not valid UTF-8."
        case .differs(let path):
            return "Existing [mcp_servers.wax] in \(path) differs from the Wax block; edit it manually instead of overwriting."
        }
    }
}
