import Foundation

/// Muse Code (`~/.config/muse/settings.json`) registration for `mcp install`.
///
/// Muse merges `mcp_servers` from user settings only; there is no
/// project-scoped MCP path and no `muse mcp add` CLI, so install edits the
/// settings file directly. The merge preserves every existing key and only
/// touches `mcp_servers.<name>`, creating the file with `schema_version: 1`
/// when it is missing.
enum MuseSetup {
    static let settingsSchemaVersion = 1
    static let defaultMode = "optional"

    struct ServerEntry: Equatable, Sendable {
        var name: String
        var command: String
        var args: [String]
        var env: [(String, String)]
        var mode: String

        static func == (lhs: ServerEntry, rhs: ServerEntry) -> Bool {
            lhs.name == rhs.name
                && lhs.command == rhs.command
                && lhs.args == rhs.args
                && lhs.env.elementsEqual(rhs.env, by: ==)
                && lhs.mode == rhs.mode
        }
    }

    struct MergeResult: Equatable, Sendable {
        var mutated: Bool
        var settingsURL: URL
    }

    /// Resolve the Muse settings path. Honors `XDG_CONFIG_HOME`, else
    /// `~/.config/muse/settings.json`. The environment is a parameter so
    /// tests do not touch process state.
    static func settingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment["XDG_CONFIG_HOME"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed)
                    .appendingPathComponent("muse", isDirectory: true)
                    .appendingPathComponent("settings.json")
            }
        }
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("muse", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// User skill directory: `$XDG_CONFIG_HOME/muse/skills`, else
    /// `~/.config/muse/skills`. This is where `muse skills install --scope
    /// user` stages skills.
    static func skillsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment["XDG_CONFIG_HOME"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed)
                    .appendingPathComponent("muse", isDirectory: true)
                    .appendingPathComponent("skills", isDirectory: true)
            }
        }
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("muse", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Build the stdio server entry from install inputs. Shared by every
    /// host registration so all of them record the same command, args,
    /// and environment.
    static func makeEntry(
        name: String,
        serverPath: String,
        storePath: String,
        env: [(String, String)],
        noEmbedder: Bool,
        featureLicense: Bool,
        mode: String = defaultMode
    ) -> ServerEntry {
        var args = ["--store-path", storePath]
        if noEmbedder {
            args.append("--no-embedder")
        }
        if featureLicense {
            args.append("--feature-license")
        }
        return ServerEntry(
            name: name,
            command: serverPath,
            args: args,
            env: env,
            mode: mode
        )
    }

    /// Merge `entry` into the Muse settings file. Missing files are seeded
    /// with `schema_version: 1`; existing files must already carry a
    /// supported schema version or the merge refuses (Muse itself rejects
    /// such files, so writing into them would only hide the breakage).
    static func merge(
        entry: ServerEntry,
        at settingsFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MergeResult {
        try HostHookTransactionWriter.refuseSymlink(settingsFile)

        let exists = FileManager.default.fileExists(atPath: settingsFile.path)
        let originalBytes: Data?
        let document: HostHookJSON
        if exists {
            let bytes = try Data(contentsOf: settingsFile)
            originalBytes = bytes
            guard let parsed = try? HostHookJSON.parse(bytes) else {
                throw MuseSetupError.malformedJSON
            }
            document = parsed
        } else {
            try HostHookTransactionWriter.refuseSymlink(settingsFile.deletingLastPathComponent())
            originalBytes = nil
            document = .object([
                HostHookJSONMember(key: "schema_version", value: .number(String(settingsSchemaVersion)))
            ])
        }

        try validateSchema(document, existed: exists)

        var servers = document.value(forKey: "mcp_servers") ?? .object([])
        guard servers.objectMembers != nil else {
            throw MuseSetupError.malformedJSON
        }
        servers.set(entry.name, to: serverJSON(entry))
        var merged = document
        merged.set("mcp_servers", to: servers)

        let rendered = merged.rendered()
        if let originalBytes, originalBytes == rendered {
            return MergeResult(mutated: false, settingsURL: settingsFile)
        }

        let mode: UInt16
        if exists {
            mode = try HostHookTransactionWriter.posixMode(of: settingsFile)
        } else {
            mode = 0o600
        }
        try writer.commit([
            HostHookWritePlan(
                url: settingsFile,
                originalBytes: originalBytes,
                preimageHash: HostHookTransactionWriter.hash(originalBytes ?? Data()),
                renderedBytes: rendered,
                originalMode: mode
            )
        ])
        return MergeResult(mutated: true, settingsURL: settingsFile)
    }

    /// Remove a previous registration. Missing files and missing entries are
    /// a no-op (`mutated: false`); malformed or schema-less files are left
    /// untouched.
    static func unmerge(
        name: String,
        at settingsFile: URL,
        writer: HostHookTransactionWriter = HostHookTransactionWriter()
    ) throws -> MergeResult {
        try HostHookTransactionWriter.refuseSymlink(settingsFile)
        guard FileManager.default.fileExists(atPath: settingsFile.path) else {
            return MergeResult(mutated: false, settingsURL: settingsFile)
        }
        let bytes = try Data(contentsOf: settingsFile)
        guard let document = try? HostHookJSON.parse(bytes) else {
            throw MuseSetupError.malformedJSON
        }
        try validateSchema(document, existed: true)
        guard var servers = document.value(forKey: "mcp_servers"), servers.objectMembers != nil else {
            return MergeResult(mutated: false, settingsURL: settingsFile)
        }
        guard servers.value(forKey: name) != nil else {
            return MergeResult(mutated: false, settingsURL: settingsFile)
        }
        servers.remove(name)
        var merged = document
        merged.set("mcp_servers", to: servers)

        let rendered = merged.rendered()
        if rendered == bytes {
            return MergeResult(mutated: false, settingsURL: settingsFile)
        }
        try writer.commit([
            HostHookWritePlan(
                url: settingsFile,
                originalBytes: bytes,
                preimageHash: HostHookTransactionWriter.hash(bytes),
                renderedBytes: rendered,
                originalMode: try HostHookTransactionWriter.posixMode(of: settingsFile)
            )
        ])
        return MergeResult(mutated: true, settingsURL: settingsFile)
    }

    /// True when the settings file registers `name`. Missing files read as
    /// false; malformed or schema-less files throw so callers can report
    /// breakage instead of silent absence.
    static func hasEntry(name: String, at settingsFile: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else {
            return false
        }
        let bytes = try Data(contentsOf: settingsFile)
        guard let document = try? HostHookJSON.parse(bytes) else {
            throw MuseSetupError.malformedJSON
        }
        try validateSchema(document, existed: true)
        guard let servers = document.value(forKey: "mcp_servers"), servers.objectMembers != nil else {
            return false
        }
        return servers.value(forKey: name) != nil
    }

    /// Require a supported `schema_version` on an existing settings
    /// document. Shared by install-merge and wire-hooks so both writers
    /// refuse files Muse itself would reject.
    static func requireSupportedSchema(_ document: HostHookJSON) throws {
        try validateSchema(document, existed: true)
    }

    private static func validateSchema(_ document: HostHookJSON, existed: Bool) throws {
        guard let version = document.value(forKey: "schema_version")?.numberLexeme else {
            if existed {
                throw MuseSetupError.missingSchemaVersion
            }
            throw MuseSetupError.malformedJSON
        }
        guard version == String(settingsSchemaVersion) else {
            throw MuseSetupError.unsupportedSchemaVersion(version)
        }
    }

    private static func serverJSON(_ entry: ServerEntry) -> HostHookJSON {
        var members = [
            HostHookJSONMember(key: "transport", value: .string("stdio")),
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
        members.append(HostHookJSONMember(key: "mode", value: .string(entry.mode)))
        return .object(members)
    }
}

enum MuseSetupError: Error, Equatable, LocalizedError {
    case malformedJSON
    case missingSchemaVersion
    case unsupportedSchemaVersion(String)

    var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "Muse settings file is not valid JSON."
        case .missingSchemaVersion:
            return "Muse settings file lacks schema_version; Muse itself rejects such files. Fix or remove it, then re-run install."
        case .unsupportedSchemaVersion(let version):
            return "Unsupported Muse settings schema version (\(version)). Refusing to modify the file."
        }
    }
}
