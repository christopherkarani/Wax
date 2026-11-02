#if MCPServer
import Foundation
import MCP
import Wax
import WaxCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum MCPPathConfinementError: Error, Sendable, Equatable {
    case notAbsolute(argument: String, path: String)
    case unresolvable(argument: String, path: String)
    case outsideAllowedRoots(argument: String, path: String, allowedRoots: [String])
    case notAWaxStorePath(argument: String, path: String)
    case wouldOverwriteNonStore(argument: String, path: String)

    var message: String {
        switch self {
        case .notAbsolute(let argument, let path):
            return "\(argument) must be an absolute path (got '\(path)')"
        case .unresolvable(let argument, let path):
            return "\(argument) '\(path)' contains a dangling or looping symlink"
        case .outsideAllowedRoots(let argument, let path, let roots):
            let allowed = roots.isEmpty ? "(none)" : roots.joined(separator: ", ")
            return "\(argument) '\(path)' is outside the allowed roots: \(allowed)"
        case .notAWaxStorePath(let argument, let path):
            return "\(argument) '\(path)' must name a .wax store file"
        case .wouldOverwriteNonStore(let argument, let path):
            return "\(argument) '\(path)' already exists and is not a Wax store; refusing to overwrite it"
        }
    }
}

/// Confines MCP-supplied filesystem paths before they reach the broker.
///
/// Markdown projections (`markdown_export` output, `markdown_sync` input)
/// may live in the Wax store directory, the broker session root, a root the
/// host advertised over MCP `roots/list`, or, for the stdio transport only,
/// the server process's working directory: a stdio server is launched by
/// the host inside the workspace it serves. An HTTP server is shared, so its
/// working directory is never a root.
///
/// `task_state_migrate` writes a whole store copy and may overwrite its
/// destination, so that destination is held tighter: a `.wax` file inside
/// the store directory, and an existing file is only replaced
/// when it is already a Wax store (`WAX1` header).
///
/// Tool arguments come from the model, so they never widen the allowed set.
struct MCPPathConfinement: Sendable {
    /// Canonical command name to its Markdown-projection path argument.
    static let workspacePathArguments: [String: String] = [
        "markdown_export": "output_dir",
        "markdown_sync": "root_dir",
    ]
    static let migrationCommand = "task_state_migrate"
    static let migrationDestinationArgument = "destination_path"

    /// Refuses every path argument. Use when no store layout is known.
    static let denyAll = MCPPathConfinement(fixedRoots: [], storeDirectory: nil)

    var fixedRoots: [String]
    /// Only root for `task_state_migrate` destinations; nil refuses them.
    var storeDirectory: String?

    init(fixedRoots: [String], storeDirectory: String? = nil) {
        self.fixedRoots = fixedRoots
        self.storeDirectory = storeDirectory
    }

    init(storeURL: URL, sessionRootURL: URL, includeProcessDirectory: Bool) {
        let storeDirectory = storeURL.deletingLastPathComponent().path
        var roots = [storeDirectory, sessionRootURL.path]
        if includeProcessDirectory {
            roots.append(FileManager.default.currentDirectoryPath)
        }
        self.init(fixedRoots: roots, storeDirectory: storeDirectory)
    }

    init(configuration: AgentBrokerConfiguration, includeProcessDirectory: Bool) {
        self.init(
            storeURL: URL(fileURLWithPath: AgentBrokerPathing.expandPath(configuration.storePath)),
            sessionRootURL: URL(fileURLWithPath: AgentBrokerPathing.expandPath(configuration.sessionRootPath)),
            includeProcessDirectory: includeProcessDirectory
        )
    }

    /// True when the command's path is checked against host project roots.
    static func usesProjectRoots(command: String) -> Bool {
        let canonical = BrokerCommandCatalog.canonicalCommand(for: command) ?? command
        return workspacePathArguments[canonical] != nil
    }

    func allowedRoots(projectRoots: [String]) -> [String] {
        Self.canonicalRoots(fixedRoots + projectRoots)
    }

    /// Returns the canonical (symlink-free) absolute path for `raw` when it
    /// lies inside one of the allowed roots.
    func confine(
        argument: String,
        path raw: String,
        projectRoots: [String]
    ) throws(MCPPathConfinementError) -> String {
        try Self.confine(argument: argument, path: raw, roots: allowedRoots(projectRoots: projectRoots))
    }

    /// Canonical destination for a store copy: a `.wax` path inside the
    /// store directory that is either new or already a Wax store.
    func confineMigrationDestination(path raw: String) throws(MCPPathConfinementError) -> String {
        let argument = Self.migrationDestinationArgument
        let roots = Self.canonicalRoots(storeDirectory.map { [$0] } ?? [])
        let resolved = try Self.confine(argument: argument, path: raw, roots: roots)
        guard (resolved as NSString).pathExtension.lowercased() == "wax" else {
            throw .notAWaxStorePath(argument: argument, path: raw)
        }
        var info = stat()
        guard lstat(resolved, &info) == 0 else { return resolved }
        guard (info.st_mode & S_IFMT) == S_IFREG, Self.hasWaxStoreHeader(atPath: resolved) else {
            throw .wouldOverwriteNonStore(argument: argument, path: raw)
        }
        return resolved
    }

    /// Rewrites the command's path argument to its confined canonical form.
    func apply(
        command: String,
        arguments: inout [String: Value],
        projectRoots: [String]
    ) throws(MCPPathConfinementError) {
        let canonical = BrokerCommandCatalog.canonicalCommand(for: command) ?? command
        if canonical == Self.migrationCommand {
            let key = Self.migrationDestinationArgument
            guard case .string(let raw)? = arguments[key] else { return }
            arguments[key] = .string(try confineMigrationDestination(path: raw))
            return
        }
        guard let key = Self.workspacePathArguments[canonical],
              case .string(let raw)? = arguments[key]
        else { return }
        arguments[key] = .string(try confine(argument: key, path: raw, projectRoots: projectRoots))
    }

    private static func confine(
        argument: String,
        path raw: String,
        roots: [String]
    ) throws(MCPPathConfinementError) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw .notAbsolute(argument: argument, path: raw)
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard let resolved = resolve(standardized) else {
            throw .unresolvable(argument: argument, path: raw)
        }
        guard roots.contains(where: { isContained(resolved, in: $0) }) else {
            throw .outsideAllowedRoots(argument: argument, path: raw, allowedRoots: roots)
        }
        return resolved
    }

    private static func canonicalRoots(_ rawRoots: [String]) -> [String] {
        var seen = Set<String>()
        return rawRoots.compactMap { raw in
            guard let resolved = resolve(AgentBrokerPathing.expandPath(raw)),
                  resolved != "/",
                  seen.insert(resolved).inserted
            else { return nil }
            return resolved
        }
    }

    private static func hasWaxStoreHeader(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: Constants.magic.count)) ?? Data()
        return header == Constants.magic
    }

    static func isContained(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Resolves symlinks in the deepest existing ancestor and re-appends the
    /// missing tail. Returns nil when an existing component cannot be
    /// resolved (dangling or looping symlink): writing through it could land
    /// anywhere.
    static func resolve(_ absolutePath: String) -> String? {
        var existing = absolutePath
        var missing: [String] = []
        while true {
            if let real = realPath(existing) {
                return missing.reduce(real) { ($0 as NSString).appendingPathComponent($1) }
            }
            var info = stat()
            if lstat(existing, &info) == 0 {
                return nil
            }
            let parent = (existing as NSString).deletingLastPathComponent
            guard parent != existing, !parent.isEmpty else { return nil }
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
#endif
