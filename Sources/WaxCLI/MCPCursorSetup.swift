import Foundation

/// Cursor (`~/.cursor/mcp.json`) registration for `mcp install`.
///
/// Cursor reads MCP servers from the `mcpServers` object. The merge preserves
/// every existing key and only touches `mcpServers.<name>`.
enum CursorSetup {
    static func merge(
        entry: MuseSetup.ServerEntry,
        at configFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MuseSetup.MergeResult {
        try HostHookTransactionWriter.refuseSymlink(configFile)

        let exists = FileManager.default.fileExists(atPath: configFile.path)
        let originalBytes: Data?
        let document: HostHookJSON
        if exists {
            let bytes = try Data(contentsOf: configFile)
            originalBytes = bytes
            guard let parsed = try? HostHookJSON.parse(bytes), parsed.objectMembers != nil else {
                throw CursorSetupError.malformedJSON
            }
            document = parsed
        } else {
            try HostHookTransactionWriter.refuseSymlink(configFile.deletingLastPathComponent())
            originalBytes = nil
            document = .object([])
        }

        var servers = document.value(forKey: "mcpServers") ?? .object([])
        guard servers.objectMembers != nil else {
            throw CursorSetupError.malformedJSON
        }
        servers.set(entry.name, to: serverJSON(entry))
        var merged = document
        merged.set("mcpServers", to: servers)
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
        let bytes = try Data(contentsOf: configFile)
        guard let document = try? HostHookJSON.parse(bytes), document.objectMembers != nil else {
            throw CursorSetupError.malformedJSON
        }
        guard var servers = document.value(forKey: "mcpServers"), servers.objectMembers != nil else {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        guard servers.value(forKey: name) != nil else {
            return MuseSetup.MergeResult(mutated: false, settingsURL: configFile)
        }
        servers.remove(name)
        var merged = document
        merged.set("mcpServers", to: servers)
        return try commit(
            merged: merged,
            at: configFile,
            originalBytes: bytes,
            exists: true,
            writer: writer
        )
    }

    /// True when the Cursor config registers `name`. Missing files read as
    /// false; malformed files throw.
    static func hasEntry(name: String, at configFile: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return false
        }
        let bytes = try Data(contentsOf: configFile)
        guard let document = try? HostHookJSON.parse(bytes), document.objectMembers != nil else {
            throw CursorSetupError.malformedJSON
        }
        guard let servers = document.value(forKey: "mcpServers"), servers.objectMembers != nil else {
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
        var members = [
            HostHookJSONMember(key: "command", value: .string(entry.command)),
            HostHookJSONMember(key: "args", value: .array(entry.args.map(HostHookJSON.string))),
        ]
        if !entry.env.isEmpty {
            members.append(
                HostHookJSONMember(
                    key: "env",
                    value: .object(entry.env.map { HostHookJSONMember(key: $0.0, value: .string($0.1)) })
                )
            )
        }
        return .object(members)
    }
}

enum CursorSetupError: Error, Equatable, LocalizedError {
    case malformedJSON

    var errorDescription: String? {
        "Cursor mcp.json is not valid JSON."
    }
}
