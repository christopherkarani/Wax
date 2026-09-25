import Foundation

/// OpenCode (`~/.config/opencode/opencode.json`, honoring
/// `OPENCODE_CONFIG` / `OPENCODE_CONFIG_DIR`) registration for `mcp install`.
///
/// Follows the official schema: top-level `mcp` object mapping names to
/// `{type: "local", command: [bin, args...], environment: {...}}`. The merge
/// preserves every existing key and only touches `mcp.<name>`. JSONC configs
/// are never edited: without a comment-preserving parser any rewrite would
/// destroy user comments, so those stay guided-manual.
enum OpenCodeSetup {
    /// Timeout for MCP requests. Wax cold-start embedder load can take tens
    /// of seconds; the 5s schema default would kill slow first calls.
    static let requestTimeoutMs = 60_000

    static func merge(
        entry: MuseSetup.ServerEntry,
        at configFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MuseSetup.MergeResult {
        try HostHookTransactionWriter.refuseSymlink(configFile)
        if configFile.pathExtension.lowercased() == "jsonc" {
            throw OpenCodeSetupError.jsoncManual(configFile.path)
        }

        let exists = FileManager.default.fileExists(atPath: configFile.path)
        if !exists {
            let jsonc = configFile.deletingPathExtension().appendingPathExtension("jsonc")
            if FileManager.default.fileExists(atPath: jsonc.path) {
                throw OpenCodeSetupError.jsoncManual(jsonc.path)
            }
            try HostHookTransactionWriter.refuseSymlink(configFile.deletingLastPathComponent())
        }
        let originalBytes: Data?
        let document: HostHookJSON
        if exists {
            let bytes = try Data(contentsOf: configFile)
            originalBytes = bytes
            guard let parsed = try? HostHookJSON.parse(bytes), parsed.objectMembers != nil else {
                throw OpenCodeSetupError.malformedJSON
            }
            document = parsed
        } else {
            originalBytes = nil
            document = .object([])
        }

        var servers = document.value(forKey: "mcp") ?? .object([])
        guard servers.objectMembers != nil else {
            throw OpenCodeSetupError.malformedJSON
        }
        servers.set(entry.name, to: serverJSON(entry))
        var merged = document
        merged.set("mcp", to: servers)
        return try commit(
            merged: merged,
            at: configFile,
            originalBytes: originalBytes,
            exists: exists,
            writer: writer
        )
    }

    /// Remove a previous registration. Missing files and missing entries are
    /// a no-op (`mutated: false`); malformed files are left untouched.
    static func unmerge(
        name: String,
        at configFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MuseSetup.MergeResult {
        try HostHookTransactionWriter.refuseSymlink(configFile)
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        if configFile.pathExtension.lowercased() == "jsonc" {
            throw OpenCodeSetupError.jsoncManualRemove(configFile.path)
        }
        let bytes = try Data(contentsOf: configFile)
        guard let document = try? HostHookJSON.parse(bytes), document.objectMembers != nil else {
            throw OpenCodeSetupError.malformedJSON
        }
        guard var servers = document.value(forKey: "mcp"), servers.objectMembers != nil else {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        guard servers.value(forKey: name) != nil else {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        servers.remove(name)
        var merged = document
        merged.set("mcp", to: servers)
        return try commit(
            merged: merged,
            at: configFile,
            originalBytes: bytes,
            exists: true,
            writer: writer
        )
    }

    /// True when the OpenCode config registers `name`. Missing files read as
    /// false; malformed files throw.
    static func hasEntry(name: String, at configFile: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return false
        }
        if configFile.pathExtension.lowercased() == "jsonc" {
            throw OpenCodeSetupError.jsoncManual(configFile.path)
        }
        let bytes = try Data(contentsOf: configFile)
        guard let document = try? HostHookJSON.parse(bytes), document.objectMembers != nil else {
            throw OpenCodeSetupError.malformedJSON
        }
        guard let servers = document.value(forKey: "mcp"), servers.objectMembers != nil else {
            return false
        }
        return servers.value(forKey: name) != nil
    }

    private static func commit(
        merged: HostHookJSON,
        at configFile: URL,
        originalBytes: Data?,
        exists: Bool,
        writer: HostHookTransactionWriter
    ) throws -> MuseSetup.MergeResult {
        let rendered = merged.rendered()
        if let originalBytes, originalBytes == rendered {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        let mode: UInt16
        if exists {
            mode = try HostHookTransactionWriter.posixMode(of: configFile)
        } else {
            mode = 0o600
        }
        try writer.commit([
            HostHookWritePlan(
                url: configFile,
                originalBytes: originalBytes,
                preimageHash: HostHookTransactionWriter.hash(originalBytes ?? Data()),
                renderedBytes: rendered,
                originalMode: mode
            )
        ])
        return MuseSetup.MergeResult(mutated: true, settingsURL: configFile)
    }

    private static func serverJSON(_ entry: MuseSetup.ServerEntry) -> HostHookJSON {
        var command: [HostHookJSON] = [.string(entry.command)]
        command.append(contentsOf: entry.args.map(HostHookJSON.string))
        var members = [
            HostHookJSONMember(key: "type", value: .string("local")),
            HostHookJSONMember(key: "command", value: .array(command)),
            HostHookJSONMember(key: "enabled", value: .bool(true)),
            HostHookJSONMember(key: "timeout", value: .number(String(requestTimeoutMs))),
        ]
        if !entry.env.isEmpty {
            members.append(
                HostHookJSONMember(
                    key: "environment",
                    value: .object(entry.env.map { HostHookJSONMember(key: $0.0, value: .string($0.1)) })
                )
            )
        }
        return .object(members)
    }
}

enum OpenCodeSetupError: Error, Equatable, LocalizedError {
    case malformedJSON
    case jsoncManual(String)
    case jsoncManualRemove(String)

    var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "OpenCode opencode.json is not valid JSON."
        case .jsoncManual(let path):
            return "OpenCode uses \(path) (JSONC with comments); add the wax entry there manually instead of overwriting."
        case .jsoncManualRemove(let path):
            return "OpenCode uses \(path) (JSONC with comments); remove the wax entry there manually instead of overwriting."
        }
    }
}
