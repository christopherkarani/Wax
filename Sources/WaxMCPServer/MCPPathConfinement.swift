#if MCPServer
import Foundation
import MCP
import Wax

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum MCPPathConfinementError: Error, Sendable, Equatable {
    case notAbsolute(argument: String, path: String)
    case unresolvable(argument: String, path: String)
    case outsideAllowedRoots(argument: String, path: String, allowedRoots: [String])

    var message: String {
        switch self {
        case .notAbsolute(let argument, let path):
            return "\(argument) must be an absolute path (got '\(path)')"
        case .unresolvable(let argument, let path):
            return "\(argument) '\(path)' contains a dangling or looping symlink"
        case .outsideAllowedRoots(let argument, let path, let roots):
            return "\(argument) '\(path)' is outside the allowed roots: \(roots.joined(separator: ", "))"
        }
    }
}

/// Confines MCP-supplied filesystem paths to the Wax store directory, the
/// broker session root, and the host-advertised project roots.
///
/// Tool arguments come from the model, so they never widen the allowed set:
/// roots are the store layout plus what the host itself advertised (MCP
/// `roots/list`, or the stdio server's working directory).
struct MCPPathConfinement: Sendable {
    /// Canonical command name to its path-valued argument.
    static let pathArguments: [String: String] = [
        "markdown_export": "output_dir",
        "markdown_sync": "root_dir",
        "task_state_migrate": "destination_path",
    ]

    var fixedRoots: [String]

    init(fixedRoots: [String]) {
        self.fixedRoots = fixedRoots
    }

    init(configuration: AgentBrokerConfiguration, includeProcessDirectory: Bool) {
        let storeDirectory = URL(fileURLWithPath: AgentBrokerPathing.expandPath(configuration.storePath))
            .deletingLastPathComponent()
            .path
        var roots = [storeDirectory, AgentBrokerPathing.expandPath(configuration.sessionRootPath)]
        if includeProcessDirectory {
            roots.append(FileManager.default.currentDirectoryPath)
        }
        self.init(fixedRoots: roots)
    }

    func allowedRoots(projectRoots: [String]) -> [String] {
        var seen = Set<String>()
        return (fixedRoots + projectRoots).compactMap { raw in
            guard let resolved = Self.resolve(AgentBrokerPathing.expandPath(raw)),
                  resolved != "/",
                  seen.insert(resolved).inserted
            else { return nil }
            return resolved
        }
    }

    /// Returns the canonical (symlink-free) absolute path for `raw` when it
    /// lies inside one of the allowed roots.
    func confine(
        argument: String,
        path raw: String,
        projectRoots: [String]
    ) throws(MCPPathConfinementError) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw .notAbsolute(argument: argument, path: raw)
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard let resolved = Self.resolve(standardized) else {
            throw .unresolvable(argument: argument, path: raw)
        }
        let roots = allowedRoots(projectRoots: projectRoots)
        guard roots.contains(where: { Self.isContained(resolved, in: $0) }) else {
            throw .outsideAllowedRoots(argument: argument, path: raw, allowedRoots: roots)
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
        guard let key = Self.pathArguments[canonical],
              case .string(let raw)? = arguments[key]
        else { return }
        arguments[key] = .string(try confine(argument: key, path: raw, projectRoots: projectRoots))
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
