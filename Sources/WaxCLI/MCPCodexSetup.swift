import Foundation

/// Codex (`~/.codex/config.toml`, or `$CODEX_HOME/config.toml`) registration.
///
/// Codex config is TOML, which has no safe partial merge without a real
/// parser. Install therefore defaults to printing an exact snippet; writing
/// is append-only behind an explicit flag and fails closed whenever an
/// existing `[mcp_servers.<name>]` block differs from the rendered one.
enum CodexSetup {
    /// Render the config block for `entry`. The output is the unit of
    /// comparison for up-to-date checks and verbatim removal.
    static func snippet(for entry: MuseSetup.ServerEntry) -> String {
        var lines = [
            "[mcp_servers.\(entry.name)]",
            "command = \(tomlString(entry.command))",
            "args = [\(entry.args.map(tomlString).joined(separator: ", "))]",
        ]
        if !entry.env.isEmpty {
            lines.append("")
            lines.append("[mcp_servers.\(entry.name).env]")
            for (key, value) in entry.env {
                lines.append("\(tomlKey(key)) = \(tomlString(value))")
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
        try HostHookTransactionWriter.refuseSymlink(configFile)
        let block = snippet(for: entry)

        guard FileManager.default.fileExists(atPath: configFile.path) else {
            try HostHookTransactionWriter.refuseSymlink(configFile.deletingLastPathComponent())
            try writer.commit([
                HostHookWritePlan(
                    url: configFile,
                    originalBytes: nil,
                    preimageHash: HostHookTransactionWriter.hash(Data()),
                    renderedBytes: Data(block.utf8),
                    originalMode: 0o600
                )
            ])
            return MuseSetup.MergeResult(mutated: true, settingsURL: configFile)
        }

        let bytes = try Data(contentsOf: configFile)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CodexSetupError.notUTF8
        }
        if hasServerTable(text, name: entry.name) {
            if text.contains(block) {
                return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
            }
            throw CodexSetupError.differs(configFile.path)
        }

        var rendered = text
        if !rendered.isEmpty, !rendered.hasSuffix("\n") {
            rendered.append("\n")
        }
        if !rendered.isEmpty, !rendered.hasSuffix("\n\n") {
            rendered.append("\n")
        }
        rendered.append(block)
        try writer.commit([
            HostHookWritePlan(
                url: configFile,
                originalBytes: bytes,
                preimageHash: HostHookTransactionWriter.hash(bytes),
                renderedBytes: Data(rendered.utf8),
                originalMode: try HostHookTransactionWriter.posixMode(of: configFile)
            )
        ])
        return MuseSetup.MergeResult(mutated: true, settingsURL: configFile)
    }

    /// Remove a previously written block, but only on a verbatim match.
    /// Anything else throws `differs` so uninstall prints manual guidance
    /// instead of guessing at TOML surgery.
    static func unmerge(
        name: String,
        entry: MuseSetup.ServerEntry,
        at configFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MuseSetup.MergeResult {
        try HostHookTransactionWriter.refuseSymlink(configFile)
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        let bytes = try Data(contentsOf: configFile)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CodexSetupError.notUTF8
        }
        guard hasServerTable(text, name: name) else {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        let block = snippet(for: entry)
        guard text.contains(block) else {
            throw CodexSetupError.differs(configFile.path)
        }
        let rendered = text.replacingOccurrences(of: "\n" + block, with: "\n")
            .replacingOccurrences(of: block, with: "")
        let renderedBytes = Data(rendered.utf8)
        if renderedBytes == bytes {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        try writer.commit([
            HostHookWritePlan(
                url: configFile,
                originalBytes: bytes,
                preimageHash: HostHookTransactionWriter.hash(bytes),
                renderedBytes: renderedBytes,
                originalMode: try HostHookTransactionWriter.posixMode(of: configFile)
            )
        ])
        return MuseSetup.MergeResult(mutated: true, settingsURL: configFile)
    }

    /// True when the Codex config contains an `[mcp_servers.<name>]` table.
    /// Missing files read as false; non-UTF8 files throw.
    static func hasEntry(name: String, at configFile: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return false
        }
        let bytes = try Data(contentsOf: configFile)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CodexSetupError.notUTF8
        }
        return hasServerTable(text, name: name)
    }

    private static func hasServerTable(_ text: String, name: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?m)^\s*\[\s*mcp_servers\.\#(escaped)\s*\]"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func tomlKey(_ key: String) -> String {
        let bare = key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
        return bare && !key.isEmpty ? key : tomlString(key)
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
