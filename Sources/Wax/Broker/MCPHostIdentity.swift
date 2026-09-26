import Foundation
import WaxCore

/// Host conversation isolation key. Equal raw IDs from different hosts do not collide.
package struct HostConversationKey: Hashable, Sendable, Equatable {
    package var hostNamespace: String
    package var conversationID: String

    package init(hostNamespace: String, conversationID: String) {
        self.hostNamespace = hostNamespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.conversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Namespaced conversation ID persisted on the broker manifest.
    package var wireConversationID: String {
        "\(hostNamespace):\(conversationID)"
    }

    package var isUsable: Bool {
        !hostNamespace.isEmpty && !conversationID.isEmpty
    }
}

/// Transport lease key. Client-controlled correlation, not authentication.
package struct MCPTransportKey: Hashable, Sendable, Equatable {
    package var rawConnectionKey: String

    package init(rawConnectionKey: String) {
        self.rawConnectionKey = rawConnectionKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package var hashedConversationID: String {
        let digest = SHA256Checksum.digest(Data(rawConnectionKey.utf8)).hexString
        return "transport:\(digest)"
    }

    package var isUsable: Bool { !rawConnectionKey.isEmpty }
}

package enum MCPMemoryOwnership: String, Sendable, Equatable {
    case transport
    case host
}

package struct MCPClientIdentity: Sendable, Equatable {
    package var name: String?
    package var version: String?
    package var isSyntheticRecovery: Bool

    package static let syntheticRecoveryName = "wax-mcp-session-recover"

    package init(name: String? = nil, version: String? = nil, isSyntheticRecovery: Bool = false) {
        self.name = name
        self.version = version
        self.isSyntheticRecovery = isSyntheticRecovery
            || name == Self.syntheticRecoveryName
    }

    /// Recovery-synthetic identity must never become a host conversation owner.
    package var canOwnHostConversation: Bool {
        !isSyntheticRecovery
    }
}

package struct MCPProjectAttribution: Sendable, Equatable {
    package enum Source: String, Sendable, Equatable {
        case explicit
        case advertisedCWD
        case mcpRoot
        case unresolved
    }

    package var project: String?
    package var repo: String?
    package var cwdPath: String?
    package var source: Source

    package init(
        project: String? = nil,
        repo: String? = nil,
        cwdPath: String? = nil,
        source: Source = .unresolved
    ) {
        self.project = project
        self.repo = repo
        self.cwdPath = cwdPath
        self.source = source
    }

    package var isResolved: Bool {
        source != .unresolved && (project != nil || repo != nil || cwdPath != nil)
    }
}

package struct MCPConnectionContext: Sendable, Equatable {
    package var transportKey: String
    package var advertisedCWD: String?
    package var mcpRoots: [String]
    package var clientIdentity: MCPClientIdentity
    package var trustedHostConversation: HostConversationKey?

    package init(
        transportKey: String,
        advertisedCWD: String? = nil,
        mcpRoots: [String] = [],
        clientIdentity: MCPClientIdentity = MCPClientIdentity(),
        trustedHostConversation: HostConversationKey? = nil
    ) {
        self.transportKey = transportKey
        self.advertisedCWD = advertisedCWD
        self.mcpRoots = mcpRoots
        self.clientIdentity = clientIdentity
        self.trustedHostConversation = trustedHostConversation
    }

    package var canonicalMCPRoot: String? {
        let unique = Array(Set(mcpRoots.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }))
        return unique.count == 1 ? unique[0] : nil
    }
}

package enum MCPProjectAttributionResolver {
    /// Resolve project/repo from explicit arguments, then advertised cwd, then exactly one MCP root.
    /// Never uses the MCP server process cwd.
    package static func resolve(
        explicitProject: String?,
        explicitRepo: String?,
        advertisedCWD: String?,
        mcpRoots: [String],
        processDirectoryPath: String = "/__wax_unused_process_cwd__"
    ) -> MCPProjectAttribution {
        if let project = normalized(explicitProject), !project.isEmpty {
            let repo = normalized(explicitRepo)
            return MCPProjectAttribution(
                project: project,
                repo: repo,
                cwdPath: normalized(advertisedCWD),
                source: .explicit
            )
        }
        if let repo = normalized(explicitRepo), !repo.isEmpty {
            return MCPProjectAttribution(
                project: nil,
                repo: repo,
                cwdPath: normalized(advertisedCWD),
                source: .explicit
            )
        }
        if let cwd = normalized(advertisedCWD), !cwd.isEmpty {
            let inferred = MemorySemantics.inferScopeContext(
                currentDirectoryPath: cwd,
                processDirectoryPath: processDirectoryPath
            )
            if inferred.projectName != nil || inferred.repoName != nil || inferred.cwdPath != nil {
                return MCPProjectAttribution(
                    project: inferred.projectName,
                    repo: inferred.repoName,
                    cwdPath: inferred.cwdPath ?? cwd,
                    source: .advertisedCWD
                )
            }
        }
        let uniqueRoots = Array(Set((mcpRoots.compactMap(normalized)).filter { !$0.isEmpty }))
        if uniqueRoots.count == 1, let root = uniqueRoots.first {
            let inferred = MemorySemantics.inferScopeContext(
                currentDirectoryPath: root,
                processDirectoryPath: processDirectoryPath
            )
            return MCPProjectAttribution(
                project: inferred.projectName,
                repo: inferred.repoName,
                cwdPath: inferred.cwdPath ?? root,
                source: .mcpRoot
            )
        }
        return MCPProjectAttribution(source: .unresolved)
    }

    /// `scope` is the parsed remember horizon. It never skips project gating.
    package static func isProjectScopedWrite(
        memoryType: MemoryType?,
        scope _: RememberWriteScope?
    ) -> Bool {
        memoryType != .userPreference
    }

    package static func isProjectGatedRecall(scope: LayeredRecall.Scope) -> Bool {
        scope == .project
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

package enum MCPAutoSessionPolicy {
    package static func isEnabled(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let raw = environment["WAX_MCP_AUTO_SESSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }
}

package enum MCPInitializeIdentityParser {
    package static func parse(from body: Data) -> MCPClientIdentity {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return MCPClientIdentity()
        }
        return parse(from: json)
    }

    package static func parse(from json: [String: Any]) -> MCPClientIdentity {
        let params = json["params"] as? [String: Any]
        let info = params?["clientInfo"] as? [String: Any]
        let name = info?["name"] as? String
        let version = info?["version"] as? String
        return MCPClientIdentity(name: name, version: version)
    }
}

/// MCP root URIs to filesystem paths. Roots must use the `file` scheme;
/// anything else is dropped, never guessed. Bare absolute paths are kept
/// so initialize-embedded roots stay usable.
package enum MCPRootsMapper {
    package static func paths(fromURIs uris: [String]) -> [String] {
        uris.compactMap(path(fromURI:))
    }

    package static func path(fromURI uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "file",
              !url.path.isEmpty
        else { return nil }
        return url.path
    }

    package static func paths(fromRootValues values: [Any]) -> [String] {
        var out: [String] = []
        for value in values {
            if let raw = value as? String, let mapped = path(fromURI: raw) {
                out.append(mapped)
            } else if let dict = value as? [String: Any],
                      let raw = dict["uri"] as? String,
                      let mapped = path(fromURI: raw) {
                out.append(mapped)
            }
        }
        return out
    }
}

/// Initialize-time roots capture. The spec carries roots via `roots/list`,
/// but clients that embed `params.roots` (or `_meta.roots`) are honored so
/// attribution works without a second round-trip.
package enum MCPInitializeRootsParser {
    package static func parseRoots(from body: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return []
        }
        return parseRoots(from: json)
    }

    package static func parseRoots(from json: [String: Any]) -> [String] {
        let params = json["params"] as? [String: Any] ?? [:]
        var ordered: [String] = []
        var seen = Set<String>()
        func append(_ paths: [String]) {
            for path in paths where seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        if let roots = params["roots"] as? [Any] {
            append(MCPRootsMapper.paths(fromRootValues: roots))
        }
        if let meta = params["_meta"] as? [String: Any],
           let roots = meta["roots"] as? [Any] {
            append(MCPRootsMapper.paths(fromRootValues: roots))
        }
        if let capabilities = params["capabilities"] as? [String: Any],
           let roots = capabilities["roots"] as? [Any] {
            append(MCPRootsMapper.paths(fromRootValues: roots))
        }
        return ordered
    }
}

/// Last-resolved project attribution per transport key. Once a connection
/// resolves, repeats reuse it instead of re-failing when the caller omits
/// `cwd`/`project`/`repo` (e.g. after `session_end` clears the binding).
package final class MCPStickyAttributionRegistry: @unchecked Sendable {
    package static let shared = MCPStickyAttributionRegistry()

    private let lock = NSLock()
    private var stored: [String: MCPProjectAttribution] = [:]

    package func remember(transportKey: String, attribution: MCPProjectAttribution) {
        guard attribution.isResolved else { return }
        lock.lock()
        defer { lock.unlock() }
        stored[transportKey] = attribution
    }

    package func current(for transportKey: String) -> MCPProjectAttribution? {
        lock.lock()
        defer { lock.unlock() }
        return stored[transportKey]
    }

    package func remove(for transportKey: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.removeValue(forKey: transportKey)
    }

    package func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        stored.removeAll()
    }
}
