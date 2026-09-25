import Foundation

/// Shared append-only `[mcp_servers.<name>]` TOML block store for Codex/Grok.
///
/// TOML has no safe partial merge without a real parser, so both hosts share
/// one discipline: append-only writes that fail closed on any differing
/// block. Callers map `Failure` to their host-specific error type so each
/// host keeps its own diagnostics. Removal stays manual for the same reason:
/// without a parser, uninstall cannot reconstruct the installed block for a
/// verbatim match.
enum TOMLServerBlock {
    enum Failure: Error {
        case notUTF8
        case differs
    }

    /// Append `block` to the TOML config, creating the file when it is
    /// missing. Never edits an existing block: identical blocks are a no-op
    /// and differing blocks throw `differs`.
    static func write(
        name: String,
        block: String,
        at configFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MuseSetup.MergeResult {
        try HostHookTransactionWriter.refuseSymlink(configFile)

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
            throw Failure.notUTF8
        }
        if blockExists(text, name: name) {
            if text.contains(block) {
                return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
            }
            throw Failure.differs
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

    /// True when the TOML config contains an `[mcp_servers.<name>]` table.
    /// Missing files read as false; non-UTF8 files throw.
    static func hasEntry(name: String, at configFile: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return false
        }
        let bytes = try Data(contentsOf: configFile)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw Failure.notUTF8
        }
        return blockExists(text, name: name)
    }

    static func blockExists(_ text: String, name: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?m)^\s*\[\s*mcp_servers\.\#(escaped)\s*\]"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    static func string(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    static func key(_ key: String) -> String {
        let bare = key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
        return bare && !key.isEmpty ? key : string(key)
    }
}
