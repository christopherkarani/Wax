import Foundation

/// Codex (`~/.codex/config.toml`, or `$CODEX_HOME/config.toml`) registration.
///
/// Codex config is TOML, which has no safe partial merge without a real
/// parser. Install therefore defaults to printing an exact snippet; writing
/// is append-only behind an explicit flag and fails closed whenever an
/// existing `[mcp_servers.<name>]` block differs from the rendered one.
enum CodexSetup {
    /// Render the config block for `entry`. The output is the unit of
    /// comparison for up-to-date checks.
    static func snippet(for entry: MuseSetup.ServerEntry) -> String {
        var lines = [
            "[mcp_servers.\(entry.name)]",
            "command = \(TOMLServerBlock.string(entry.command))",
            "args = [\(entry.args.map(TOMLServerBlock.string).joined(separator: ", "))]",
        ]
        if !entry.env.isEmpty {
            lines.append("")
            lines.append("[mcp_servers.\(entry.name).env]")
            for (key, value) in entry.env {
                lines.append("\(TOMLServerBlock.key(key)) = \(TOMLServerBlock.string(value))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Append the entry block to the Codex config, creating the file when it
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
            throw CodexSetupError.notUTF8
        } catch TOMLServerBlock.Failure.differs {
            throw CodexSetupError.differs(configFile.path)
        }
    }

    /// True when the Codex config contains an `[mcp_servers.<name>]` table.
    /// Missing files read as false; non-UTF8 files throw.
    static func hasEntry(name: String, at configFile: URL) throws -> Bool {
        do {
            return try TOMLServerBlock.hasEntry(name: name, at: configFile)
        } catch TOMLServerBlock.Failure.notUTF8 {
            throw CodexSetupError.notUTF8
        }
    }
}

enum CodexSetupError: Error, Equatable, LocalizedError {
    case notUTF8
    case differs(String)

    var errorDescription: String? {
        switch self {
        case .notUTF8:
            return "Codex config.toml is not valid UTF-8."
        case .differs(let path):
            return "Existing [mcp_servers.wax] in \(path) differs from the Wax block; edit it manually instead of overwriting."
        }
    }
}
